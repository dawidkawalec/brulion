import Foundation

/// Where model files live: `<modelsDirectory>/<fileName>` once verified, `<fileName>.part`
/// while downloading. A file counts as installed when its size matches the spec; it only
/// gets its final name after the SHA-256 check.
enum LocalModelFiles {
    static let partSuffix = ".part"

    static func fileURL(for spec: LocalModelSpec, in directory: URL) -> URL {
        directory.appending(path: spec.fileName, directoryHint: .notDirectory)
    }

    static func partURL(for spec: LocalModelSpec, in directory: URL) -> URL {
        directory.appending(path: spec.fileName + partSuffix, directoryHint: .notDirectory)
    }

    static func isInstalled(_ spec: LocalModelSpec, in directory: URL) -> Bool {
        size(of: fileURL(for: spec, in: directory)) == spec.bytes
    }

    /// Bytes of an unfinished download kept for resuming (0 when there is none).
    static func partialBytes(of spec: LocalModelSpec, in directory: URL) -> Int64 {
        size(of: partURL(for: spec, in: directory)) ?? 0
    }

    /// Size of a regular file, nil when it does not exist.
    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Models are downloadable again at any time, so they stay out of Time Machine backups.
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
