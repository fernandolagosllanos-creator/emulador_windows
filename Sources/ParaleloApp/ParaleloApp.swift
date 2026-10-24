import AppKit
import SwiftUI
import VMKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necesario cuando se ejecuta con `swift run` (sin bundle .app).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Escribir en un socket que la VM cerró no debe cerrar la app.
        signal(SIGPIPE, SIG_IGN)
    }
}

@main
struct ParaleloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Paralelo") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
        }

        // Acceso rápido a las apps de Windows desde la barra de menús, como el menú de Coherence de Parallels.
        MenuBarExtra("Paralelo", systemImage: "square.on.square") {
            ForEach(model.vms, id: \.configuration.id) { bundle in
                let config = bundle.configuration
                Section("\(config.name) — \(model.state(config.id).label)") {
                    Button("Pantalla de la VM") { model.showScreen(config.id) }
                    Button("Escritorio de Windows (RDP)") { model.open(app: nil, in: config.id) }
                    ForEach(config.coherence.apps) { app in
                        Button(app.name) { model.open(app: app, in: config.id) }
                    }
                }
            }
            Divider()
            Button("Salir de Paralelo") { NSApp.terminate(nil) }
        }
    }
}
