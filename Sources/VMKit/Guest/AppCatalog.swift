import Foundation

extension VMController {
    /// Busca las apps instaladas en Windows y guarda los iconos de las que ya estaban añadidas.
    /// Arranca la VM sin ventana si hace falta y espera a que Windows termine de arrancar.
    public func discoverApps(bootTimeout: TimeInterval = 180, progress: (String) -> Void = { _ in }) throws -> [DiscoveredApp] {
        if !isRunning {
            progress("Arrancando Windows sin ventana…")
            try start(display: .headless, bootFromInstaller: false)
        } else if state() == .paused {
            try resume()
        }
        let config = bundle.configuration
        if !GuestShell.isReady(port: config.sshPort) {
            progress("Esperando a que Windows termine de arrancar…")
            // RDP indica que Windows ya arrancó; SSH puede tardar unos segundos más.
            _ = ProcessRunner.waitFor(timeout: bootTimeout, interval: 2) { CoherenceLauncher.rdpIsReady(port: config.rdpPort) }
            guard ProcessRunner.waitFor(timeout: 15, interval: 1, { GuestShell.isReady(port: config.sshPort) }) else {
                throw GuestShell.notConfigured
            }
        }
        progress("Buscando apps instaladas en Windows…")
        let found = try AppScanner.scan(bundle: bundle)
        for app in config.coherence.apps {
            if let png = found.first(where: { $0.matches(app) })?.iconPNG {
                try? bundle.saveIcon(png, for: app)
            }
        }
        return found
    }

    /// Añade a Coherence las apps elegidas, con sus iconos.
    public func addApps(_ discovered: [DiscoveredApp]) throws {
        let existing = bundle.configuration.coherence.apps
        let new = discovered.filter { found in !existing.contains { found.matches($0) } }
        let apps = new.map { $0.makeRemoteApp() }
        for (app, found) in zip(apps, new) {
            if let png = found.iconPNG { try? bundle.saveIcon(png, for: app) }
        }
        try update { $0.coherence.apps += apps }
    }
}
