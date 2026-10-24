import AppKit
import Foundation
import VMKit

/// Estado de la app: biblioteca de VMs, su estado en vivo y las acciones sobre ellas.
@MainActor
final class AppModel: ObservableObject {
    @Published var vms: [VMBundle] = []
    @Published var states: [UUID: VMState] = [:]
    @Published var busy: Set<UUID> = []
    @Published var selection: UUID?
    @Published var environmentError: String?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var discovery: AppDiscovery?

    let library = VMLibrary()
    private(set) var environment: QEMUEnvironment?
    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStates() }
        }
    }

    func reload() {
        do {
            environment = try QEMUEnvironment.detect()
            environmentError = nil
        } catch {
            environment = nil
            environmentError = error.localizedDescription
        }
        vms = library.list()
        if selection == nil || !vms.contains(where: { $0.configuration.id == selection }) {
            selection = vms.first?.configuration.id
        }
        refreshStates()
    }

    func refreshStates() {
        guard let environment else { return }
        let bundles = vms
        Task.detached {
            var result: [UUID: VMState] = [:]
            for bundle in bundles {
                result[bundle.configuration.id] = VMController(bundle: bundle, environment: environment).state()
            }
            let states = result
            await MainActor.run { self.states = states }
        }
    }

    func bundle(_ id: UUID) -> VMBundle? {
        vms.first { $0.configuration.id == id }
    }

    func state(_ id: UUID) -> VMState {
        states[id] ?? .stopped
    }

    func controller(_ id: UUID) -> VMController? {
        guard let environment, let bundle = bundle(id) else { return nil }
        return VMController(bundle: bundle, environment: environment)
    }

    /// Ejecuta una acción sobre una VM fuera del hilo principal y recarga al terminar.
    /// `done` recibe si la acción falló, para limpiar mensajes de progreso.
    func perform(_ id: UUID, done: (@MainActor @Sendable (Bool) -> Void)? = nil,
                 _ work: @escaping @Sendable (VMController) throws -> Void) {
        guard let controller = controller(id) else {
            errorMessage = environmentError ?? "VM no encontrada"
            return
        }
        busy.insert(id)
        Task.detached {
            let failure: String?
            do {
                try work(controller)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.busy.remove(id)
                if let failure { self.errorMessage = failure }
                done?(failure != nil)
                self.reload()
            }
        }
    }

    func create(_ config: VMConfiguration) {
        guard let environment else {
            errorMessage = environmentError
            return
        }
        do {
            let bundle = try library.create(config, environment: environment)
            reload()
            selection = bundle.configuration.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ id: UUID) {
        guard let bundle = bundle(id) else { return }
        if state(id) != .stopped {
            errorMessage = "Apaga la VM antes de eliminarla."
            return
        }
        do {
            try library.delete(bundle)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Coherence

    func open(app: RemoteApp?, in id: UUID) {
        let password = bundle(id).flatMap { KeychainStore.password(for: $0.configuration.id) }
        let name = app?.name ?? "el escritorio de Windows"
        notice = "Abriendo \(name)…"
        perform(id, done: { [weak self] failed in
            self?.notice = failed ? nil : "\(name) abierto en una ventana del Mac."
        }) { controller in
            try CoherenceLauncher(controller: controller, password: password).open(app: app) { step in
                Task { @MainActor [weak self] in self?.notice = step }
            }
        }
    }

    func discoverApps(in id: UUID) {
        notice = "Buscando apps instaladas en Windows…"
        perform(id, done: { [weak self] failed in
            if failed { self?.notice = nil }
        }) { controller in
            let found = try controller.discoverApps { step in
                Task { @MainActor [weak self] in self?.notice = step }
            }
            Task { @MainActor [weak self] in
                self?.notice = nil
                self?.discovery = AppDiscovery(vmID: id, apps: found)
            }
        }
    }

    func addApps(_ apps: [DiscoveredApp], to id: UUID) {
        let count = apps.count
        perform(id, done: { [weak self] failed in
            if !failed {
                self?.notice = "Añadidas \(count) apps. Pulsa \"Crear apps en el Dock\" para tenerlas también en el Dock."
            }
        }) { try $0.addApps(apps) }
    }

    /// Ruta del CLI `paralelo`: dentro del .app (Contents/MacOS) o junto al ejecutable en `swift run`.
    var cliPath: String {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "paralelo") { return url.path }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("paralelo")
        return sibling?.path ?? "paralelo"
    }

    func buildDockApps(for id: UUID) {
        guard let bundle = bundle(id) else { return }
        do {
            let urls = try AppShimBuilder(cliPath: cliPath).build(for: bundle)
            notice = "Creadas \(urls.count) apps en ~/Applications/Paralelo Apps"
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
