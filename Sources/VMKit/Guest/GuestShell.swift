import Foundation

/// Canal de control con Windows por SSH: OpenSSH Server, que activa setup-windows.ps1.
/// Usa una clave propia de cada VM (su parte pública va en la ISO de herramientas) y el puerto
/// `sshPort`, publicado solo en 127.0.0.1 del Mac.
public struct GuestShell: Sendable {
    public var bundle: VMBundle

    public init(bundle: VMBundle) {
        self.bundle = bundle
    }

    static let sshKeygen = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")
    static let scp = URL(fileURLWithPath: "/usr/bin/scp")

    /// Crea la clave de la VM si no existe y devuelve la clave pública (una línea).
    @discardableResult
    public static func ensureKey(for bundle: VMBundle) throws -> String {
        let fm = FileManager.default
        let key = bundle.sshKeyURL
        if !fm.fileExists(atPath: key.path) {
            try fm.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try ProcessRunner.check(sshKeygen, [
                "-q", "-t", "ed25519", "-N", "", "-C", "paralelo-\(bundle.configuration.shortID)", "-f", key.path,
            ])
        }
        let pub = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        return pub.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// El shell por defecto de OpenSSH en Windows es cmd.exe: arranca PowerShell y ejecuta
    /// el script que llega por la entrada estándar (así no hay límites de longitud ni problemas de comillas).
    static let powerShellCommand =
        #"powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "iex ([Console]::In.ReadToEnd())""#

    private var commonOptions: [String] {
        [
            "-i", bundle.sshKeyURL.path,
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
        ]
    }

    public func sshArguments(command: String) -> [String] {
        let config = bundle.configuration
        return commonOptions + [
            "-p", "\(config.sshPort)",
            "-l", config.coherence.username,
            "127.0.0.1",
            command,
        ]
    }

    /// scp no acepta espacios en "usuario@host" ("Fernando Lagos"): el usuario va como opción, entre comillas.
    /// Las rutas de Windows se escriben como las entiende su servidor SFTP: /C:/Users/...
    public func scpArguments(sources: [String], destination: String) -> [String] {
        let config = bundle.configuration
        let user = config.coherence.username.replacingOccurrences(of: "\"", with: "")
        return commonOptions + ["-P", "\(config.sshPort)", "-o", "User=\"\(user)\"", "-q", "-r"]
            + sources + [destination]
    }

    /// C:\Users\x → 127.0.0.1:/C:/Users/x. En los orígenes remotos, scp expande comodines: se escapan.
    public static func remotePath(_ windowsPath: String, escapingGlobs: Bool = false) -> String {
        var path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        if !path.hasPrefix("/") { path = "/" + path }
        if escapingGlobs {
            for c in ["*", "?", "["] { path = path.replacingOccurrences(of: c, with: "\\" + c) }
        }
        return "127.0.0.1:" + path
    }

    /// OpenSSH responde con su versión ("SSH-2.0-...") nada más conectar.
    public static func isReady(port: Int) -> Bool {
        guard let banner = TCPProbe.exchange(port: port) else { return false }
        return banner.starts(with: Array("SSH-".utf8))
    }

    /// Hay usuario, clave y Windows responde por SSH (sin esperar).
    public var isAvailable: Bool {
        !bundle.configuration.coherence.username.isEmpty
            && FileManager.default.fileExists(atPath: bundle.sshKeyURL.path)
            && Self.isReady(port: bundle.configuration.sshPort)
    }

    /// Ejecuta un script de PowerShell (solo ASCII) en Windows y devuelve su salida estándar.
    public func runPowerShell(_ script: String) throws -> String {
        try run(Self.powerShellCommand, input: Data(script.utf8))
    }

    /// Ejecuta un comando de cmd.exe en Windows; `input` llega por la entrada estándar.
    public func run(_ command: String, input: Data? = nil) throws -> String {
        try checkReady()

        var inputURL: URL?
        if let input {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("paralelo-\(UUID().uuidString).in")
            try input.write(to: url)
            inputURL = url
        }
        defer { if let inputURL { try? FileManager.default.removeItem(at: inputURL) } }

        let result = try ProcessRunner.run(Self.ssh, sshArguments(command: command), input: inputURL)
        try check(result, tool: "ssh")
        return result.stdout
    }

    /// Copia archivos o carpetas del Mac a una carpeta de Windows que ya existe.
    public func upload(_ items: [URL], toDirectory windowsDirectory: String) throws {
        guard !items.isEmpty else { return }
        try checkReady()
        let destination = Self.remotePath(windowsDirectory.hasSuffix("\\") ? windowsDirectory : windowsDirectory + "\\")
        try check(ProcessRunner.run(Self.scp, scpArguments(sources: items.map(\.path), destination: destination)), tool: "scp")
    }

    /// Copia archivos o carpetas de Windows a una carpeta del Mac.
    public func download(_ windowsPaths: [String], toDirectory directory: URL) throws {
        guard !windowsPaths.isEmpty else { return }
        try checkReady()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources = windowsPaths.map { Self.remotePath($0, escapingGlobs: true) }
        try check(ProcessRunner.run(Self.scp, scpArguments(sources: sources, destination: directory.path)), tool: "scp")
    }

    private func checkReady() throws {
        let config = bundle.configuration
        guard !config.coherence.username.isEmpty else {
            throw VMError.invalidConfiguration("escribe tu usuario de Windows en Coherence y pulsa Guardar")
        }
        guard FileManager.default.fileExists(atPath: bundle.sshKeyURL.path) else {
            throw VMError.notFound("la clave SSH de la VM; arranca la VM una vez y ejecuta setup-windows.ps1 de la unidad PARALELO")
        }
        guard Self.isReady(port: config.sshPort) else { throw Self.notConfigured }
    }

    private func check(_ result: ProcessRunner.Output, tool: String) throws {
        guard result.status != 0 else { return }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("Permission denied") && tool == "ssh" {
            throw VMError.commandFailed("Windows rechazó la clave de Paralelo para el usuario \"\(bundle.configuration.coherence.username)\". "
                + "Comprueba el usuario y vuelve a ejecutar setup-windows.ps1 de la unidad PARALELO.")
        }
        throw VMError.commandFailed("\(tool): \(detail.isEmpty ? "código \(result.status)" : detail)")
    }

    static let notConfigured = VMError.timeout(
        "Windows no responde al canal de control de Paralelo. Ejecuta (como Administrador) "
            + "setup-windows.ps1 de la unidad PARALELO, versión \(GuestTools.version) o posterior, y reinicia Windows.")
}
