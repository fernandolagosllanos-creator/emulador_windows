import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Cliente mínimo y síncrono del protocolo QMP de QEMU sobre un socket Unix.
/// Cada llamada abre su propia conexión: es lo más simple y QEMU acepta conexiones sucesivas.
public final class QMPClient {
    private let fd: Int32
    private var buffer = Data()

    public init(socketPath: String, timeout: TimeInterval = 5) throws {
        #if canImport(Darwin)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw VMError.qmp("no se pudo crear el socket") }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        // En los errores no se cierra fd aquí: deinit lo cierra.
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw VMError.qmp("ruta de socket demasiado larga: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw VMError.qmp("no se pudo conectar a \(socketPath)")
        }
        _ = try readMessage() // saludo {"QMP": ...}
        _ = try execute("qmp_capabilities")
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// Ejecuta un comando QMP y devuelve el campo "return".
    @discardableResult
    public func execute(_ command: String, arguments: [String: Any]? = nil) throws -> Any? {
        var message: [String: Any] = ["execute": command]
        if let arguments { message["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw VMError.qmp("escritura incompleta") }

        while true {
            let reply = try readMessage()
            if reply["event"] != nil { continue } // los eventos asíncronos no son la respuesta
            if let error = reply["error"] as? [String: Any] {
                throw VMError.qmp(error["desc"] as? String ?? "error desconocido")
            }
            return reply["return"]
        }
    }

    /// Comando del monitor humano (HMP); se usa para savevm/loadvm/delvm.
    @discardableResult
    public func humanMonitorCommand(_ line: String) throws -> String {
        let output = try execute("human-monitor-command", arguments: ["command-line": line]) as? String ?? ""
        if output.lowercased().contains("error") {
            throw VMError.qmp(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw VMError.qmp("respuesta no válida")
                }
                return object
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw VMError.qmp("conexión cerrada o sin respuesta") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
