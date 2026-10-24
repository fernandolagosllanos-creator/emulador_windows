import Foundation
import VMKit

let usage = """
paralelo: gestor de máquinas virtuales Windows 11 ARM (QEMU + HVF)

Uso:
  paralelo list
  paralelo create <nombre> --iso <ruta.iso> [--cpus 4] [--ram 8192] [--disk 64] [--drivers <virtio-win.iso>]
  paralelo start <vm> [--headless] [--no-installer]
  paralelo status|pause|resume|shutdown|kill <vm>
  paralelo set <vm> [--cpus N] [--ram MB] [--disk GB] [--user USUARIO] [--client windowsApp|freeRDP] [--eject-iso]
  paralelo snapshot list|create|restore|delete <vm> [nombre]
  paralelo desktop <vm>                 Escritorio completo de Windows por RDP
  paralelo apps <vm>                    Lista las apps de Coherence
  paralelo app <vm> <app>               Abre una app de Windows como ventana del Mac
  paralelo add-app <vm> <nombre> <ruta.exe>
  paralelo dock <vm>                    Crea las apps en ~/Applications/Paralelo Apps
  paralelo delete <vm>
  paralelo log <vm>

<vm> es el nombre o el inicio del id; <app> es el nombre o el inicio del id.
"""

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Separa argumentos posicionales y opciones `--clave valor` / `--bandera`.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String], flagNames: Set<String>) {
        var i = 0
        while i < raw.count {
            let arg = raw[i]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if flagNames.contains(key) {
                    flags.insert(key)
                } else if i + 1 < raw.count {
                    options[key] = raw[i + 1]
                    i += 1
                }
            } else {
                positional.append(arg)
            }
            i += 1
        }
    }

    func int(_ key: String) throws -> Int? {
        guard let value = options[key] else { return nil }
        guard let n = Int(value) else { throw CLIError(message: "--\(key) debe ser un número") }
        return n
    }

    func require(_ index: Int, _ what: String) throws -> String {
        guard index < positional.count else { throw CLIError(message: "falta \(what)\n\n\(usage)") }
        return positional[index]
    }
}

let library = VMLibrary()

func controller(_ query: String) throws -> VMController {
    VMController(bundle: try library.find(query), environment: try QEMUEnvironment.detect())
}

func findApp(_ query: String, in config: VMConfiguration) throws -> RemoteApp {
    let lower = query.lowercased()
    if let app = config.coherence.apps.first(where: { $0.name.lowercased() == lower }) { return app }
    let byID = config.coherence.apps.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
    guard byID.count == 1 else { throw CLIError(message: "app \"\(query)\" no encontrada; usa `paralelo apps`") }
    return byID[0]
}

func launcher(_ c: VMController) -> CoherenceLauncher {
    #if canImport(Security)
    return CoherenceLauncher(controller: c, password: KeychainStore.password(for: c.bundle.configuration.id))
    #else
    return CoherenceLauncher(controller: c)
    #endif
}

func run() throws {
    var raw = Array(CommandLine.arguments.dropFirst())
    guard !raw.isEmpty, !["-h", "--help", "help"].contains(raw[0]) else {
        print(usage)
        return
    }
    let command = raw.removeFirst()
    let args = Arguments(raw, flagNames: ["headless", "no-installer", "eject-iso"])

    switch command {
    case "list":
        let env = try? QEMUEnvironment.detect()
        for bundle in library.list() {
            let c = bundle.configuration
            let state = env.map { VMController(bundle: bundle, environment: $0).state().label } ?? "?"
            print("\(c.shortID)  \(c.name)  [\(state)]  \(c.cpuCount) CPU, \(c.memoryMB) MB, \(c.diskSizeGB) GB, RDP 127.0.0.1:\(c.rdpPort)")
        }

    case "create":
        let name = try args.require(0, "el nombre")
        guard let iso = args.options["iso"] else { throw CLIError(message: "falta --iso <ruta a Windows 11 ARM>") }
        var config = VMConfiguration(
            name: name,
            installerISO: URL(fileURLWithPath: iso).standardizedFileURL.path,
            driversISO: args.options["drivers"].map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            rdpPort: library.nextFreeRDPPort())
        if let cpus = try args.int("cpus") { config.cpuCount = cpus }
        if let ram = try args.int("ram") { config.memoryMB = ram }
        if let disk = try args.int("disk") { config.diskSizeGB = disk }
        let bundle = try library.create(config, environment: try QEMUEnvironment.detect())
        print("Creada \"\(name)\" en \(bundle.url.path)")
        print("Siguiente paso: paralelo start \"\(name)\"  (pulsa una tecla cuando aparezca \"Press any key to boot from CD\")")

    case "start":
        let c = try controller(try args.require(0, "la VM"))
        try c.start(display: args.flags.contains("headless") ? .headless : .window,
                    bootFromInstaller: args.flags.contains("no-installer") ? false : nil)
        print("Arrancada (log: \(c.bundle.logURL.path))")

    case "status":
        let c = try controller(try args.require(0, "la VM"))
        print(c.state().label)

    case "pause": try controller(try args.require(0, "la VM")).pause()
    case "resume": try controller(try args.require(0, "la VM")).resume()
    case "shutdown": try controller(try args.require(0, "la VM")).shutdown()
    case "kill": try controller(try args.require(0, "la VM")).forceStop()

    case "set":
        let c = try controller(try args.require(0, "la VM"))
        let client = try args.options["client"].map { value -> RDPClientKind in
            guard let kind = RDPClientKind(rawValue: value) else { throw CLIError(message: "--client: windowsApp o freeRDP") }
            return kind
        }
        let cpus = try args.int("cpus"), ram = try args.int("ram"), disk = try args.int("disk")
        try c.update { config in
            if let cpus { config.cpuCount = cpus }
            if let ram { config.memoryMB = ram }
            if let disk { config.diskSizeGB = disk }
            if let user = args.options["user"] { config.coherence.username = user }
            if let client { config.coherence.client = client }
            if args.flags.contains("eject-iso") { config.installerISO = nil }
        }
        #if canImport(Security)
        if args.options["user"] != nil {
            print("Contraseña de Windows para FreeRDP (Enter para no guardarla): ", terminator: "")
            let password = String(cString: getpass(""))
            KeychainStore.setPassword(password, for: c.bundle.configuration.id)
        }
        #endif
        print("Guardado.")

    case "snapshot":
        let action = try args.require(0, "la acción (list|create|restore|delete)")
        let c = try controller(try args.require(1, "la VM"))
        switch action {
        case "list":
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            for s in try c.snapshots() {
                print("\(s.name)\t\(formatter.string(from: s.date))\t\(s.includesMemory ? "con memoria" : "solo disco")")
            }
        case "create": try c.createSnapshot(named: try args.require(2, "el nombre"))
        case "restore": try c.restoreSnapshot(named: try args.require(2, "el nombre"))
        case "delete": try c.deleteSnapshot(named: try args.require(2, "el nombre"))
        default: throw CLIError(message: "acción desconocida: \(action)")
        }

    case "desktop":
        let c = try controller(try args.require(0, "la VM"))
        try launcher(c).open(app: nil)

    case "apps":
        let c = try library.find(try args.require(0, "la VM")).configuration
        for app in c.coherence.apps {
            print("\(app.id.uuidString.prefix(8).lowercased())  \(app.name)  \(app.program)")
        }

    case "app":
        let c = try controller(try args.require(0, "la VM"))
        let app = try findApp(try args.require(1, "la app"), in: c.bundle.configuration)
        try launcher(c).open(app: app)

    case "add-app":
        let c = try controller(try args.require(0, "la VM"))
        let app = RemoteApp(name: try args.require(1, "el nombre"), program: try args.require(2, "la ruta del .exe"))
        try c.update { $0.coherence.apps.append(app) }
        print("Añadida \"\(app.name)\".")

    case "dock":
        let bundle = try library.find(try args.require(0, "la VM"))
        let cli = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        let urls = try AppShimBuilder(cliPath: cli).build(for: bundle.configuration)
        print("Creadas \(urls.count) apps en \(AppShimBuilder.defaultDestination.path)")

    case "delete":
        let c = try controller(try args.require(0, "la VM"))
        guard !c.isRunning else { throw VMError.alreadyRunning }
        try library.delete(c.bundle)
        print("Eliminada.")

    case "log":
        print(try controller(try args.require(0, "la VM")).logTail(lines: 50))

    default:
        throw CLIError(message: "comando desconocido: \(command)\n\n\(usage)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
