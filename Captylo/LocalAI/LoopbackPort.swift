import Darwin
import Foundation

/// A free TCP port on 127.0.0.1, picked by the kernel (bind to port 0, read it back, close).
/// Another process could take it before llama-server binds; `LlamaServer` then retries.
enum LoopbackPort {
    struct Unavailable: Error {}

    static func free() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw Unavailable() }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw Unavailable() }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else { throw Unavailable() }
        let port = Int(UInt16(bigEndian: address.sin_port))
        guard port > 0 else { throw Unavailable() }
        return port
    }
}
