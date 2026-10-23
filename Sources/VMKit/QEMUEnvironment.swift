import Foundation

/// Ubicación de los binarios y firmware de QEMU instalados (normalmente con Homebrew).
public struct QEMUEnvironment: Sendable {
    public var qemuSystem: URL
    public var qemuImg: URL
    public var swtpm: URL?
    /// Firmware UEFI de solo lectura (edk2-aarch64-code.fd).
    public var firmwareCode: URL
    /// Plantilla de variables UEFI (edk2-arm-vars.fd), se copia a cada VM.
    public var firmwareVarsTemplate: URL

    public init(qemuSystem: URL, qemuImg: URL, swtpm: URL?, firmwareCode: URL, firmwareVarsTemplate: URL) {
        self.qemuSystem = qemuSystem
        self.qemuImg = qemuImg
        self.swtpm = swtpm
        self.firmwareCode = firmwareCode
        self.firmwareVarsTemplate = firmwareVarsTemplate
    }

    public static let defaultPrefixes = ["/opt/homebrew", "/usr/local"]

    public static func detect(prefixes: [String] = defaultPrefixes) throws -> QEMUEnvironment {
        let fm = FileManager.default
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let binDirs = prefixes.map { "\($0)/bin" } + pathDirs

        func findBinary(_ name: String) -> URL? {
            binDirs.lazy
                .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { fm.isExecutableFile(atPath: $0.path) }
        }
        func findShared(_ name: String) -> URL? {
            prefixes.lazy
                .map { URL(fileURLWithPath: "\($0)/share/qemu/\(name)") }
                .first { fm.fileExists(atPath: $0.path) }
        }

        guard let qemu = findBinary("qemu-system-aarch64") else {
            throw VMError.dependencyMissing("qemu-system-aarch64")
        }
        guard let img = findBinary("qemu-img") else {
            throw VMError.dependencyMissing("qemu-img")
        }
        guard let code = findShared("edk2-aarch64-code.fd") else {
            throw VMError.dependencyMissing("firmware edk2-aarch64-code.fd")
        }
        guard let vars = findShared("edk2-arm-vars.fd") else {
            throw VMError.dependencyMissing("firmware edk2-arm-vars.fd")
        }
        return QEMUEnvironment(
            qemuSystem: qemu, qemuImg: img, swtpm: findBinary("swtpm"),
            firmwareCode: code, firmwareVarsTemplate: vars)
    }
}
