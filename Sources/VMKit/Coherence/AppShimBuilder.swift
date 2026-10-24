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
    public func build(for bundle: VMBundle) throws -> [URL] {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return try bundle.configuration.coherence.apps.map {
            try build(app: $0, vm: bundle.configuration, iconPNG: bundle.icon(for: $0))
        }
    }

    public func shimURL(app: RemoteApp) -> URL {
        destination.appendingPathComponent("\(app.fileName).app", isDirectory: true)
    }

    @discardableResult
    public func build(app: RemoteApp, vm: VMConfiguration, iconPNG: Data? = nil) throws -> URL {
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

        var plist: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": "app.paralelo.shim.\(vm.shortID).\(app.id.uuidString.prefix(8).lowercased())",
            "CFBundleName": app.name,
            "CFBundleDisplayName": app.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
        ]
        if let iconPNG, let icns = ICNS.make(png: iconPNG) ?? Self.resized(iconPNG).flatMap(ICNS.make(png:)) {
            let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
            plist["CFBundleIconFile"] = "AppIcon"
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        return appURL
    }

    /// Redimensiona a 256×256 con sips (incluido en macOS) cuando el PNG no tiene un tamaño de icono estándar.
    static func resized(_ png: Data) -> Data? {
        let sips = URL(fileURLWithPath: "/usr/bin/sips")
        guard FileManager.default.isExecutableFile(atPath: sips.path) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("paralelo-icon-\(UUID().uuidString)")
        let input = tmp.appendingPathExtension("png"), output = tmp.appendingPathExtension("256.png")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        guard (try? png.write(to: input)) != nil,
              let result = try? ProcessRunner.run(sips, ["-z", "256", "256", input.path, "--out", output.path]),
              result.status == 0
        else { return nil }
        return try? Data(contentsOf: output)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
