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

    // Stisne vse predmete v en arhiv poleg prvega predmeta.
    @discardableResult
    nonisolated static func compress(_ urls: [URL], as format: ArchiveFormat) throws -> URL {
        guard let first = urls.first else { throw Failure(message: "nothing to compress") }
        let parent = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.lastPathComponent : "Archive"
        let out = uniqueURL(in: parent, name: base, ext: format.ext)

        do {
            switch format {
            case .zip where urls.count == 1:
                // en predmet: ditto, enako kot Finder
                try run("/usr/bin/ditto",
                        ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            case .zip, .sevenZ, .tarGz:
                // ditto ne zna več virov naenkrat, zato več predmetov gre prek bsdtar
                var args = ["--exclude", ".DS_Store"]
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
