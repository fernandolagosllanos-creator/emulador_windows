import Foundation

/// Una aplicación de Windows que se abre como ventana suelta en el Mac (RDP RemoteApp).
public struct RemoteApp: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Ruta del ejecutable dentro de Windows, p. ej. C:\Windows\System32\notepad.exe
    public var program: String
    public var arguments: String
    /// Identificador de la app en el menú Inicio de Windows (AppUserModelID), si se encontró al buscar apps.
    public var appUserModelID: String?

    public init(id: UUID = UUID(), name: String, program: String, arguments: String = "",
                appUserModelID: String? = nil) {
        self.id = id
        self.name = name
        self.program = program
        self.arguments = arguments
        self.appUserModelID = appUserModelID
    }

    /// Nombre seguro para archivos (.rdp y .app).
    public var fileName: String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    private static let office = #"C:\Program Files\Microsoft Office\root\Office16"#

    /// Apps de ofimática habituales; las de Office solo funcionan si Office está instalado en Windows.
    public static let defaults: [RemoteApp] = [
        RemoteApp(name: "Explorador de archivos", program: #"C:\Windows\explorer.exe"#),
        RemoteApp(name: "Bloc de notas", program: #"C:\Windows\System32\notepad.exe"#),
        RemoteApp(name: "Microsoft Edge", program: #"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"#),
        RemoteApp(name: "Word", program: office + #"\WINWORD.EXE"#),
        RemoteApp(name: "Excel", program: office + #"\EXCEL.EXE"#),
        RemoteApp(name: "PowerPoint", program: office + #"\POWERPNT.EXE"#),
        RemoteApp(name: "Outlook", program: office + #"\OUTLOOK.EXE"#),
        RemoteApp(name: "Terminal (PowerShell)", program: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#),
    ]
}

/// Cliente RDP del Mac que muestra las ventanas.
public enum RDPClientKind: String, Codable, CaseIterable, Sendable {
    /// "Windows App" de Microsoft (App Store), abre archivos .rdp.
    case windowsApp
    /// FreeRDP (`brew install freerdp`), soporta RemoteApp con /app.
    case freeRDP

    public var label: String {
        switch self {
        case .windowsApp: return "Windows App (Microsoft)"
        case .freeRDP: return "FreeRDP"
        }
    }
}
