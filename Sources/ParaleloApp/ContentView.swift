import SwiftUI
import VMKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingNewVM = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.vms, id: \.configuration.id) { bundle in
                    let config = bundle.configuration
                    HStack {
                        Image(systemName: "pc")
                        VStack(alignment: .leading) {
                            Text(config.name).font(.headline)
                            Text(model.state(config.id).label)
                                .font(.caption)
                                .foregroundStyle(color(for: model.state(config.id)))
                        }
                    }
                    .tag(config.id)
                    .contextMenu {
                        Button("Eliminar…", role: .destructive) { model.delete(config.id) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                Button { showingNewVM = true } label: { Label("Nueva VM", systemImage: "plus") }
                    .disabled(model.environment == nil)
            }
        } detail: {
            if let error = model.environmentError {
                MissingDependenciesView(message: error) { model.reload() }
            } else if let id = model.selection, model.bundle(id) != nil {
                VMDetailView(id: id).id(id)
            } else {
                ContentUnavailableView("Sin máquinas virtuales", systemImage: "pc",
                                       description: Text("Crea una con el botón + a partir de una ISO de Windows 11 ARM."))
            }
        }
        .sheet(isPresented: $showingNewVM) {
            NewVMSheet().environmentObject(model)
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func color(for state: VMState) -> Color {
        switch state {
        case .running: return .green
        case .paused: return .orange
        case .stopped, .unknown: return .secondary
        }
    }
}

struct MissingDependenciesView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 40))
            Text("Falta QEMU").font(.title2)
            Text(message).foregroundStyle(.secondary)
            Text("Instálalo con:  brew install qemu").font(.body.monospaced()).textSelection(.enabled)
            Button("Reintentar", action: retry)
        }
        .padding()
    }
}
