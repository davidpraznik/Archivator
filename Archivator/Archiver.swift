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

    nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
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
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        job.lock.lock()
        job.process = nil
        let wasCancelled = job.cancelled
        job.lock.unlock()
        if wasCancelled { throw Cancelled() }
        if p.terminationStatus != 0 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Failure(message: "\(executable) exit \(p.terminationStatus): \(text)")
        }
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

    nonisolated static func runTar(_ urls: [URL], as format: ArchiveFormat, to out: URL, options: [String]) throws {
        var args = ["--exclude", ".DS_Store"]
        for o in options { args += ["--options", o] }
        switch format {
        case .zip: args += ["--format", "zip", "-cf", out.path]
        case .sevenZ: args += ["--format", "7zip", "-cf", out.path]
        case .tarGz: args += ["-czf", out.path]
        }
        for u in urls {
            args += ["-C", u.deletingLastPathComponent().path, u.lastPathComponent]
        }
        try run("/usr/bin/tar", args)
    }

    // Stisne vse predmete v en arhiv poleg prvega predmeta (ali v izbrano mapo).
    @discardableResult
    nonisolated static func compress(_ urls: [URL], as format: ArchiveFormat, into destination: URL? = nil) throws -> URL {
        guard let first = urls.first else { throw Failure(message: "nothing to compress") }
        let parent = destination ?? first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.lastPathComponent : "Archive"
        let out = uniqueURL(in: parent, name: base, ext: format.ext)

        do {
            if format == .zip && urls.count == 1 && !CompressionSettings.crossPlatformZip {
                // en predmet: ditto, enako kot Finder (doda __MACOSX, če so razširjeni atributi)
                try run("/usr/bin/ditto",
                        ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            } else {
                let store = CompressionSettings.storeCompressed && isMostlyCompressed(urls)
                let options = tarOptions(for: format, level: CompressionSettings.level, store: store)
                do {
                    try runTar(urls, as: format, to: out, options: options)
                } catch {
                    if error is Cancelled || options.isEmpty { throw error }
                    try? FileManager.default.removeItem(at: out)
                    try runTar(urls, as: format, to: out, options: [])
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
    nonisolated static func extract(_ archive: URL, into destination: URL?) throws -> URL {
        let parent = destination ?? archive.deletingLastPathComponent()
        let folder = uniqueURL(in: parent, name: baseName(ofArchive: archive.lastPathComponent), ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
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
