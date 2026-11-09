import Darwin
import Foundation

/// `<runDirectory>/<modelID>.pid` with the pid and the executable path of a running server,
/// so the next launch can stop a server a crashed run left behind (it would hold gigabytes).
/// A recorded pid is only killed while it still runs the recorded executable: pids get
/// reused, and other llama-server binaries on the Mac are never touched.
enum LlamaPIDFile {
    static let fileExtension = "pid"

    static func url(modelID: String, in directory: URL) -> URL {
        directory.appending(path: "\(modelID).\(fileExtension)", directoryHint: .notDirectory)
    }

    static func write(pid: Int32, executable: URL, modelID: String, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "\(pid)\n\(executable.path(percentEncoded: false))\n"
        try? Data(text.utf8).write(to: url(modelID: modelID, in: directory), options: .atomic)
    }

    static func remove(modelID: String, in directory: URL) {
        try? FileManager.default.removeItem(at: url(modelID: modelID, in: directory))
    }

    /// Kills the process a pid file names when it still runs that executable, then removes
    /// the file. Returns whether a process was killed.
    @discardableResult
    static func killStale(at file: URL) -> Bool {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2, let pid = Int32(lines[0]), pid > 1 else { return false }
        let recordedPath = String(lines[1])
        guard executablePath(of: pid) == recordedPath else { return false }
        return Darwin.kill(pid, SIGKILL) == 0
    }

    /// Stops every stale server recorded in `directory` (at launch, before any server starts).
    @discardableResult
    static func sweep(_ directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == fileExtension }.reduce(0) { $0 + (killStale(at: $1) ? 1 : 0) }
    }

    /// Path of the executable a live process runs, nil when there is no such process.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
