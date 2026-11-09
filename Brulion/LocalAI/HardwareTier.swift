import Foundation

/// How much local AI a Mac gets, by its memory (PRD 6).
enum HardwareTier: String, Codable, Sendable {
    /// 16 GB and more: correction on Bielik 1.5B, AI features on Bielik Minitron 7B.
    case standard
    /// Under 16 GB (8 GB Macs): correction on 1.5B, AI features on 1.5B or in the cloud.
    /// Not tested on such hardware, so the app calls it experimental (PRD 8).
    case experimental
}
