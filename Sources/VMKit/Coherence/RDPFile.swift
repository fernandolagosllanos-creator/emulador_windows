import Foundation

/// Genera archivos .rdp: escritorio completo o una sola app (RemoteApp = modo Coherence).
public struct RDPFile: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var app: RemoteApp?
    public var shareHomeFolder: Bool

    public init(host: String = "127.0.0.1", port: Int, username: String, app: RemoteApp?, shareHomeFolder: Bool) {
        self.host = host
        self.port = port
        self.username = username
        self.app = app
        self.shareHomeFolder = shareHomeFolder
    }

    public init(configuration: VMConfiguration, app: RemoteApp?) {
        self.init(port: configuration.rdpPort, username: configuration.coherence.username,
                  app: app, shareHomeFolder: configuration.coherence.shareHomeFolder)
    }

    public func contents() -> String {
        var lines = [
            "full address:s:\(host):\(port)",
            "redirectclipboard:i:1",
            "audiomode:i:0",
            "authentication level:i:0",
            "prompt for credentials on client:i:0",
            "drivestoredirect:s:\(shareHomeFolder ? "*" : "")",
        ]
        if !username.isEmpty {
            lines.append("username:s:\(username)")
        }
        if let app {
            lines += [
                "remoteapplicationmode:i:1",
                "remoteapplicationprogram:s:\(app.program)",
                "remoteapplicationname:s:\(app.name)",
                "remoteapplicationcmdline:s:\(app.arguments)",
                "disableremoteappcapscheck:i:1",
                "alternate shell:s:rdpinit.exe",
            ]
        } else {
            lines += [
                "screen mode id:i:1",
                "dynamic resolution:i:1",
                "smart sizing:i:1",
            ]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    @discardableResult
    public func write(to url: URL) throws -> URL {
        try contents().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
