import Foundation

public enum DisplayMode: String, Codable, Sendable {
    /// Ventana de QEMU (Cocoa) con la consola de Windows; necesaria para instalar Windows.
    case window
    /// Sin ventana: se usa con el escritorio RDP o con Coherence.
    case headless
}

/// Construye la línea de comandos de qemu-system-aarch64 para Windows 11 ARM sobre HVF.
/// Es una función pura para poder probarla sin QEMU instalado.
public struct QEMUCommandBuilder {
    public var bundle: VMBundle
    public var environment: QEMUEnvironment
    public var display: DisplayMode
    /// Si es true, la ISO de instalación tiene prioridad de arranque.
    public var bootFromInstaller: Bool
    /// Socket del proceso swtpm, o nil para arrancar sin TPM.
    public var tpmSocket: URL?
    /// ISO de herramientas de invitado, o nil si no existe.
    public var toolsISO: URL?

    public init(bundle: VMBundle, environment: QEMUEnvironment, display: DisplayMode,
                bootFromInstaller: Bool, tpmSocket: URL?, toolsISO: URL? = nil) {
        self.bundle = bundle
        self.environment = environment
        self.display = display
        self.bootFromInstaller = bootFromInstaller
        self.tpmSocket = tpmSocket
        self.toolsISO = toolsISO
    }

    /// QEMU separa opciones con comas; una coma literal en una ruta se escribe ",,".
    public static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: ",", with: ",,")
    }

    public func arguments() -> [String] {
        let config = bundle.configuration
        let runtime = bundle.runtime
        let e = Self.escape
        var args: [String] = []

        // Sin ",process=": esa subopción solo existe en Linux y QEMU falla en macOS.
        args += ["-name", e(config.name)]
        args += ["-machine", "virt", "-accel", "hvf", "-cpu", "host"]
        args += ["-smp", "cpus=\(config.cpuCount)", "-m", "\(config.memoryMB)"]
        args += ["-rtc", "base=localtime"]

        // UEFI
        args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(e(environment.firmwareCode.path))"]
        args += ["-drive", "if=pflash,format=qcow2,file=\(e(bundle.efiVarsURL.path))"]

        // Entrada y pantalla. Windows ARM trae drivers para XHCI/USB y ramfb (pantalla básica).
        args += ["-device", "qemu-xhci,id=xhci"]
        args += ["-device", "usb-kbd,bus=xhci.0", "-device", "usb-tablet,bus=xhci.0"]
        args += ["-device", "ramfb"]
        switch display {
        case .window: args += ["-display", "cocoa,show-cursor=on"]
        case .headless: args += ["-display", "none"]
        }

        // Disco: NVMe porque el instalador de Windows ARM lo reconoce sin drivers adicionales.
        let diskBoot = bootFromInstaller && config.installerISO != nil ? 2 : 0
        args += ["-drive", "if=none,id=disk0,format=qcow2,discard=unmap,file=\(e(bundle.diskURL.path))"]
        args += ["-device", "nvme,drive=disk0,serial=paralelo0,bootindex=\(diskBoot)"]

        // ISOs como memorias USB extraíbles (el instalador ARM no ve CD-ROM SCSI/IDE).
        if let iso = config.installerISO {
            args += ["-drive", "if=none,id=cd0,media=cdrom,readonly=on,file=\(e(iso))"]
            let boot = bootFromInstaller ? ",bootindex=0" : ""
            args += ["-device", "usb-storage,bus=xhci.0,drive=cd0,removable=on\(boot)"]
        }
        if let drivers = config.driversISO {
            args += ["-drive", "if=none,id=cd1,media=cdrom,readonly=on,file=\(e(drivers))"]
            args += ["-device", "usb-storage,bus=xhci.0,drive=cd1,removable=on"]
        }
        if let tools = toolsISO {
            args += ["-drive", "if=none,id=cd2,media=cdrom,readonly=on,file=\(e(tools.path))"]
            args += ["-device", "usb-storage,bus=xhci.0,drive=cd2,removable=on"]
        }

        // Red NAT con el RDP (3389) y el SSH (22) de Windows publicados solo en 127.0.0.1 del Mac.
        args += ["-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(config.rdpPort)-:3389"
                    + ",hostfwd=tcp:127.0.0.1:\(config.sshPort)-:22"]
        args += ["-device", "virtio-net-pci,netdev=net0"]

        if let tpm = tpmSocket {
            args += ["-chardev", "socket,id=chrtpm,path=\(e(tpm.path))"]
            args += ["-tpmdev", "emulator,id=tpm0,chardev=chrtpm"]
            args += ["-device", "tpm-tis-device,tpmdev=tpm0"]
        }

        args += ["-qmp", "unix:\(e(runtime.qmpSocket.path)),server=on,wait=off"]
        args += ["-pidfile", runtime.pidFile.path]
        return args
    }

    /// Argumentos de swtpm para el TPM 2.0 emulado.
    public func swtpmArguments() -> [String] {
        [
            "socket", "--tpm2",
            "--tpmstate", "dir=\(bundle.tpmStateURL.path)",
            "--ctrl", "type=unixio,path=\(bundle.runtime.tpmSocket.path)",
            "--terminate",
        ]
    }
}
