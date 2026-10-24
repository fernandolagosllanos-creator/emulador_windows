import Foundation

/// Crea mini-apps de macOS (una por app de Windows) en ~/Applications/Paralelo Apps.
/// Se pueden abrir desde Launchpad/Spotlight o fijar en el Dock, como hace Parallels.
public struct AppShimBuilder {
    public var cliPath: String
    public var destination: URL

    public static var defaultDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Paralelo Apps", isDirectory: true)
    }

    public init(cliPath: String, destination: URL = AppShimBuilder.defaultDestination) {
        self.cliPath = cliPath
        self.destination = destination
    }

    @discardableResult
    public func build(for configuration: VMConfiguration) throws -> [URL] {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return try configuration.coherence.apps.map { try build(app: $0, vm: configuration) }
    }

    public func shimURL(app: RemoteApp) -> URL {
        destination.appendingPathComponent("\(app.fileName).app", isDirectory: true)
    }

    @discardableResult
    public func build(app: RemoteApp, vm: VMConfiguration) throws -> URL {
        let fm = FileManager.default
        let appURL = shimURL(app: app)
        let macOS = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try? fm.removeItem(at: appURL)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        exec \(Self.shellQuote(cliPath)) app \(vm.id.uuidString) \(app.id.uuidString)

        """
        let executable = macOS.appendingPathComponent("launch")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let plist: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": "app.paralelo.shim.\(vm.shortID).\(app.id.uuidString.prefix(8).lowercased())",
            "CFBundleName": app.name,
            "CFBundleDisplayName": app.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        return appURL
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
