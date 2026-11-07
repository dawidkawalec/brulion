import Foundation

/// One downloadable GGUF model: where it comes from, how big it is and how to check it.
/// Values for the shipped models live in `LocalModelCatalog`; tests build their own.
struct LocalModelSpec: Codable, Hashable, Identifiable, Sendable {
    /// Stable id used in settings, pid files and usage stats (never changes for a given file).
    let id: String
    /// Name shown in the app, e.g. "Bielik 1.5B v3 (Q8_0)".
    let displayName: String
    /// The role this model plays by default, nil for an alternative offered for testing.
    let defaultRole: LocalRole?
    /// Hugging Face repository, e.g. "speakleash/Bielik-1.5B-v3.0-Instruct-GGUF".
    let repository: String
    /// Pinned commit of the repository, so the file behind the URL never changes.
    let revision: String
    /// File name in the repository and on disk.
    let fileName: String
    /// Exact size in bytes (the download is checked against it).
    let bytes: Int64
    /// Lowercase hex SHA-256 of the file (Hugging Face `lfs.sha256`).
    let sha256: String
    /// Context window the server is started with when this model plays its default role.
    let contextLength: Int
    /// SPDX id of the model licence.
    let licence: String

    /// Approximate peak memory of llama-server with this model loaded (`LocalAITuning`).
    var approximateRAMBytes: Int64 {
        LocalAITuning.peakRAMBytes(modelID: id, fileBytes: bytes)
    }

    /// `https://huggingface.co/{repo}/resolve/{revision}/{file}` (or the same path on `base`,
    /// for tests). Hugging Face answers with a redirect to its CDN.
    func downloadURL(base: URL = LocalModelCatalog.downloadBase) -> URL {
        base.appending(path: repository)
            .appending(path: "resolve")
            .appending(path: revision)
            .appending(path: fileName)
    }
}
