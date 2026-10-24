import Foundation

/// Portapapeles compartido con la ventana de pantalla. El agente de Paralelo en Windows copia el
/// portapapeles de Windows a un archivo y aplica el que llega del Mac; aquí se leen y escriben por SSH.
public struct GuestClipboard: Sendable {
    public var shell: GuestShell

    public init(shell: GuestShell) {
        self.shell = shell
    }

    /// Pone `text` en el portapapeles de Windows.
    public func push(_ text: String) throws {
        let base64 = Data(text.utf8).base64EncodedString()
        _ = try shell.runPowerShell("""
            [IO.File]::WriteAllText('\(GuestTools.clipboardFromMac)', \
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(base64)')), \
            (New-Object Text.UTF8Encoding $false))
            """)
    }

    /// Último texto copiado en Windows, o nil si no hay. Usa cmd.exe porque arranca mucho antes que PowerShell.
    public func pull() throws -> String? {
        let path = GuestTools.clipboardToMac
        let text = try shell.run("if exist \"\(path)\" type \"\(path)\"")
        return text.isEmpty ? nil : text
    }
}
