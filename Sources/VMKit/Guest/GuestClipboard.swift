import Foundation

/// Lo que hay en un portapapeles: texto, una imagen y/o archivos.
public struct ClipboardContent: Equatable, Sendable {
    public var text: String?
    public var png: Data?
    public var files: [URL]

    public init(text: String? = nil, png: Data? = nil, files: [URL] = []) {
        self.text = text
        self.png = png
        self.files = files
    }

    public var isEmpty: Bool { (text ?? "").isEmpty && png == nil && files.isEmpty }
}

/// Estado del portapapeles de Windows que publica el agente (to-mac.kind): "<id> text image files size=<bytes>".
public struct GuestClipboardState: Equatable, Sendable {
    public var id: String
    public var formats: Set<String>
    /// Tamaño total de los archivos copiados.
    public var size: Int64

    public init?(line: String) {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
        id = first
        size = 0
        formats = []
        for part in parts.dropFirst() {
            if part.hasPrefix("size=") {
                size = Int64(part.dropFirst(5)) ?? 0
            } else {
                formats.insert(part)
            }
        }
    }
}

/// Portapapeles compartido con la ventana de pantalla. El agente de Paralelo en Windows copia el
/// portapapeles de Windows a archivos y aplica el que llega del Mac; aquí se leen y escriben por SSH.
public struct GuestClipboard: Sendable {
    public var transfer: GuestTransfer
    public var shell: GuestShell { transfer.shell }

    /// Más que esto no se copia por el portapapeles (para no bloquearlo con una carpeta enorme).
    public static let maxFileBytes: Int64 = 1 << 30

    public init(transfer: GuestTransfer) {
        self.transfer = transfer
    }

    static func path(_ name: String) -> String { GuestTools.clipboardDirectory + "\\" + name }

    /// Pone `content` en el portapapeles de Windows.
    public func push(_ content: ClipboardContent) throws {
        var formats: [String] = []
        var files: [String] = []
        if !content.files.isEmpty {
            files = try transfer.stage(content.files, limit: Self.maxFileBytes)
            formats.append("files")
        }
        if let png = content.png, files.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paralelo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("from-mac.png")
            try png.write(to: file)
            try shell.upload([file], toDirectory: GuestTools.clipboardDirectory)
            formats.append("image")
        }
        var outputs: [(name: String, content: String)] = []
        if let text = content.text, !text.isEmpty {
            outputs.append(("from-mac.txt", text))
            formats.append("text")
        }
        guard !formats.isEmpty else { return }
        if !files.isEmpty { outputs.append(("from-mac-files.txt", files.joined(separator: "\r\n"))) }
        // El agente reacciona a from-mac.kind: se escribe al final.
        outputs.append(("from-mac.kind", formats.joined(separator: " ")))
        _ = try shell.runPowerShell(GuestTransfer.writeScript(outputs))
    }

    /// Lo último que se copió en Windows, o nil si no hay nada. Usa cmd.exe porque arranca mucho antes que PowerShell.
    public func state() throws -> GuestClipboardState? {
        GuestClipboardState(line: try type(Self.path("to-mac.kind")))
    }

    /// Trae el contenido del portapapeles de Windows. Los archivos que no están en la carpeta compartida
    /// se copian a `directory`.
    public func fetch(_ state: GuestClipboardState, filesInto directory: URL) throws -> ClipboardContent {
        var content = ClipboardContent()
        if state.formats.contains("text") {
            let text = try type(Self.path("to-mac.txt"))
            content.text = text.isEmpty ? nil : text
        }
        if state.formats.contains("files") {
            let paths = try type(Self.path("to-mac-files.txt"))
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var remote: [String] = []
            for path in paths {
                if let local = transfer.macURL(forWindowsPath: path) {
                    content.files.append(local)
                } else {
                    remote.append(path)
                }
            }
            if !remote.isEmpty {
                guard state.size <= Self.maxFileBytes else {
                    throw VMError.commandFailed("los archivos copiados en Windows pasan de 1 GB; arrástralos a la unidad Mac (Z:)")
                }
                try? FileManager.default.removeItem(at: directory)
                try shell.download(remote, toDirectory: directory)
                content.files += remote.map { directory.appendingPathComponent(GuestTransfer.windowsName($0)) }
            }
        } else if state.formats.contains("image") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paralelo-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            try shell.download([Self.path("to-mac.png")], toDirectory: dir)
            content.png = try Data(contentsOf: dir.appendingPathComponent("to-mac.png"))
        }
        return content
    }

    private func type(_ path: String) throws -> String {
        try shell.run("if exist \"\(path)\" type \"\(path)\"")
    }
}
