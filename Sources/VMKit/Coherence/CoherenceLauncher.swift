import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Abre apps de Windows (o el escritorio completo) como ventanas del Mac vía RDP.
public struct CoherenceLauncher {
    public var controller: VMController
    public var password: String?

    public init(controller: VMController, password: String? = nil) {
        self.controller = controller
        self.password = password
    }

    /// Arranca la VM sin ventana si hace falta, espera a que Windows acepte RDP y abre la app.
    /// `app == nil` abre el escritorio completo. `progress` recibe cada paso para mostrarlo.
    public func open(app: RemoteApp?, bootTimeout: TimeInterval = 180,
                     progress: (String) -> Void = { _ in }) throws {
        if !controller.isRunning {
            progress("Arrancando Windows sin ventana…")
            try controller.start(display: .headless, bootFromInstaller: false)
        } else if controller.state() == .paused {
            try controller.resume()
        }
        let port = controller.bundle.configuration.rdpPort
        if !Self.rdpIsReady(port: port) {
            progress("Esperando a que Windows termine de arrancar (puede tardar hasta \(Int(bootTimeout / 60)) min)…")
            guard ProcessRunner.waitFor(timeout: bootTimeout, interval: 2, { Self.rdpIsReady(port: port) }) else {
                throw VMError.timeout("Windows no respondió por RDP en el puerto \(port). ¿Ejecutaste setup-windows.ps1 (unidad PARALELO) dentro de Windows?")
            }
        }
        progress("Abriendo \(app?.name ?? "el escritorio de Windows")…")
        switch controller.bundle.configuration.coherence.client {
        case .windowsApp: try openWithWindowsApp(app: app)
        case .freeRDP: try openWithFreeRDP(app: app)
        }
    }

    private func openWithWindowsApp(app: RemoteApp?) throws {
        let bundle = controller.bundle
        try FileManager.default.createDirectory(at: bundle.rdpDirectoryURL, withIntermediateDirectories: true)
        let url = bundle.rdpDirectoryURL.appendingPathComponent("\(app?.fileName ?? "Escritorio").rdp")
        try RDPFile(configuration: bundle.configuration, app: app).write(to: url)
        // Siempre por bundle id: "Windows App" y el antiguo "Microsoft Remote Desktop" comparten
        // com.microsoft.rdc.macos. Nunca se usa la app asociada a .rdp, porque puede ser otra
        // (p. ej. Parallels la registra y abre el archivo dentro de su propia VM).
        let open = URL(fileURLWithPath: "/usr/bin/open")
        let result = try ProcessRunner.run(open, ["-b", Self.windowsAppBundleID, url.path])
        guard result.status == 0 else {
            throw VMError.dependencyMissing("Windows App de Microsoft (instálala desde la App Store) o elige FreeRDP como cliente")
        }
    }

    static let windowsAppBundleID = "com.microsoft.rdc.macos"

    private func openWithFreeRDP(app: RemoteApp?) throws {
        guard let binary = Self.findFreeRDP(remoteApp: app != nil) else { throw VMError.dependencyMissing("FreeRDP (brew install freerdp)") }
        let config = controller.bundle.configuration
        var args = Self.freeRDPArguments(configuration: config, app: app)
        if let password, !password.isEmpty { args.append("/p:\(password)") }
        _ = try ProcessRunner.launch(binary, args, log: controller.bundle.url.appendingPathComponent("freerdp.log"))
    }

    public static func freeRDPArguments(configuration config: VMConfiguration, app: RemoteApp?,
                                        homeFolder: String = NSHomeDirectory()) -> [String] {
        var args = ["/v:127.0.0.1:\(config.rdpPort)", "/cert:ignore", "+clipboard"]
        if !config.coherence.username.isEmpty { args.append("/u:\(config.coherence.username)") }
        if config.coherence.shareHomeFolder { args.append("/drive:Mac,\(homeFolder)") }
        if let app {
            var spec = "program:\(app.program),name:\(app.name)"
            if !app.arguments.isEmpty { spec += ",cmd:\(app.arguments)" }
            args.append("/app:\(spec)")
        } else {
            args += ["/dynamic-resolution", "/size:1440x900"]
        }
        return args
    }

    /// Para RemoteApp se prefiere el cliente X11 (xfreerdp, necesita XQuartz): el cliente SDL
    /// no implementa bien las ventanas sueltas de RemoteApp.
    static func findFreeRDP(remoteApp: Bool) -> URL? {
        let x11 = ["xfreerdp3", "xfreerdp"], sdl = ["sdl-freerdp3", "sdl-freerdp"]
        let names = remoteApp ? x11 + sdl : sdl + x11
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            for name in names {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// QEMU acepta conexiones en el puerto redirigido aunque Windows no escuche todavía,
    /// así que se envía una petición de conexión RDP (X.224) y se espera la respuesta TPKT.
    public static func rdpIsReady(port: Int, host: String = "127.0.0.1") -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
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
        guard connected == 0 else { return false }

        let request = rdpConnectionRequest
        let sent = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == request.count else { return false }
        var reply = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &reply, reply.count)
        return n >= 4 && reply[0] == 0x03 && reply[1] == 0x00
    }

    /// TPKT + X.224 Connection Request + RDP_NEG_REQ (TLS | CredSSP).
    static let rdpConnectionRequest: [UInt8] = [
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00,
    ]
}
