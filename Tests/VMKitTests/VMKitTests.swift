import XCTest
@testable import VMKit

final class QEMUCommandBuilderTests: XCTestCase {
    private func makeBuilder(iso: String? = "/isos/Win11_ARM64.iso", tpm: Bool = true,
                             display: DisplayMode = .window, boot: Bool = true) -> QEMUCommandBuilder {
        let config = VMConfiguration(
            id: UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!,
            name: "Windows 11", cpuCount: 6, memoryMB: 8192, diskSizeGB: 64,
            installerISO: iso, rdpPort: 33891)
        let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/x.paralelovm"), configuration: config)
        let env = QEMUEnvironment(
            qemuSystem: URL(fileURLWithPath: "/opt/homebrew/bin/qemu-system-aarch64"),
            qemuImg: URL(fileURLWithPath: "/opt/homebrew/bin/qemu-img"),
            swtpm: URL(fileURLWithPath: "/opt/homebrew/bin/swtpm"),
            firmwareCode: URL(fileURLWithPath: "/fw/code.fd"),
            firmwareVarsTemplate: URL(fileURLWithPath: "/fw/vars.fd"))
        return QEMUCommandBuilder(
            bundle: bundle, environment: env, display: display, bootFromInstaller: boot,
            tpmSocket: tpm ? URL(fileURLWithPath: "/tmp/tpm.sock") : nil)
    }

    /// Valor que sigue a una opción, p. ej. value(after: "-m").
    private func values(_ args: [String], after flag: String) -> [String] {
        args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
    }

    func testNameHasNoLinuxOnlySuboptions() {
        XCTAssertEqual(values(makeBuilder().arguments(), after: "-name"), ["Windows 11"])
    }

    func testUsesHVFAndResources() {
        let args = makeBuilder().arguments()
        XCTAssertEqual(values(args, after: "-accel"), ["hvf"])
        XCTAssertEqual(values(args, after: "-cpu"), ["host"])
        XCTAssertEqual(values(args, after: "-smp"), ["cpus=6"])
        XCTAssertEqual(values(args, after: "-m"), ["8192"])
    }

    func testDiskIsNVMeAndInstallerBootsFirst() {
        let devices = values(makeBuilder().arguments(), after: "-device")
        XCTAssertTrue(devices.contains("nvme,drive=disk0,serial=paralelo0,bootindex=2"))
        XCTAssertTrue(devices.contains("usb-storage,bus=xhci.0,drive=cd0,removable=on,bootindex=0"))
    }

    func testNoInstallerBootsFromDisk() {
        let devices = values(makeBuilder(iso: nil).arguments(), after: "-device")
        XCTAssertTrue(devices.contains("nvme,drive=disk0,serial=paralelo0,bootindex=0"))
        XCTAssertFalse(devices.contains { $0.contains("drive=cd0") })
    }

    func testRDPForwardedOnlyToLocalhost() {
        let netdev = values(makeBuilder().arguments(), after: "-netdev")
        XCTAssertEqual(netdev, ["user,id=net0,hostfwd=tcp:127.0.0.1:33891-:3389,hostfwd=tcp:127.0.0.1:34891-:22"])
    }

    func testTPMIsOptional() {
        XCTAssertTrue(makeBuilder(tpm: true).arguments().contains("-tpmdev"))
        XCTAssertFalse(makeBuilder(tpm: false).arguments().contains("-tpmdev"))
    }

    func testToolsISOAttachedWhenPresent() {
        var builder = makeBuilder()
        XCTAssertFalse(values(builder.arguments(), after: "-drive").contains { $0.contains("id=cd2") })
        builder.toolsISO = URL(fileURLWithPath: "/vms/x.paralelovm/paralelo-tools.iso")
        XCTAssertTrue(values(builder.arguments(), after: "-drive").contains { $0.contains("id=cd2") })
    }

    func testAutounattendBypassesTPMAndIsWellFormed() throws {
        let xml = GuestTools.autounattend
        XCTAssertTrue(xml.contains(#"HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck"#))
        XCTAssertTrue(xml.contains("BypassNRO"))
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testGuestScriptEnablesRemoteApp() {
        XCTAssertTrue(GuestTools.setupScript.contains("fDisabledAllowList"))
        XCTAssertTrue(GuestTools.setupScript.contains("fDenyTSConnections"))
    }

    func testHeadlessDisplay() {
        XCTAssertEqual(values(makeBuilder(display: .headless).arguments(), after: "-display"), ["none"])
    }

    func testSharedFolderAndResume() {
        var builder = makeBuilder()
        XCTAssertFalse(values(builder.arguments(), after: "-netdev")[0].contains("smb="))
        XCTAssertFalse(builder.arguments().contains("-loadvm"))
        builder.sharedFolder = URL(fileURLWithPath: "/Users/fer,nando")
        builder.loadSnapshot = VMController.suspendSnapshotName
        XCTAssertTrue(values(builder.arguments(), after: "-netdev")[0].hasSuffix(",smb=/Users/fer,,nando"))
        XCTAssertEqual(values(builder.arguments(), after: "-loadvm"), ["paralelo-suspendida"])
    }

    func testVNCOnPrivateSocket() {
        for display in [DisplayMode.window, .headless] {
            let vnc = values(makeBuilder(display: display).arguments(), after: "-vnc")
            XCTAssertEqual(vnc.count, 1)
            XCTAssertTrue(vnc[0].hasPrefix("unix:/tmp/paralelo-"))
            XCTAssertTrue(vnc[0].hasSuffix("/abcdef12/vnc.sock"))
        }
    }

    func testQMPSocketUsesShortRuntimePath() {
        let qmp = values(makeBuilder().arguments(), after: "-qmp")
        XCTAssertEqual(qmp.count, 1)
        XCTAssertTrue(qmp[0].hasPrefix("unix:/tmp/paralelo-"))
        XCTAssertTrue(qmp[0].contains("/abcdef12/qmp.sock"))
    }

    func testCommasInPathsAreEscaped() {
        XCTAssertEqual(QEMUCommandBuilder.escape("/a,b/c.iso"), "/a,,b/c.iso")
        let drives = values(makeBuilder(iso: "/isos/win,11.iso").arguments(), after: "-drive")
        XCTAssertTrue(drives.contains { $0.hasSuffix("file=/isos/win,,11.iso") })
    }
}

final class RDPFileTests: XCTestCase {
    func testRemoteAppFile() {
        let app = RemoteApp(name: "Word", program: #"C:\Office\WINWORD.EXE"#)
        let text = RDPFile(port: 33890, username: "fernando", app: app, shareHomeFolder: true).contents()
        XCTAssertTrue(text.contains("full address:s:127.0.0.1:33890\r\n"))
        XCTAssertTrue(text.contains("remoteapplicationmode:i:1\r\n"))
        XCTAssertTrue(text.contains(#"remoteapplicationprogram:s:C:\Office\WINWORD.EXE"#))
        XCTAssertTrue(text.contains("username:s:fernando\r\n"))
        XCTAssertTrue(text.contains("drivestoredirect:s:*\r\n"))
    }

    func testDesktopFileHasNoRemoteApp() {
        let text = RDPFile(port: 33890, username: "", app: nil, shareHomeFolder: false).contents()
        XCTAssertFalse(text.contains("remoteapplicationmode"))
        XCTAssertFalse(text.contains("username:"))
        XCTAssertTrue(text.contains("dynamic resolution:i:1"))
    }

    func testFreeRDPArguments() {
        var config = VMConfiguration(name: "w", rdpPort: 33892)
        config.coherence.username = "fer"
        let app = RemoteApp(name: "Excel", program: #"C:\X\EXCEL.EXE"#)
        let args = CoherenceLauncher.freeRDPArguments(configuration: config, app: app, homeFolder: "/Users/fer")
        XCTAssertTrue(args.contains("/v:127.0.0.1:33892"))
        XCTAssertTrue(args.contains("/u:fer"))
        XCTAssertTrue(args.contains("/drive:Mac,/Users/fer"))
        XCTAssertTrue(args.contains(#"/app:program:C:\X\EXCEL.EXE,name:Excel"#))
    }

    func testAppFileNameStripsInvalidCharacters() {
        XCTAssertEqual(RemoteApp(name: "A/B:C", program: "x").fileName, "A-B-C")
    }
}

final class ModelTests: XCTestCase {
    func testConfigurationRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = VMConfiguration(name: "Win", installerISO: "/a.iso")
        try VMBundle(url: dir, configuration: config).save()
        let loaded = try VMBundle.load(from: dir).configuration
        XCTAssertEqual(loaded.id, config.id)
        XCTAssertEqual(loaded.name, "Win")
        XCTAssertEqual(loaded.coherence.apps.count, RemoteApp.defaults.count)
    }

    func testValidation() {
        XCTAssertThrowsError(try VMConfiguration(name: " ").validate())
        XCTAssertThrowsError(try VMConfiguration(name: "w", memoryMB: 1024).validate())
        XCTAssertThrowsError(try VMConfiguration(name: "w", diskSizeGB: 16).validate())
        XCTAssertNoThrow(try VMConfiguration(name: "w").validate())
    }

    func testSnapshotNames() {
        XCTAssertEqual(try VMController.validSnapshotName(" antes-de-office "), "antes-de-office")
        XCTAssertThrowsError(try VMController.validSnapshotName("a b"))
        XCTAssertThrowsError(try VMController.validSnapshotName("x; quit"))
        XCTAssertThrowsError(try VMController.validSnapshotName("año"))
    }

    func testParseQemuImgSnapshots() throws {
        let json = """
        {"virtual-size": 68719476736, "filename": "disk.qcow2", "format": "qcow2",
         "snapshots": [
           {"icount": 0, "vm-state-size": 0, "date-sec": 1700000000, "date-nsec": 0,
            "vm-clock-nsec": 0, "name": "limpio", "vm-clock-sec": 0, "id": "1"},
           {"vm-state-size": 524288000, "date-sec": 1700001000, "date-nsec": 0,
            "vm-clock-nsec": 0, "name": "con-office", "vm-clock-sec": 120, "id": "2"}
         ]}
        """
        let snaps = try VMSnapshot.parse(qemuImgInfoJSON: Data(json.utf8))
        XCTAssertEqual(snaps.map(\.name), ["limpio", "con-office"])
        XCTAssertFalse(snaps[0].includesMemory)
        XCTAssertTrue(snaps[1].includesMemory)
        XCTAssertEqual(snaps[1].date, Date(timeIntervalSince1970: 1_700_001_000))
    }

    func testParseWithoutSnapshots() throws {
        let snaps = try VMSnapshot.parse(qemuImgInfoJSON: Data(#"{"format":"qcow2"}"#.utf8))
        XCTAssertTrue(snaps.isEmpty)
    }
}

final class GuestAppsTests: XCTestCase {
    func testParseScannerOutput() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let output = [
            "WARN\tAdd-Type no disponible",
            "APP\tWord\tMicrosoft.Office.WINWORD.EXE.15\tC:\\Office\\WINWORD.EXE\t\t\(png)",
            "APP\tCalculadora\tMicrosoft.WindowsCalculator_8wekyb3d8bbwe!App\tC:\\Windows\\explorer.exe\tshell:AppsFolder\\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App\t",
            "APP\tword\tdup\tC:\\x.exe\t\t",
            "APP\tSin programa\tid\t\t\t",
            "basura",
        ].joined(separator: "\r\n")
        let apps = AppScanner.parse(output)
        XCTAssertEqual(apps.map(\.name), ["Calculadora", "Word"])
        XCTAssertTrue(apps[0].isStoreApp)
        XCTAssertNil(apps[0].iconPNG)
        XCTAssertFalse(apps[1].isStoreApp)
        XCTAssertEqual(apps[1].iconPNG, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(apps[1].makeRemoteApp().appUserModelID, "Microsoft.Office.WINWORD.EXE.15")
    }

    func testDiscoveredAppMatchesExistingApps() {
        let found = DiscoveredApp(name: "Microsoft Edge", appUserModelID: "MSEdge",
                                  program: #"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"#)
        XCTAssertTrue(RemoteApp.defaults.contains { found.matches($0) })
        XCTAssertFalse(found.matches(RemoteApp(name: "Otra", program: #"C:\otra.exe"#)))
    }

    func testScannerScriptIsASCII() {
        XCTAssertTrue(AppScanner.script.unicodeScalars.allSatisfy(\.isASCII))
        XCTAssertTrue(AppScanner.script.contains("shell:AppsFolder"))
    }

    func testRemoteAppDecodesOldConfigWithoutAUMID() throws {
        let json = #"{"id":"ABCDEF12-0000-0000-0000-000000000000","name":"X","program":"C:\\x.exe","arguments":""}"#
        let app = try JSONDecoder().decode(RemoteApp.self, from: Data(json.utf8))
        XCTAssertNil(app.appUserModelID)
    }

    func testSSHPortAndArguments() {
        var config = VMConfiguration(name: "w", rdpPort: 33890)
        config.coherence.username = "Fernando Lagos"
        XCTAssertEqual(config.sshPort, 34890)
        let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/x.paralelovm"), configuration: config)
        let args = GuestShell(bundle: bundle).sshArguments(command: "cmd")
        XCTAssertEqual(Array(args.suffix(4)), ["-l", "Fernando Lagos", "127.0.0.1", "cmd"])
        XCTAssertTrue(args.contains("34890"))
        XCTAssertTrue(args.contains("/vms/x.paralelovm/ssh/id_ed25519"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
    }

    func testSetupScriptAuthorizesParaleloKey() {
        XCTAssertTrue(GuestTools.setupScript.contains("paralelo.pub"))
        XCTAssertTrue(GuestTools.setupScript.contains("administrators_authorized_keys"))
        XCTAssertTrue(GuestTools.setupScript.contains("OpenSSH.Server"))
    }
}

final class ICNSTests: XCTestCase {
    private func fakePNG(size: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        data.append(Data("IHDR".utf8))
        for value in [size, size] {
            data.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        data.append(contentsOf: [8, 6, 0, 0, 0])
        return data
    }

    func testWrapsPNGWithTypeForItsSize() throws {
        let png = fakePNG(size: 256)
        XCTAssertEqual(ICNS.pngSize(png)?.width, 256)
        let icns = try XCTUnwrap(ICNS.make(png: png))
        XCTAssertEqual(Array(icns.prefix(4)), Array("icns".utf8))
        XCTAssertEqual(Array(icns[4..<8]), [0, 0, 0, UInt8(16 + png.count)])
        XCTAssertEqual(Array(icns[8..<12]), Array("ic08".utf8))
        XCTAssertEqual(icns.suffix(png.count), png)
    }

    func testRejectsNonStandardSizes() {
        XCTAssertNil(ICNS.make(png: fakePNG(size: 48)))
        XCTAssertNil(ICNS.make(png: Data("no es png".utf8)))
    }
}

final class VNCTests: XCTestCase {
    func testClientMessages() {
        XCTAssertEqual(VNCMessages.setPixelFormatBGRA().count, 20)
        XCTAssertEqual(VNCMessages.updateRequest(incremental: true, width: 1024, height: 768),
                       [3, 1, 0, 0, 0, 0, 0x04, 0x00, 0x03, 0x00])
        XCTAssertEqual(VNCMessages.pointerEvent(x: 300, y: 2, buttons: 1), [5, 1, 0x01, 0x2C, 0, 2])
        XCTAssertEqual(VNCMessages.qemuKeyEvent(scancode: 0xB8, down: true),
                       [255, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0xB8])
        let encodings = VNCMessages.setEncodings([0, -223])
        XCTAssertEqual(encodings, [2, 0, 0, 2, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x21])
    }

    func testFramebufferBlitAndCopy() {
        var fb = Framebuffer(width: 4, height: 3)
        let red: [UInt8] = [0, 0, 255, 0]
        fb.blit(red + red, x: 1, y: 0, width: 2, height: 1)
        XCTAssertEqual(Array(fb.pixels[4..<8]), red)
        XCTAssertEqual(Array(fb.pixels[0..<4]), [0, 0, 0, 0])
        // Copia solapada hacia abajo: la fila 0 baja a la 1 y la 1 a la 2.
        fb.copy(fromX: 0, fromY: 0, toX: 0, toY: 1, width: 4, height: 2)
        XCTAssertEqual(Array(fb.pixels[(4 + 1) * 4..<(4 + 2) * 4]), red)
        XCTAssertEqual(Array(fb.pixels[(8 + 1) * 4..<(8 + 2) * 4]), [0, 0, 0, 0])
        XCTAssertEqual(fb.frame().pixels.count, 4 * 3 * 4)
    }

    func testKeyMap() {
        XCTAssertEqual(KeyMap.scancode(macKeyCode: 0x00), 0x1E) // A
        XCTAssertEqual(KeyMap.scancode(macKeyCode: 0x3D), 0xB8) // Opción derecha = AltGr
        XCTAssertEqual(KeyMap.scancode(macKeyCode: 0x7E), 0xC8) // flecha arriba
        XCTAssertEqual(KeyMap.scancode(macKeyCode: 0x0A, isISOKeyboard: true), 0x29)
        XCTAssertEqual(KeyMap.scancode(macKeyCode: 0x32, isISOKeyboard: true), 0x56)
        XCTAssertNil(KeyMap.scancode(macKeyCode: 0x3F)) // Fn
    }
}

final class GuestAgentTests: XCTestCase {
    func testAgentScriptIsASCIIAndMountsMacFolder() {
        XCTAssertTrue(GuestTools.agentScript.unicodeScalars.allSatisfy(\.isASCII))
        XCTAssertTrue(GuestTools.agentScript.contains(#"net use Z: \\10.0.2.4\qemu"#))
        XCTAssertTrue(GuestTools.agentScript.contains("to-mac.txt"))
        XCTAssertTrue(GuestTools.agentLauncher.contains(#""C:\ProgramData\Paralelo\paralelo-agent.ps1""#))
    }

    func testSetupInstallsAgentAndAllowsGuestSMB() {
        XCTAssertTrue(GuestTools.setupScript.contains("paralelo-agent.vbs"))
        XCTAssertTrue(GuestTools.setupScript.contains("EnableInsecureGuestLogons"))
        XCTAssertGreaterThanOrEqual(GuestTools.version, 4)
    }

    func testSuspendedMarkerDrivesState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir, configuration: VMConfiguration(name: "w"))
        let env = QEMUEnvironment(
            qemuSystem: URL(fileURLWithPath: "/x"), qemuImg: URL(fileURLWithPath: "/x"), swtpm: nil,
            firmwareCode: URL(fileURLWithPath: "/x"), firmwareVarsTemplate: URL(fileURLWithPath: "/x"))
        let controller = VMController(bundle: bundle, environment: env)
        XCTAssertEqual(controller.state(), .stopped)
        try Data().write(to: bundle.suspendedMarkerURL)
        XCTAssertEqual(controller.state(), .suspended)
        XCTAssertThrowsError(try controller.restoreSnapshot(named: "limpio"))
    }
}
