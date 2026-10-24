import Foundation

/// Colección de VMs en disco: ~/Library/Application Support/Paralelo/VMs/<id>.paralelovm
public final class VMLibrary: @unchecked Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paralelo/VMs", isDirectory: true)
    }

    public init(root: URL = VMLibrary.defaultRoot) {
        self.root = root
    }

    public func list() -> [VMBundle] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == VMBundle.fileExtension }
            .compactMap { try? VMBundle.load(from: $0) }
            .sorted { $0.configuration.createdAt < $1.configuration.createdAt }
    }

    /// Busca por nombre exacto (sin distinguir mayúsculas) o por prefijo del id.
    public func find(_ query: String) throws -> VMBundle {
        let all = list()
        if let match = all.first(where: { $0.configuration.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return match
        }
        let lower = query.lowercased()
        let byID = all.filter { $0.configuration.id.uuidString.lowercased().hasPrefix(lower) }
        guard byID.count == 1, let match = byID.first else {
            throw VMError.notFound("máquina virtual \"\(query)\"")
        }
        return match
    }

    /// Primer puerto libre para RDP a partir de 33890 entre las VMs existentes.
    public func nextFreeRDPPort() -> Int {
        let used = Set(list().map(\.configuration.rdpPort))
        var port = 33890
        while used.contains(port) { port += 1 }
        return port
    }

    /// Crea la carpeta de la VM, el disco qcow2 y las variables UEFI.
    public func create(_ configuration: VMConfiguration, environment: QEMUEnvironment) throws -> VMBundle {
        var config = configuration
        try config.validate()
        if list().contains(where: { $0.configuration.name.caseInsensitiveCompare(config.name) == .orderedSame }) {
            throw VMError.invalidConfiguration("ya existe una VM llamada \"\(config.name)\"")
        }
        if let iso = config.installerISO, !FileManager.default.fileExists(atPath: iso) {
            throw VMError.notFound("ISO \(iso)")
        }
        if list().contains(where: { $0.configuration.rdpPort == config.rdpPort }) {
            config.rdpPort = nextFreeRDPPort()
        }

        let fm = FileManager.default
        let url = root.appendingPathComponent("\(config.id.uuidString).\(VMBundle.fileExtension)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url, configuration: config)
        do {
            try fm.createDirectory(at: bundle.tpmStateURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: bundle.rdpDirectoryURL, withIntermediateDirectories: true)
            try ProcessRunner.check(environment.qemuImg, [
                "create", "-f", "qcow2", bundle.diskURL.path, "\(config.diskSizeGB)G",
            ])
            try ProcessRunner.check(environment.qemuImg, [
                "convert", "-f", "raw", "-O", "qcow2",
                environment.firmwareVarsTemplate.path, bundle.efiVarsURL.path,
            ])
            try bundle.save()
            _ = try? GuestTools.buildISO(at: bundle.toolsISOURL, publicKey: try? GuestShell.ensureKey(for: bundle))
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return bundle
    }

    public func delete(_ bundle: VMBundle) throws {
        try FileManager.default.removeItem(at: bundle.url)
    }
}
