import Foundation

/// Carpeta `<id>.paralelovm` que contiene todo lo persistente de una VM.
public struct VMBundle: Sendable {
    public let url: URL
    public var configuration: VMConfiguration

    public static let fileExtension = "paralelovm"

    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var diskURL: URL { url.appendingPathComponent("disk.qcow2") }
    /// Variables UEFI en qcow2 (en raw, `savevm` falla porque pflash no admite snapshots).
    public var efiVarsURL: URL { url.appendingPathComponent("efi_vars.qcow2") }
    public var tpmStateURL: URL { url.appendingPathComponent("tpm", isDirectory: true) }
    public var logURL: URL { url.appendingPathComponent("qemu.log") }
    /// ISO de herramientas (unidad PARALELO en Windows) con setup-windows.ps1.
    /// El número de versión fuerza a regenerar la ISO cuando cambia su contenido.
    public var toolsISOURL: URL { url.appendingPathComponent("paralelo-tools-v\(GuestTools.version).iso") }
    public var rdpDirectoryURL: URL { url.appendingPathComponent("rdp", isDirectory: true) }
    /// Clave SSH privada de la VM; la pública (.pub) va en la ISO de herramientas.
    public var sshKeyURL: URL { url.appendingPathComponent("ssh/id_ed25519") }
    /// Iconos PNG de las apps de Coherence, uno por app (<id>.png).
    public var iconsDirectoryURL: URL { url.appendingPathComponent("icons", isDirectory: true) }

    public func iconURL(for app: RemoteApp) -> URL {
        iconsDirectoryURL.appendingPathComponent("\(app.id.uuidString).png")
    }

    /// Icono de la app si ya se obtuvo de Windows.
    public func icon(for app: RemoteApp) -> Data? {
        try? Data(contentsOf: iconURL(for: app))
    }

    public func saveIcon(_ png: Data, for app: RemoteApp) throws {
        try FileManager.default.createDirectory(at: iconsDirectoryURL, withIntermediateDirectories: true)
        try png.write(to: iconURL(for: app), options: .atomic)
    }

    public var runtime: RuntimePaths { RuntimePaths(shortID: configuration.shortID) }

    public init(url: URL, configuration: VMConfiguration) {
        self.url = url
        self.configuration = configuration
    }

    public static func load(from url: URL) throws -> VMBundle {
        let data = try Data(contentsOf: url.appendingPathComponent("config.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: data)
        return VMBundle(url: url, configuration: config)
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(configuration).write(to: configURL, options: .atomic)
    }
}

/// Rutas efímeras (sockets y pid). Viven en /tmp porque las rutas de sockets Unix tienen un límite de ~104 bytes
/// y "~/Library/Application Support/..." lo supera con facilidad.
public struct RuntimePaths: Sendable {
    public let directory: URL

    public init(shortID: String, base: URL = URL(fileURLWithPath: "/tmp/paralelo-\(getuid())")) {
        directory = base.appendingPathComponent(shortID, isDirectory: true)
    }

    public var qmpSocket: URL { directory.appendingPathComponent("qmp.sock") }
    public var tpmSocket: URL { directory.appendingPathComponent("tpm.sock") }
    /// Pantalla de la VM por VNC, para verla dentro de Paralelo.
    public var vncSocket: URL { directory.appendingPathComponent("vnc.sock") }
    public var pidFile: URL { directory.appendingPathComponent("qemu.pid") }

    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
