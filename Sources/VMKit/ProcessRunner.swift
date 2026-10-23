import Foundation

/// Ejecución de comandos auxiliares (qemu-img, open, ...).
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Leer antes de esperar para no bloquear si la salida llena el buffer del pipe.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Igual que `run`, pero lanza un error si el comando termina con estado distinto de 0.
    @discardableResult
    public static func check(_ executable: URL, _ arguments: [String]) throws -> String {
        let result = try run(executable, arguments)
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw VMError.commandFailed("\(executable.lastPathComponent): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }

    /// Lanza un proceso de larga duración (QEMU, swtpm) con su salida a un archivo de log.
    public static func launch(_ executable: URL, _ arguments: [String], log: URL) throws -> Process {
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    public static func isAlive(pid: pid_t) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    public static func waitFor(timeout: TimeInterval, interval: TimeInterval = 0.1,
                               _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return condition()
    }
}
