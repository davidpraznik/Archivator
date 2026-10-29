import Foundation

// Motor: sistemska orodja. ZIP z ditto (kot Finder), 7z in tar.gz z bsdtar (libarchive).
// Razpakiranje z bsdtar. Brez -P bsdtar zavrne poti z ".." in odreže začetni "/".

enum Archiver {
    struct Failure: Error { let message: String }
    struct Cancelled: Error {}

    // Preklic (Esc): ustavi tekoče orodje, nedokončan izhod pobriše obstoječi catch.
    private final class JobState {
        let lock = NSLock()
        var process: Process?
        var cancelled = false
    }
    private nonisolated static let job = JobState()

    nonisolated static func beginJob() {
        job.lock.lock(); job.cancelled = false; job.process = nil; job.lock.unlock()
    }

    nonisolated static var wasCancelled: Bool {
        job.lock.lock(); defer { job.lock.unlock() }
        return job.cancelled
    }

    nonisolated static func cancel() {
        job.lock.lock()
        job.cancelled = true
        let p = job.process
        job.lock.unlock()
        if let p = p, p.isRunning { p.terminate() }
    }

    nonisolated static let archiveExtensions: Set<String> =
        ["zip", "7z", "tar", "tgz", "gz", "bz2", "tbz2", "xz", "txz", "rar"]

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated static func isArchive(_ url: URL) -> Bool {
        !isDirectory(url) && archiveExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func kind(of urls: [URL]) -> WheelKind {
        (!urls.isEmpty && urls.allSatisfy { isArchive($0) }) ? .extract : .compress
    }

    // Nikoli ne prepiše: "ime.zip", "ime 2.zip", "ime 3.zip" …
    nonisolated static func uniqueURL(in dir: URL, name: String, ext: String?) -> URL {
        func make(_ n: String) -> URL {
            if let ext = ext {
                return dir.appendingPathComponent("\(n).\(ext)")
            }
            return dir.appendingPathComponent(n, isDirectory: true)
        }
        var candidate = make(name)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(name) \(i)")
            i += 1
        }
        return candidate
    }

    nonisolated static func baseName(ofArchive name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty ? "Extracted" : stripped
    }

    nonisolated static func run(_ executable: String, _ arguments: [String],
                                onLine: (@Sendable (String) -> Void)? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"   // brez ._ datotek v tar
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        job.lock.lock()
        if job.cancelled { job.lock.unlock(); throw Cancelled() }
        try p.run()
        job.process = p
        job.lock.unlock()
        // stderr beremo sproti (za napredek); hranimo samo zadnji del za sporočilo o napaki
        var pending = Data()
        var tail = Data()
        let handle = err.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            tail.append(chunk)
            if tail.count > 8192 { tail = tail.suffix(8192) }
            guard let onLine = onLine else { continue }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending = Data(pending[(nl + 1)...])
                if let text = String(data: line, encoding: .utf8) { onLine(text) }
            }
        }
        p.waitUntilExit()
        job.lock.lock()
        job.process = nil
        let wasCancelled = job.cancelled
        job.lock.unlock()
        if wasCancelled { throw Cancelled() }
        if p.terminationStatus != 0 {
            let text = String(data: tail, encoding: .utf8) ?? ""
            throw Failure(message: "\(executable) exit \(p.terminationStatus): \(text)")
        }
    }

    // MARK: Napredek

    // Kar vidi uporabnik: delež (če ga znamo izračunati), zapisana velikost ali pretečeni čas.
    nonisolated struct Readout: Sendable {
        var fraction: Double?
        var bytes: Int64?
        var elapsed: TimeInterval
    }

    nonisolated final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [String: Int64] = [:]
        private var total: Int64 = 0
        private var done: Int64 = 0
        private var previous: Int64 = 0
        private(set) var fileCount = 0
        private(set) var usable = false

        // Pregleda vhodne predmete. Pri več kot 50 000 vnosih odneha (delež ni na voljo).
        init(_ urls: [URL]) {
            var seen = 0
            func add(_ file: URL, base: String) {
                guard let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      v.isRegularFile == true else { return }
                let size = Int64(v.fileSize ?? 0)
                let path = file.path
                guard path.hasPrefix(base) else { return }
                sizes[String(path.dropFirst(base.count))] = size
                total += size
                fileCount += 1
            }
            for u in urls {
                let base = u.deletingLastPathComponent().path + "/"
                if Archiver.isDirectory(u) {
                    guard let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil) else { continue }
                    while let f = en.nextObject() as? URL {
                        seen += 1
                        if seen > 50_000 { return }
                        add(f, base: base)
                    }
                } else {
                    add(u, base: base)
                }
            }
            usable = true
        }

        // Vrstica "a pot" pomeni, da je tar začel naslednji vnos; prejšnji je končan.
        func line(_ text: String) {
            guard text.hasPrefix("a ") else { return }
            let name = String(text.dropFirst(2))
            lock.lock()
            done += previous
            previous = sizes[name] ?? 0
            lock.unlock()
        }

        func reset() {
            lock.lock(); done = 0; previous = 0; lock.unlock()
        }

        var fraction: Double? {
            lock.lock(); defer { lock.unlock() }
            guard usable, fileCount > 1, total > 0 else { return nil }
            return min(Double(done) / Double(total), 0.99)
        }
    }

    // Vsake pol sekunde sporoči napredek, dokler posel teče.
    private nonisolated static func startReporter(output: URL?, meter: Meter?,
                                                   report: @escaping (Readout) -> Void) -> DispatchSourceTimer {
        let start = Date()
        nonisolated(unsafe) let report = report
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler {
            var size: Int64? = nil
            if let output = output,
               let v = try? output.resourceValues(forKeys: [.fileSizeKey]), let n = v.fileSize {
                size = Int64(n)
            }
            report(Readout(fraction: meter?.fraction, bytes: size, elapsed: Date().timeIntervalSince(start)))
        }
        t.resume()
        return t
    }

    // Končnice, ki jih ponovno stiskanje skoraj ne zmanjša
    nonisolated static let compressedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "mpg", "mpeg",
        "jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "gif",
        "mp3", "m4a", "aac", "flac", "ogg", "opus", "wma",
        "zip", "7z", "gz", "tgz", "bz2", "xz", "rar", "dmg"
    ]

    // Ali je vsaj 90 % podatkov že stisnjenih (po končnicah). Pri veliki mapi odneha in vrne false.
    nonisolated static func isMostlyCompressed(_ urls: [URL]) -> Bool {
        var packed: Int64 = 0
        var total: Int64 = 0
        var seen = 0
        func add(_ file: URL) {
            guard let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true else { return }
            let size = Int64(v.fileSize ?? 0)
            total += size
            if compressedExtensions.contains(file.pathExtension.lowercased()) { packed += size }
        }
        for u in urls {
            if isDirectory(u) {
                guard let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil) else { continue }
                while let f = en.nextObject() as? URL {
                    seen += 1
                    if seen > 50_000 { return false }
                    add(f)
                }
            } else {
                add(u)
            }
        }
        return total > 0 && Double(packed) / Double(total) >= 0.9
    }

    // Možnosti libarchive (--options). Če jih tar ne pozna, se stiskanje ponovi brez njih.
    nonisolated static func tarOptions(for format: ArchiveFormat, level: CompressionLevel, store: Bool) -> [String] {
        let module: String
        switch format {
        case .zip: module = "zip"
        case .sevenZ: module = "7zip"
        case .tarGz: module = "gzip"
        }
        if store {
            switch format {
            case .zip: return ["zip:compression=store"]
            case .sevenZ: return ["7zip:compression=copy"]
            case .tarGz: return ["gzip:compression-level=0"]
            }
        }
        switch level {
        case .fast: return ["\(module):compression-level=1"]
        case .balanced: return []
        case .best: return ["\(module):compression-level=9"]
        }
    }

    nonisolated static func runTar(_ urls: [URL], as format: ArchiveFormat, to out: URL, options: [String],
                                   meter: Meter? = nil) throws {
        var args = ["--exclude", ".DS_Store"]
        if meter != nil { args.append("-v") }
        for o in options { args += ["--options", o] }
        switch format {
        case .zip: args += ["--format", "zip", "-cf", out.path]
        case .sevenZ: args += ["--format", "7zip", "-cf", out.path]
        case .tarGz: args += ["-czf", out.path]
        }
        for u in urls {
            args += ["-C", u.deletingLastPathComponent().path, u.lastPathComponent]
        }
        if let meter = meter {
            try run("/usr/bin/tar", args, onLine: { meter.line($0) })
        } else {
            try run("/usr/bin/tar", args)
        }
    }

    // Stisne vse predmete v en arhiv poleg prvega predmeta (ali v izbrano mapo).
    @discardableResult
    nonisolated static func compress(_ urls: [URL], as format: ArchiveFormat, into destination: URL? = nil,
                                     progress: ((Readout) -> Void)? = nil) throws -> URL {
        guard let first = urls.first else { throw Failure(message: "nothing to compress") }
        let parent = destination ?? first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.lastPathComponent : "Archive"
        let out = uniqueURL(in: parent, name: base, ext: format.ext)

        let meter: Meter? = progress != nil ? Meter(urls) : nil
        let reporter = progress.map { startReporter(output: out, meter: meter, report: $0) }
        defer { reporter?.cancel() }

        do {
            if format == .zip && urls.count == 1 && !CompressionSettings.crossPlatformZip {
                // en predmet: ditto, enako kot Finder (doda __MACOSX, če so razširjeni atributi)
                try run("/usr/bin/ditto",
                        ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            } else {
                let store = CompressionSettings.storeCompressed && isMostlyCompressed(urls)
                let options = tarOptions(for: format, level: CompressionSettings.level, store: store)
                do {
                    try runTar(urls, as: format, to: out, options: options, meter: meter)
                } catch {
                    if error is Cancelled || options.isEmpty { throw error }
                    try? FileManager.default.removeItem(at: out)
                    meter?.reset()
                    try runTar(urls, as: format, to: out, options: [], meter: meter)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    // Razpakira v novo mapo z imenom arhiva. destination == nil: poleg arhiva.
    @discardableResult
    nonisolated static func extract(_ archive: URL, into destination: URL?,
                                    progress: ((Readout) -> Void)? = nil) throws -> URL {
        let parent = destination ?? archive.deletingLastPathComponent()
        let folder = uniqueURL(in: parent, name: baseName(ofArchive: archive.lastPathComponent), ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let reporter = progress.map { startReporter(output: nil, meter: nil, report: $0) }
        defer { reporter?.cancel() }
        do {
            try run("/usr/bin/tar", ["-xf", archive.path, "-C", folder.path])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    nonisolated static func log(_ error: Error) {
        if error is Cancelled { return }
        if let f = error as? Failure {
            NSLog("Archivator error: %@", f.message)
        } else {
            NSLog("Archivator error: %@", String(describing: error))
        }
    }
}
