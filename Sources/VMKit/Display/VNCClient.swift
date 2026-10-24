import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Cliente VNC (RFB 3.8) mínimo para ver la pantalla de la VM dentro de Paralelo.
/// QEMU publica la pantalla en un socket Unix privado, así que no hay contraseña ni red de por medio.
/// Solo usa codificación Raw y CopyRect: por un socket local el ancho de banda sobra.
/// El teclado va como scancodes de PC (extensión de QEMU), así Windows aplica su propia distribución.
public final class VNCClient: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case connecting
        case connected(width: Int, height: Int)
        case disconnected(String)
    }

    /// Imagen completa en BGRA (4 bytes por píxel, sin relleno entre filas).
    public struct Frame: Sendable {
        public let width: Int
        public let height: Int
        public let pixels: Data
    }

    public let socketPath: String
    /// Se llaman desde el hilo de lectura, no desde el principal.
    public var onFrame: (@Sendable (Frame) -> Void)?
    public var onStatus: (@Sendable (Status) -> Void)?

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Conecta en segundo plano y reintenta cada segundo (la VM puede no estar encendida todavía).
    public func start() {
        let thread = Thread { [self] in runLoop() }
        thread.name = "VNC \(socketPath)"
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopped = true
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)) }
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func runLoop() {
        var lastError = ""
        while !isStopped {
            onStatus?(.connecting)
            do {
                try session()
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            if isStopped { break }
            onStatus?(.disconnected(lastError))
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: Entrada

    /// Botones: bit 0 izquierdo, 1 central, 2 derecho, 3 rueda arriba, 4 rueda abajo.
    public func sendPointer(x: Int, y: Int, buttons: UInt8) {
        transmit(VNCMessages.pointerEvent(x: x, y: y, buttons: buttons))
    }

    /// `scancode` es el código XT de la tecla (0xE0 xx se escribe 0x80 | xx).
    public func sendKey(scancode: UInt32, down: Bool) {
        transmit(VNCMessages.qemuKeyEvent(scancode: scancode, down: down))
    }

    private func transmit(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        _ = Self.writeAll(fd, bytes)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    // MARK: Sesión

    private func session() throws {
        let sock = try Self.openSocket(socketPath)
        lock.lock()
        if stopped {
            lock.unlock()
            close(sock)
            return
        }
        fd = sock
        lock.unlock()
        defer {
            lock.lock()
            close(sock)
            fd = -1
            lock.unlock()
        }
        let io = SocketReader(fd: sock)
        func send(_ bytes: [UInt8]) throws {
            lock.lock()
            let ok = Self.writeAll(sock, bytes)
            lock.unlock()
            if !ok { throw VNCError("se cortó la conexión") }
        }

        guard try io.bytes(12).starts(with: Array("RFB ".utf8)) else { throw VNCError("el servidor no habla VNC") }
        try send(Array("RFB 003.008\n".utf8))
        let typeCount = Int(try io.u8())
        if typeCount == 0 {
            let length = Int(try io.u32())
            throw VNCError(String(decoding: try io.bytes(length), as: UTF8.self))
        }
        guard try io.bytes(typeCount).contains(1) else { throw VNCError("el servidor VNC pide contraseña") }
        try send([1])
        guard try io.u32() == 0 else { throw VNCError("el servidor VNC rechazó la conexión") }
        try send([1]) // ClientInit: sesión compartida

        var framebuffer = Framebuffer(width: Int(try io.u16()), height: Int(try io.u16()))
        _ = try io.bytes(16) // formato de píxel del servidor; se pide otro a continuación
        _ = try io.bytes(Int(try io.u32())) // nombre
        try send(VNCMessages.setPixelFormatBGRA())
        try send(VNCMessages.setEncodings(VNCMessages.encodings))
        onStatus?(.connected(width: framebuffer.width, height: framebuffer.height))
        try send(VNCMessages.updateRequest(incremental: false, width: framebuffer.width, height: framebuffer.height))

        while !isStopped {
            switch try io.u8() {
            case 0: // FramebufferUpdate
                _ = try io.u8()
                var full = false
                for _ in 0..<Int(try io.u16()) {
                    let x = Int(try io.u16()), y = Int(try io.u16())
                    let w = Int(try io.u16()), h = Int(try io.u16())
                    let encoding = Int32(bitPattern: try io.u32())
                    switch encoding {
                    case VNCMessages.raw:
                        framebuffer.blit(try io.bytes(w * h * 4), x: x, y: y, width: w, height: h)
                    case VNCMessages.copyRect:
                        let sx = Int(try io.u16()), sy = Int(try io.u16())
                        framebuffer.copy(fromX: sx, fromY: sy, toX: x, toY: y, width: w, height: h)
                    case VNCMessages.desktopSize:
                        framebuffer = Framebuffer(width: w, height: h)
                        full = true
                        onStatus?(.connected(width: w, height: h))
                    case VNCMessages.qemuExtendedKey:
                        break
                    default:
                        throw VNCError("codificación VNC no soportada (\(encoding))")
                    }
                }
                onFrame?(framebuffer.frame())
                try send(VNCMessages.updateRequest(incremental: !full, width: framebuffer.width, height: framebuffer.height))
            case 1: // SetColourMapEntries (no se usa con color verdadero)
                _ = try io.bytes(3)
                _ = try io.bytes(Int(try io.u16()) * 6)
            case 2: // Bell
                break
            case 3: // ServerCutText
                _ = try io.bytes(3)
                _ = try io.bytes(Int(try io.u32()))
            case let type:
                throw VNCError("mensaje VNC desconocido (\(type))")
            }
        }
    }

    static func openSocket(_ path: String) throws -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw VNCError("no se pudo crear el socket") }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw VNCError("ruta de socket demasiado larga")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw VNCError("la VM no está encendida")
        }
        return fd
    }
}

struct VNCError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Lectura con búfer de un socket bloqueante.
final class SocketReader {
    private let fd: Int32
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)
    private var start = 0, end = 0

    init(fd: Int32) {
        self.fd = fd
    }

    func bytes(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            if start == end {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { throw VNCError("se cortó la conexión") }
                start = 0
                end = n
            }
            let take = min(count - out.count, end - start)
            out.append(contentsOf: buffer[start..<start + take])
            start += take
        }
        return out
    }

    func u8() throws -> UInt8 { try bytes(1)[0] }
    func u16() throws -> UInt16 { try bytes(2).reduce(0) { $0 << 8 | UInt16($1) } }
    func u32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
}

/// Copia local de la pantalla en BGRA.
struct Framebuffer {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    mutating func blit(_ data: [UInt8], x: Int, y: Int, width w: Int, height h: Int) {
        guard x >= 0, y >= 0, x + w <= width, y + h <= height, data.count >= w * h * 4 else { return }
        let rowBytes = w * 4
        pixels.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                for row in 0..<h {
                    let to = ((y + row) * width + x) * 4
                    dst.baseAddress!.advanced(by: to)
                        .copyMemory(from: src.baseAddress!.advanced(by: row * rowBytes), byteCount: rowBytes)
                }
            }
        }
    }

    mutating func copy(fromX sx: Int, fromY sy: Int, toX x: Int, toY y: Int, width w: Int, height h: Int) {
        guard sx >= 0, sy >= 0, x >= 0, y >= 0, sx + w <= width, sy + h <= height, x + w <= width, y + h <= height
        else { return }
        let rowBytes = w * 4
        // Si el destino está debajo del origen se copia de abajo arriba para no pisar filas aún sin copiar.
        let rows = y > sy ? Array((0..<h).reversed()) : Array(0..<h)
        pixels.withUnsafeMutableBytes { buf in
            for row in rows {
                let from = ((sy + row) * width + sx) * 4
                let to = ((y + row) * width + x) * 4
                buf.baseAddress!.advanced(by: to).copyMemory(from: buf.baseAddress!.advanced(by: from), byteCount: rowBytes)
            }
        }
    }

    func frame() -> VNCClient.Frame {
        VNCClient.Frame(width: width, height: height, pixels: Data(pixels))
    }
}

/// Mensajes del cliente al servidor (todos los enteros en big endian).
enum VNCMessages {
    static let raw: Int32 = 0
    static let copyRect: Int32 = 1
    static let desktopSize: Int32 = -223
    static let qemuExtendedKey: Int32 = -258
    static let encodings = [copyRect, raw, desktopSize, qemuExtendedKey]

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    /// 32 bits por píxel, little endian, rojo en el bit 16: en memoria queda B, G, R, X.
    static func setPixelFormatBGRA() -> [UInt8] {
        [0, 0, 0, 0,
         32, 24, 0, 1] + be16(255) + be16(255) + be16(255) + [16, 8, 0, 0, 0, 0]
    }

    static func setEncodings(_ list: [Int32]) -> [UInt8] {
        [2, 0] + be16(list.count) + list.flatMap { be32(UInt32(bitPattern: $0)) }
    }

    static func updateRequest(incremental: Bool, width: Int, height: Int) -> [UInt8] {
        [3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(width) + be16(height)
    }

    static func pointerEvent(x: Int, y: Int, buttons: UInt8) -> [UInt8] {
        [5, buttons] + be16(max(0, x)) + be16(max(0, y))
    }

    static func qemuKeyEvent(scancode: UInt32, down: Bool) -> [UInt8] {
        [255, 0] + be16(down ? 1 : 0) + be32(0) + be32(scancode)
    }
}
