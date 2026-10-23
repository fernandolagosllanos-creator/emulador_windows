import Foundation

/// Configuración persistente de una máquina virtual (se guarda como config.json dentro del bundle).
public struct VMConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var cpuCount: Int
    public var memoryMB: Int
    public var diskSizeGB: Int
    /// ISO de instalación de Windows 11 ARM. Se quita cuando Windows ya está instalado.
    public var installerISO: String?
    /// ISO opcional con drivers (virtio-win), necesaria para la red virtio-net.
    public var driversISO: String?
    /// Puerto del Mac (127.0.0.1) que se redirige al RDP (3389) de Windows.
    public var rdpPort: Int
    /// Emula un TPM 2.0 con swtpm. Desactivado: ver `VMController.tpmSupported`.
    public var useTPM: Bool
    public var coherence: CoherenceSettings
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        cpuCount: Int = 4,
        memoryMB: Int = 8192,
        diskSizeGB: Int = 64,
        installerISO: String? = nil,
        driversISO: String? = nil,
        rdpPort: Int = 33890,
        useTPM: Bool = false,
        coherence: CoherenceSettings = CoherenceSettings(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.installerISO = installerISO
        self.driversISO = driversISO
        self.rdpPort = rdpPort
        self.useTPM = useTPM
        self.coherence = coherence
        self.createdAt = createdAt
    }

    /// Identificador corto usado para rutas de sockets (los sockets Unix en macOS admiten ~104 bytes).
    public var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw VMError.invalidConfiguration("El nombre no puede estar vacío.")
        }
        guard (1...64).contains(cpuCount) else {
            throw VMError.invalidConfiguration("CPU debe estar entre 1 y 64.")
        }
        guard memoryMB >= 2048 else {
            throw VMError.invalidConfiguration("Windows 11 necesita al menos 2048 MB de RAM (se recomiendan 4096+).")
        }
        guard diskSizeGB >= 32 else {
            throw VMError.invalidConfiguration("Windows 11 necesita al menos 32 GB de disco (se recomiendan 64+).")
        }
        guard (1024...65535).contains(rdpPort) else {
            throw VMError.invalidConfiguration("Puerto RDP fuera de rango.")
        }
    }
}

/// Ajustes del modo Coherence (apps de Windows como ventanas sueltas del Mac).
public struct CoherenceSettings: Codable, Equatable, Sendable {
    public var username: String
    public var client: RDPClientKind
    public var apps: [RemoteApp]
    /// Comparte la carpeta de inicio del Mac con Windows (aparece como unidad redirigida).
    public var shareHomeFolder: Bool

    public init(
        username: String = "",
        client: RDPClientKind = .windowsApp,
        apps: [RemoteApp] = RemoteApp.defaults,
        shareHomeFolder: Bool = true
    ) {
        self.username = username
        self.client = client
        self.apps = apps
        self.shareHomeFolder = shareHomeFolder
    }
}

public enum VMError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case notFound(String)
    case dependencyMissing(String)
    case alreadyRunning
    case notRunning
    case commandFailed(String)
    case qmp(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let m): return "Configuración no válida: \(m)"
        case .notFound(let m): return "No encontrado: \(m)"
        case .dependencyMissing(let m): return "Falta una dependencia: \(m). Ejecuta scripts/install-deps.sh."
        case .alreadyRunning: return "La máquina virtual ya está en ejecución."
        case .notRunning: return "La máquina virtual no está en ejecución."
        case .commandFailed(let m): return "Falló un comando: \(m)"
        case .qmp(let m): return "Error de QEMU: \(m)"
        case .timeout(let m): return "Tiempo de espera agotado: \(m)"
        }
    }
}
