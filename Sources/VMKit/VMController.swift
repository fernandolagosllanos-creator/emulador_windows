import Foundation

public enum VMState: String, Sendable {
    case stopped, running, paused, unknown

    public var label: String {
        switch self {
        case .stopped: return "Apagada"
        case .running: return "En ejecución"
        case .paused: return "En pausa"
        case .unknown: return "Desconocido"
        }
    }
}

public struct VMSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var date: Date
    /// Bytes de estado de RAM guardados; 0 si es un snapshot solo de disco (hecho con la VM apagada).
    public var vmStateSize: Int

    public var includesMemory: Bool { vmStateSize > 0 }

    /// Interpreta la salida de `qemu-img info --output=json`.
    public static func parse(qemuImgInfoJSON data: Data) throws -> [VMSnapshot] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let list = root["snapshots"] as? [[String: Any]] ?? []
        return list.map { entry in
            VMSnapshot(
                id: "\(entry["id"] ?? "")",
                name: entry["name"] as? String ?? "",
                date: Date(timeIntervalSince1970: (entry["date-sec"] as? NSNumber)?.doubleValue ?? 0),
                vmStateSize: (entry["vm-state-size"] as? NSNumber)?.intValue ?? 0)
        }
    }
}

/// Controla el ciclo de vida de una VM: arranque, pausa, apagado, snapshots y ajustes.
/// Las llamadas son síncronas; la interfaz las ejecuta fuera del hilo principal.
public final class VMController: @unchecked Sendable {
    public private(set) var bundle: VMBundle
    public let environment: QEMUEnvironment

    public init(bundle: VMBundle, environment: QEMUEnvironment) {
        self.bundle = bundle
        self.environment = environment
    }

    private var runtime: RuntimePaths { bundle.runtime }

    // MARK: Estado

    public var pid: pid_t? {
        guard let text = try? String(contentsOf: runtime.pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ProcessRunner.isAlive(pid: pid)
        else { return nil }
        return pid
    }

    public var isRunning: Bool { pid != nil }

    public func state() -> VMState {
        guard isRunning else { return .stopped }
        guard let status = try? qmp().execute("query-status") as? [String: Any],
              let value = status["status"] as? String
        else { return .unknown }
        switch value {
        case "running": return .running
        case "paused", "suspended": return .paused
        case "shutdown", "guest-panicked": return .stopped
        default: return .unknown
        }
    }

    private func qmp() throws -> QMPClient {
        try QMPClient(socketPath: runtime.qmpSocket.path)
    }

    // MARK: Ciclo de vida

    /// tpm-tis-device hace fallar a QEMU con HVF en Apple Silicon (HV_BAD_ARGUMENT al mapear su memoria).
    /// Mientras tanto Windows salta la comprobación de TPM con el autounattend.xml de las herramientas.
    public static let tpmSupported = false

    /// Arranca la VM. Si hay ISO de instalación, por defecto arranca desde ella
    /// (el instalador espera una tecla y, si no se pulsa, sigue al disco).
    public func start(display: DisplayMode, bootFromInstaller: Bool? = nil) throws {
        guard !isRunning else { throw VMError.alreadyRunning }
        let fm = FileManager.default
        try runtime.prepare()
        for stale in [runtime.qmpSocket, runtime.tpmSocket, runtime.pidFile] {
            try? fm.removeItem(at: stale)
        }

        // Log nuevo en cada arranque para que los errores mostrados sean solo de este intento.
        let previousLog = bundle.logURL.appendingPathExtension("1")
        try? fm.removeItem(at: previousLog)
        try? fm.moveItem(at: bundle.logURL, to: previousLog)

        if !fm.fileExists(atPath: bundle.toolsISOURL.path) {
            _ = try? GuestTools.buildISO(at: bundle.toolsISOURL)
        }
        let toolsISO = fm.fileExists(atPath: bundle.toolsISOURL.path) ? bundle.toolsISOURL : nil

        var tpmSocket: URL?
        let builder = { (tpm: URL?) in
            QEMUCommandBuilder(
                bundle: self.bundle, environment: self.environment, display: display,
                bootFromInstaller: bootFromInstaller ?? (self.bundle.configuration.installerISO != nil),
                tpmSocket: tpm, toolsISO: toolsISO)
        }

        if bundle.configuration.useTPM && Self.tpmSupported {
            guard let swtpm = environment.swtpm else { throw VMError.dependencyMissing("swtpm") }
            try fm.createDirectory(at: bundle.tpmStateURL, withIntermediateDirectories: true)
            let tpm = try ProcessRunner.launch(swtpm, builder(nil).swtpmArguments(), log: bundle.logURL)
            guard ProcessRunner.waitFor(timeout: 5, { fm.fileExists(atPath: runtime.tpmSocket.path) }) else {
                tpm.terminate()
                throw VMError.timeout("swtpm no creó su socket")
            }
            tpmSocket = runtime.tpmSocket
        }

        let qemu = try ProcessRunner.launch(environment.qemuSystem, builder(tpmSocket).arguments(), log: bundle.logURL)
        let ready = ProcessRunner.waitFor(timeout: 15, interval: 0.25) {
            !qemu.isRunning || (try? self.qmp()) != nil
        }
        guard qemu.isRunning else {
            throw VMError.commandFailed("QEMU terminó al arrancar:\n\(logTail())")
        }
        guard ready else { throw VMError.timeout("QEMU no respondió por QMP") }
    }

    public func pause() throws {
        guard isRunning else { throw VMError.notRunning }
        try qmp().execute("stop")
    }

    public func resume() throws {
        guard isRunning else { throw VMError.notRunning }
        try qmp().execute("cont")
    }

    /// Apagado ordenado: equivale a pulsar el botón de encendido (Windows se apaga solo).
    public func shutdown() throws {
        guard isRunning else { throw VMError.notRunning }
        try qmp().execute("system_powerdown")
    }

    /// Apagado forzado (como desenchufar).
    public func forceStop() throws {
        guard let pid else { throw VMError.notRunning }
        _ = try? qmp().execute("quit")
        if !ProcessRunner.waitFor(timeout: 5, { !ProcessRunner.isAlive(pid: pid) }) {
            kill(pid, SIGKILL)
        }
    }

    public func logTail(lines: Int = 20) -> String {
        let text = (try? String(contentsOf: bundle.logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    // MARK: Snapshots

    public func snapshots() throws -> [VMSnapshot] {
        // -U permite leer el disco aunque QEMU lo tenga bloqueado.
        let json = try ProcessRunner.check(environment.qemuImg, [
            "info", "-U", "--output=json", bundle.diskURL.path,
        ])
        return try VMSnapshot.parse(qemuImgInfoJSON: Data(json.utf8))
    }

    /// Con la VM encendida guarda disco + memoria (savevm); apagada, solo disco.
    public func createSnapshot(named name: String) throws {
        let name = try Self.validSnapshotName(name)
        if isRunning {
            try qmp().humanMonitorCommand("savevm \(name)")
        } else {
            try ProcessRunner.check(environment.qemuImg, ["snapshot", "-c", name, bundle.diskURL.path])
            try ProcessRunner.check(environment.qemuImg, ["snapshot", "-c", name, bundle.efiVarsURL.path])
        }
    }

    public func restoreSnapshot(named name: String) throws {
        let name = try Self.validSnapshotName(name)
        if isRunning {
            try qmp().humanMonitorCommand("loadvm \(name)")
        } else {
            try ProcessRunner.check(environment.qemuImg, ["snapshot", "-a", name, bundle.diskURL.path])
            // Las variables UEFI pueden no tener ese snapshot; no es grave.
            _ = try? ProcessRunner.run(environment.qemuImg, ["snapshot", "-a", name, bundle.efiVarsURL.path])
        }
    }

    public func deleteSnapshot(named name: String) throws {
        let name = try Self.validSnapshotName(name)
        if isRunning {
            try qmp().humanMonitorCommand("delvm \(name)")
        } else {
            try ProcessRunner.check(environment.qemuImg, ["snapshot", "-d", name, bundle.diskURL.path])
            _ = try? ProcessRunner.run(environment.qemuImg, ["snapshot", "-d", name, bundle.efiVarsURL.path])
        }
    }

    /// Los nombres van al monitor HMP, así que se limitan a caracteres seguros.
    public static func validSnapshotName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII })
        else {
            throw VMError.invalidConfiguration("el nombre del snapshot solo admite letras, números, '-', '_' y '.'")
        }
        return trimmed
    }

    // MARK: Ajustes

    /// Aplica cambios de configuración. CPU, RAM y disco solo con la VM apagada; el disco solo crece.
    public func update(_ change: (inout VMConfiguration) -> Void) throws {
        var config = bundle.configuration
        change(&config)
        try config.validate()
        let old = bundle.configuration
        let hardwareChanged = config.cpuCount != old.cpuCount || config.memoryMB != old.memoryMB
            || config.diskSizeGB != old.diskSizeGB || config.useTPM != old.useTPM
            || config.installerISO != old.installerISO || config.driversISO != old.driversISO
            || config.rdpPort != old.rdpPort
        if hardwareChanged && isRunning {
            throw VMError.invalidConfiguration("apaga la VM para cambiar el hardware")
        }
        if config.diskSizeGB < old.diskSizeGB {
            throw VMError.invalidConfiguration("el disco no se puede reducir")
        }
        if config.diskSizeGB > old.diskSizeGB {
            try ProcessRunner.check(environment.qemuImg, ["resize", bundle.diskURL.path, "\(config.diskSizeGB)G"])
        }
        bundle.configuration = config
        try bundle.save()
    }
}
