import AppKit
import VMKit

/// Portapapeles (texto, imágenes y archivos) y archivos soltados entre el Mac y la ventana de pantalla.
/// Se envía el portapapeles del Mac al entrar en la ventana y se trae el de Windows al salir.
/// Todo lo que habla con Windows va en una cola propia, en orden.
final class GuestSync: @unchecked Sendable {
    private let bundle: VMBundle
    private let queue = DispatchQueue(label: "Paralelo.portapapeles")
    /// Se llama en el hilo principal con un aviso para la pantalla (nil lo quita) y si debe ocultarse solo.
    var onNotice: ((String?, Bool) -> Void)?

    // Solo en `queue`.
    private var agentChecked = false
    private var lastPulledID: String?
    // Solo en el hilo principal.
    private var lastPushedChange = -1

    /// Copias de los archivos que llegan del portapapeles de Windows.
    static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Paralelo/Portapapeles", isDirectory: true)

    init(bundle: VMBundle) {
        self.bundle = bundle
    }

    private var clipboard: GuestClipboard { GuestClipboard(transfer: GuestTransfer(bundle: bundle)) }

    /// En `queue`: Windows responde por SSH y el agente está al día.
    private func prepare() -> Bool {
        let shell = GuestShell(bundle: bundle)
        guard shell.isAvailable else { return false }
        if !agentChecked {
            agentChecked = true
            if (try? GuestAgent(shell: shell).ensureCurrent()) == true {
                notice("Agente de Paralelo actualizado en Windows.", autoHide: true)
            }
        }
        return true
    }

    private func notice(_ text: String?, autoHide: Bool = false) {
        DispatchQueue.main.async { self.onNotice?(text, autoHide) }
    }

    private func report(_ error: Error) {
        notice("No se pudo copiar: \(error.localizedDescription)", autoHide: true)
    }

    // MARK: Portapapeles

    @MainActor
    func push() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPushedChange else { return }
        lastPushedChange = pasteboard.changeCount
        let content = Self.read(pasteboard)
        queue.async {
            guard self.prepare() else { return }
            let clipboard = self.clipboard
            // Lo que ya estaba copiado en Windows no debe pisar el portapapeles del Mac al salir.
            if self.lastPulledID == nil { self.lastPulledID = (try? clipboard.state())?.id }
            guard !content.isEmpty else { return }
            do {
                try clipboard.push(content)
            } catch {
                self.report(error)
            }
        }
    }

    @MainActor
    func pull(apply: Bool) {
        queue.async {
            guard self.prepare() else { return }
            let clipboard = self.clipboard
            guard let state = try? clipboard.state(), state.id != self.lastPulledID else { return }
            self.lastPulledID = state.id
            guard apply else { return }
            do {
                let content = try clipboard.fetch(state, filesInto: Self.cacheDirectory)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.write(content) }
                }
            } catch {
                self.report(error)
            }
        }
    }

    static func read(_ pasteboard: NSPasteboard) -> ClipboardContent {
        var content = ClipboardContent()
        content.files = pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        content.text = pasteboard.string(forType: .string)
        if content.files.isEmpty {
            if let png = pasteboard.data(forType: .png) {
                content.png = png
            } else if let tiff = pasteboard.data(forType: .tiff) {
                content.png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            }
        }
        return content
    }

    @MainActor
    private func write(_ content: ClipboardContent) {
        guard !content.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !content.files.isEmpty { pasteboard.writeObjects(content.files.map { $0 as NSURL }) }
        if let text = content.text, !text.isEmpty { pasteboard.setString(text, forType: .string) }
        if let png = content.png {
            pasteboard.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        }
        lastPushedChange = pasteboard.changeCount
    }

    // MARK: Arrastrar

    @MainActor
    func drop(_ files: [URL], x: Int, y: Int) {
        guard !files.isEmpty else { return }
        let what = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) elementos"
        onNotice?("Copiando \(what) a Windows…", false)
        let bundle = bundle
        queue.async {
            guard self.prepare() else {
                self.notice("Windows aún no responde al canal de control de Paralelo.", autoHide: true)
                return
            }
            do {
                try GuestTransfer(bundle: bundle).drop(files, x: x, y: y)
                self.notice(nil)
            } catch {
                self.report(error)
            }
        }
    }
}
