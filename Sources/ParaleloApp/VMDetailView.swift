import SwiftUI
import VMKit

struct VMDetailView: View {
    @EnvironmentObject var model: AppModel
    let id: UUID

    var body: some View {
        if let bundle = model.bundle(id) {
            let config = bundle.configuration
            let state = model.state(id)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(config: config, state: state)
                    if let notice = model.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                    }
                    GroupBox("Hardware") { HardwareSection(id: id, config: config, running: state != .stopped) }
                    GroupBox("Snapshots") { SnapshotSection(id: id, state: state) }
                    GroupBox("Coherence") { CoherenceSection(id: id, config: config) }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func header(config: VMConfiguration, state: VMState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "pc").font(.system(size: 36))
            VStack(alignment: .leading) {
                Text(config.name).font(.title)
                Text("\(state.label) · RDP en 127.0.0.1:\(config.rdpPort)").foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy.contains(id) { ProgressView().controlSize(.small) }
            switch state {
            case .stopped:
                Button { model.perform(id) { try $0.start(display: .window) } } label: {
                    Label("Iniciar", systemImage: "play.fill")
                }
                Button { model.perform(id) { try $0.start(display: .headless, bootFromInstaller: false) } } label: {
                    Label("Iniciar sin ventana", systemImage: "play")
                }
            case .running, .unknown:
                Button { model.open(app: nil, in: id) } label: { Label("Escritorio", systemImage: "macwindow") }
                Button { model.perform(id) { try $0.pause() } } label: { Label("Pausar", systemImage: "pause.fill") }
                Button { model.perform(id) { try $0.shutdown() } } label: { Label("Apagar", systemImage: "power") }
                Button(role: .destructive) { model.perform(id) { try $0.forceStop() } } label: {
                    Label("Forzar", systemImage: "bolt.slash")
                }
            case .paused:
                Button { model.perform(id) { try $0.resume() } } label: { Label("Reanudar", systemImage: "play.fill") }
                Button(role: .destructive) { model.perform(id) { try $0.forceStop() } } label: {
                    Label("Forzar", systemImage: "bolt.slash")
                }
            }
        }
        .disabled(model.busy.contains(id))
    }
}

struct HardwareSection: View {
    @EnvironmentObject var model: AppModel
    let id: UUID
    let config: VMConfiguration
    let running: Bool

    @State private var cpus = 4
    @State private var memoryMB = 8192
    @State private var diskGB = 64
    @State private var driversPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("CPU: \(cpus)", value: $cpus, in: 1...ProcessInfo.processInfo.activeProcessorCount)
            MemoryPicker(memoryMB: $memoryMB)
            Stepper("Disco: \(diskGB) GB (solo puede crecer)", value: $diskGB, in: config.diskSizeGB...2048, step: 16)
            FilePickerRow(title: "ISO de drivers", path: $driversPath)
            HStack {
                if let iso = config.installerISO {
                    Text("ISO de instalación: \(URL(fileURLWithPath: iso).lastPathComponent)").foregroundStyle(.secondary)
                    Button("Expulsar ISO") { model.perform(id) { try $0.update { $0.installerISO = nil } } }
                }
                Spacer()
                Button("Aplicar") {
                    let (newCPUs, newMemory, newDisk, drivers) = (cpus, memoryMB, diskGB, driversPath)
                    model.perform(id) { controller in
                        try controller.update {
                            $0.cpuCount = newCPUs
                            $0.memoryMB = newMemory
                            $0.diskSizeGB = newDisk
                            $0.driversISO = drivers.isEmpty ? nil : drivers
                        }
                    }
                }
                .disabled(!hasChanges)
            }
            if running {
                Text("Apaga la VM para cambiar el hardware.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(running)
        .onAppear(perform: load)
        .onChange(of: config) { load() }
    }

    private var hasChanges: Bool {
        cpus != config.cpuCount || memoryMB != config.memoryMB || diskGB != config.diskSizeGB
            || driversPath != (config.driversISO ?? "")
    }

    private func load() {
        cpus = config.cpuCount
        memoryMB = config.memoryMB
        diskGB = config.diskSizeGB
        driversPath = config.driversISO ?? ""
    }
}

struct SnapshotSection: View {
    @EnvironmentObject var model: AppModel
    let id: UUID
    let state: VMState

    @State private var snapshots: [VMSnapshot] = []
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshots.isEmpty {
                Text("Sin snapshots.").foregroundStyle(.secondary)
            }
            ForEach(snapshots) { snapshot in
                HStack {
                    Image(systemName: snapshot.includesMemory ? "memorychip" : "internaldrive")
                    Text(snapshot.name)
                    Text(snapshot.date, style: .date).foregroundStyle(.secondary)
                    Text(snapshot.date, style: .time).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restaurar") { run { try $0.restoreSnapshot(named: snapshot.name) } }
                    Button("Eliminar", role: .destructive) { run { try $0.deleteSnapshot(named: snapshot.name) } }
                }
            }
            HStack {
                TextField("Nombre (letras, números, - _ .)", text: $newName)
                Button("Crear snapshot") {
                    let name = newName
                    newName = ""
                    run { try $0.createSnapshot(named: name) }
                }
                .disabled(newName.isEmpty)
            }
            Text(state == .stopped
                 ? "Con la VM apagada el snapshot guarda solo el disco."
                 : "Con la VM encendida el snapshot guarda disco y memoria (se reanuda donde estaba).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onChange(of: model.busy) { refresh() }
    }

    private func run(_ work: @escaping @Sendable (VMController) throws -> Void) {
        model.perform(id, work)
    }

    private func refresh() {
        guard let controller = model.controller(id) else { return }
        Task { @MainActor in
            snapshots = await Task.detached { (try? controller.snapshots()) ?? [] }.value
        }
    }
}

struct CoherenceSection: View {
    @EnvironmentObject var model: AppModel
    let id: UUID
    let config: VMConfiguration

    @State private var username = ""
    @State private var password = ""
    @State private var client: RDPClientKind = .windowsApp
    @State private var shareHome = true
    @State private var newAppName = ""
    @State private var newAppPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Abre apps de Windows como ventanas sueltas del Mac. Requiere Windows Pro y ejecutar una vez setup-windows.ps1 desde la unidad PARALELO de Windows.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Usuario de Windows", text: $username)
                SecureField("Contraseña (solo FreeRDP, se guarda en el llavero)", text: $password)
            }
            HStack {
                Picker("Cliente RDP", selection: $client) {
                    ForEach(RDPClientKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Compartir mi carpeta de inicio", isOn: $shareHome)
                Button("Guardar") {
                    KeychainStore.setPassword(password, for: config.id)
                    let (user, rdpClient, share) = (username, client, shareHome)
                    model.perform(id) { controller in
                        try controller.update {
                            $0.coherence.username = user
                            $0.coherence.client = rdpClient
                            $0.coherence.shareHomeFolder = share
                        }
                    }
                }
            }
            Divider()
            ForEach(config.coherence.apps) { app in
                HStack {
                    Image(systemName: "app.dashed")
                    VStack(alignment: .leading) {
                        Text(app.name)
                        Text(app.program).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Abrir") { model.open(app: app, in: id) }
                    Button { removeApp(app) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Nombre", text: $newAppName).frame(maxWidth: 160)
                TextField(#"Ruta en Windows, p. ej. C:\Program Files\App\app.exe"#, text: $newAppPath)
                Button("Añadir") {
                    let app = RemoteApp(name: newAppName, program: newAppPath)
                    newAppName = ""
                    newAppPath = ""
                    model.perform(id) { try $0.update { $0.coherence.apps.append(app) } }
                }
                .disabled(newAppName.isEmpty || newAppPath.isEmpty)
            }
            Button("Crear apps en el Dock / Launchpad") { model.buildDockApps(for: id) }
        }
        .onAppear(perform: load)
        .onChange(of: config) { load() }
    }

    private func removeApp(_ app: RemoteApp) {
        let appID = app.id
        model.perform(id) { try $0.update { $0.coherence.apps.removeAll { $0.id == appID } } }
    }

    private func load() {
        username = config.coherence.username
        client = config.coherence.client
        shareHome = config.coherence.shareHomeFolder
        password = KeychainStore.password(for: config.id) ?? ""
    }
}
