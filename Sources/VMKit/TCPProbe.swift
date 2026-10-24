import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Comprobaciones de servicios de Windows a través de los puertos redirigidos por QEMU.
/// QEMU acepta la conexión aunque Windows no escuche todavía, así que hay que leer una respuesta real.
enum TCPProbe {
    /// Conecta a host:port, envía `request` (si hay) y devuelve los primeros bytes recibidos.
    static func exchange(port: Int, host: String = "127.0.0.1", request: [UInt8] = [],
                         timeoutSeconds: Int = 3) -> [UInt8]? {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        if !request.isEmpty {
            let sent = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard sent == request.count else { return nil }
        }
        var reply = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &reply, reply.count)
        guard n > 0 else { return nil }
        return Array(reply.prefix(n))
    }
}
