import AppKit
import SwiftUI
import VMKit

/// Resultado de buscar apps en Windows, para mostrarlo en una hoja.
struct AppDiscovery: Identifiable {
    let id = UUID()
    let vmID: UUID
    let apps: [DiscoveredApp]
}

/// Elige qué apps instaladas en Windows añadir a Coherence.
struct DiscoverAppsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let discovery: AppDiscovery

    @State private var selected: Set<String> = []
    @State private var filter = ""

    private var existing: [RemoteApp] {
        model.bundle(discovery.vmID)?.configuration.coherence.apps ?? []
    }

    private func isAdded(_ app: DiscoveredApp) -> Bool {
        existing.contains { app.matches($0) }
    }

    private var visible: [DiscoveredApp] {
        filter.isEmpty ? discovery.apps : discovery.apps.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apps instaladas en Windows").font(.title2)
            Text("Elige las que quieres abrir como ventanas del Mac. Las de la Microsoft Store se abren a través del Explorador de Windows.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Buscar", text: $filter)
            List(visible) { app in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { isAdded(app) || selected.contains(app.id) },
                        set: { if $0 { selected.insert(app.id) } else { selected.remove(app.id) } }))
                        .labelsHidden()
                        .disabled(isAdded(app))
                    AppIconView(png: app.iconPNG)
                    VStack(alignment: .leading) {
                        Text(app.name)
                        Text(app.isStoreApp ? "Microsoft Store" : app.program)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if isAdded(app) {
                        Spacer()
                        Text("Ya añadida").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 320)
            HStack {
                Text("\(discovery.apps.count) apps encontradas").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                Button("Añadir \(selected.count)") {
                    let chosen = discovery.apps.filter { selected.contains($0.id) }
                    model.addApps(chosen, to: discovery.vmID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

/// Icono de una app de Windows (PNG obtenido de Windows) o uno genérico si aún no hay.
struct AppIconView: View {
    var png: Data?
    var size: CGFloat = 24

    init(png: Data?, size: CGFloat = 24) {
        self.png = png
        self.size = size
    }

    var body: some View {
        if let png, let image = NSImage(data: png) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").frame(width: size, height: size)
        }
    }
}
