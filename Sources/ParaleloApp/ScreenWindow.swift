import AppKit
import Carbon.HIToolbox
import VMKit

/// Ventanas con la pantalla de cada VM (VNC por socket local), una por VM.
@MainActor
final class ScreenWindows {
    static let shared = ScreenWindows()
    private var controllers: [UUID: ScreenWindowController] = [:]

    func show(_ bundle: VMBundle) {
        let id = bundle.configuration.id
        let controller = controllers[id] ?? ScreenWindowController(bundle: bundle) { [weak self] in
            self?.controllers[id] = nil
        }
        controllers[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class ScreenWindowController: NSWindowController, NSWindowDelegate {
    private let client: VNCClient
    private let screen: VMScreenView
    private let onClose: () -> Void
    private var sizedToGuest = false

    init(bundle: VMBundle, onClose: @escaping () -> Void) {
        client = VNCClient(socketPath: bundle.runtime.vncSocket.path)
        screen = VMScreenView(client: client)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = bundle.configuration.name
        window.contentView = screen
        window.contentMinSize = NSSize(width: 320, height: 240)
        window.center()
        window.setFrameAutosaveName("Pantalla-\(bundle.configuration.id.uuidString)")
        super.init(window: window)
        window.delegate = self

        // Si llegan imágenes más rápido de lo que se dibujan, solo se dibuja la última.
        let latest = LatestFrame()
        client.onFrame = { [weak screen] frame in
            guard latest.put(frame) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let frame = latest.take() { screen?.show(frame) }
                }
            }
        }
        client.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.statusChanged(status) }
            }
        }
        client.start()
        window.makeFirstResponder(screen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func statusChanged(_ status: VNCClient.Status) {
        screen.status = status
        // La primera vez, la ventana toma el tamaño de la pantalla de Windows (sin pasarse de la del Mac).
        if case .connected(let width, let height) = status, !sizedToGuest, width > 0, height > 0,
           let window, let visible = window.screen?.visibleFrame {
            sizedToGuest = true
            let scale = min(1, (visible.width - 40) / CGFloat(width), (visible.height - 60) / CGFloat(height))
            window.setContentSize(NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale))
            window.contentAspectRatio = NSSize(width: width, height: height)
        }
    }

    func windowWillClose(_ notification: Notification) {
        client.stop()
        onClose()
    }

    func windowDidResignKey(_ notification: Notification) {
        screen.releaseAllKeys()
    }
}

/// Última imagen recibida, compartida entre el hilo del VNC y el principal.
final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: VNCClient.Frame?

    /// Devuelve true si no había otra pendiente (hay que programar el dibujo).
    func put(_ new: VNCClient.Frame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = frame == nil
        frame = new
        return wasEmpty
    }

    func take() -> VNCClient.Frame? {
        lock.lock()
        defer { lock.unlock() }
        let current = frame
        frame = nil
        return current
    }
}

/// Muestra la pantalla de la VM y envía teclado y ratón a Windows.
final class VMScreenView: NSView {
    private let client: VNCClient
    private var guestSize = CGSize.zero
    private var buttons: UInt8 = 0
    private var pressedKeys = Set<UInt32>()
    private var scrollRemainder: CGFloat = 0
    private let message = NSTextField(labelWithString: "Conectando con la VM…")

    var status: VNCClient.Status = .connecting {
        didSet { updateMessage() }
    }

    init(client: VNCClient) {
        self.client = client
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    private func updateMessage() {
        switch status {
        case .connected:
            message.isHidden = true
        case .connecting:
            break // se reintenta cada segundo: se deja el mensaje que hubiera
        case .disconnected:
            layer?.contents = nil
            message.isHidden = false
            message.stringValue = "La VM está apagada. La pantalla aparecerá al iniciarla."
        }
    }

    // MARK: Imagen

    func show(_ frame: VNCClient.Frame) {
        guard frame.width > 0, frame.height > 0,
              let provider = CGDataProvider(data: frame.pixels as CFData),
              let image = CGImage(
                width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        guestSize = CGSize(width: frame.width, height: frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
        message.isHidden = true
    }

    // MARK: Ratón

    /// Windows dibuja su propio puntero en la pantalla: se oculta el del Mac para no ver dos.
    private lazy var invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: invisibleCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Convierte un punto de la vista a coordenadas de la pantalla de Windows (la imagen se ajusta sin deformarse).
    private func guestPoint(_ event: NSEvent) -> (x: Int, y: Int)? {
        guard guestSize.width > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / guestSize.width, bounds.height / guestSize.height)
        let shown = CGSize(width: guestSize.width * scale, height: guestSize.height * scale)
        let origin = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
        let x = (p.x - origin.x) / scale
        let y = (origin.y + shown.height - p.y) / scale
        return (Int(min(max(x, 0), guestSize.width - 1)), Int(min(max(y, 0), guestSize.height - 1)))
    }

    private func sendPointer(_ event: NSEvent, buttons extra: UInt8 = 0) {
        guard let point = guestPoint(event) else { return }
        client.sendPointer(x: point.x, y: point.y, buttons: buttons | extra)
    }

    private func button(_ event: NSEvent) -> UInt8 {
        switch event.buttonNumber {
        case 0: return 1
        case 1: return 4
        case 2: return 2
        default: return 0
        }
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttons |= button(event)
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttons &= ~button(event)
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func scrollWheel(with event: NSEvent) {
        // Cada "clic" de rueda es una pulsación de los botones 4 (arriba) o 5 (abajo).
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollRemainder += event.scrollingDeltaY
        while abs(scrollRemainder) >= step {
            let wheel: UInt8 = scrollRemainder > 0 ? 8 : 16
            sendPointer(event, buttons: wheel)
            sendPointer(event)
            scrollRemainder -= scrollRemainder > 0 ? step : -step
        }
    }

    // MARK: Teclado

    private var isISOKeyboard: Bool {
        Int(KBGetLayoutType(Int16(LMGetKbdType()))) == kKeyboardISO
    }

    private func key(_ code: UInt16, down: Bool) {
        guard let scancode = KeyMap.scancode(macKeyCode: code, isISOKeyboard: isISOKeyboard) else { return }
        if down { pressedKeys.insert(scancode) } else { pressedKeys.remove(scancode) }
        client.sendKey(scancode: scancode, down: down)
    }

    override func keyDown(with event: NSEvent) {
        // Windows repite las teclas por su cuenta mientras están pulsadas.
        if !event.isARepeat { key(event.keyCode, down: true) }
    }

    override func keyUp(with event: NSEvent) {
        key(event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let down: Bool
        switch Int(event.keyCode) {
        case kVK_Shift, kVK_RightShift: down = flags.contains(.shift)
        case kVK_Control, kVK_RightControl: down = flags.contains(.control)
        case kVK_Option, kVK_RightOption: down = flags.contains(.option)
        case kVK_Command, kVK_RightCommand: down = flags.contains(.command)
        case kVK_CapsLock:
            // El Mac solo avisa al cambiar el estado: se envía una pulsación completa.
            key(event.keyCode, down: true)
            key(event.keyCode, down: false)
            return
        default: return
        }
        key(event.keyCode, down: down)
    }

    /// Atajos con Comando (Cmd+Q, Cmd+W…) siguen siendo del Mac.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) ? super.performKeyEquivalent(with: event) : false
    }

    func releaseAllKeys() {
        for scancode in pressedKeys { client.sendKey(scancode: scancode, down: false) }
        pressedKeys.removeAll()
    }

    override func resignFirstResponder() -> Bool {
        releaseAllKeys()
        return super.resignFirstResponder()
    }
}
