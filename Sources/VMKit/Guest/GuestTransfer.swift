import Foundation

/// Lleva archivos del Mac a Windows (para el portapapeles y para soltarlos sobre la pantalla).
/// Lo que está dentro de la carpeta compartida no se copia: Windows lo abre en \\10.0.2.4\qemu.
/// El resto se sube por scp a C:\ProgramData\Paralelo\transfer.
public struct GuestTransfer: Sendable {
    public var shell: GuestShell
    /// Carpeta del Mac que ve Windows en este arranque (nil si no hay carpeta compartida).
    public var sharedFolder: URL?

    public init(shell: GuestShell, sharedFolder: URL?) {
        self.shell = shell
        self.sharedFolder = sharedFolder
    }

    /// La carpeta compartida del arranque actual de la VM.
    public init(bundle: VMBundle) {
        self.init(shell: GuestShell(bundle: bundle), sharedFolder: bundle.runtime.sharedFolder)
    }

    private var sharedRoot: String? {
        sharedFolder.map { $0.standardizedFileURL.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }
    }

    /// Ruta de Windows para un archivo del Mac que está en la carpeta compartida.
    public func windowsPath(forMacURL url: URL) -> String? {
        guard let root = sharedRoot else { return nil }
        let path = url.standardizedFileURL.path
        if path == root { return GuestTools.sharedFolderUNC }
        guard path.hasPrefix(root + "/") else { return nil }
        let rest = path.dropFirst(root.count + 1).replacingOccurrences(of: "/", with: "\\")
        return GuestTools.sharedFolderUNC + "\\" + rest
    }

    /// Archivo del Mac para una ruta de Windows dentro de la carpeta compartida (\\10.0.2.4\qemu\… o Z:\…).
    public func macURL(forWindowsPath path: String) -> URL? {
        guard let root = sharedRoot else { return nil }
        let lower = path.lowercased()
        let rest: Substring
        if let prefix = [GuestTools.sharedFolderUNC.lowercased() + "\\", "z:\\"].first(where: { lower.hasPrefix($0) }) {
            rest = path.dropFirst(prefix.count)
        } else if lower == GuestTools.sharedFolderUNC.lowercased() || lower == "z:" {
            rest = ""
        } else {
            return nil
        }
        let relative = rest.replacingOccurrences(of: "\\", with: "/")
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relative).standardizedFileURL
    }

    /// Nombre del archivo en una ruta de Windows.
    public static func windowsName(_ path: String) -> String {
        let trimmed = path.hasSuffix("\\") ? String(path.dropLast()) : path
        return trimmed.split(separator: "\\").last.map(String.init) ?? trimmed
    }

    /// Deja los archivos accesibles desde Windows y devuelve sus rutas allí.
    public func stage(_ files: [URL], limit: Int64? = nil) throws -> [String] {
        var paths: [String] = []
        var upload: [URL] = []
        for file in files {
            if let path = windowsPath(forMacURL: file) { paths.append(path) } else { upload.append(file) }
        }
        guard !upload.isEmpty else { return paths }
        if let limit, Self.size(of: upload) > limit {
            throw VMError.commandFailed("hay más de 1 GB fuera de tu carpeta de inicio; arrástralos a la ventana en lugar de copiarlos")
        }
        let directory = GuestTools.transferDirectory + "\\" + UUID().uuidString
        // Se borra lo que se subió hace más de un día.
        _ = try shell.runPowerShell("""
            $t = '\(GuestTools.transferDirectory)'
            New-Item -ItemType Directory -Path '\(directory)' -Force | Out-Null
            Get-ChildItem -LiteralPath $t -Directory | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            """)
        try shell.upload(upload, toDirectory: directory)
        return paths + upload.map { directory + "\\" + $0.lastPathComponent }
    }

    /// Copia los archivos a la carpeta del Explorador que hay en (x, y) de la pantalla de Windows, o al Escritorio.
    public func drop(_ files: [URL], x: Int, y: Int) throws {
        let paths = try stage(files)
        guard !paths.isEmpty else { return }
        _ = try shell.runPowerShell(Self.writeScript([("drop.txt", (["\(x) \(y)"] + paths).joined(separator: "\r\n"))]))
    }

    /// Script que escribe archivos de texto (UTF-8) en la carpeta del portapapeles, en orden.
    static func writeScript(_ files: [(name: String, content: String)]) -> String {
        var script = "$u = New-Object Text.UTF8Encoding $false\n"
        for file in files {
            let base64 = Data(file.content.utf8).base64EncodedString()
            script += "[IO.File]::WriteAllText('\(GuestClipboard.path(file.name))', "
                + "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(base64)')), $u)\n"
        }
        return script
    }

    static func size(of files: [URL]) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let items = fm.enumerator(at: file, includingPropertiesForKeys: keys)
                while let item = items?.nextObject() as? URL {
                    total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

/// El agente de Paralelo en Windows: se actualiza desde el Mac cuando su versión no es la actual.
public struct GuestAgent: Sendable {
    public var shell: GuestShell

    public init(shell: GuestShell) {
        self.shell = shell
    }

    static let versionFile = GuestClipboard.path("agent-version.txt")

    public func installedVersion() throws -> Int? {
        Int(try shell.run("if exist \"\(Self.versionFile)\" type \"\(Self.versionFile)\"")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Instala y arranca el agente actual si hace falta. Devuelve true si lo actualizó.
    @discardableResult
    public func ensureCurrent() throws -> Bool {
        guard try installedVersion() != GuestTools.agentVersion else { return false }
        _ = try shell.runPowerShell(GuestTools.agentInstallScript)
        _ = ProcessRunner.waitFor(timeout: 20, interval: 1) {
            (try? installedVersion()) == GuestTools.agentVersion
        }
        return true
    }
}
