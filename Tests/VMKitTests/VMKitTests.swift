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
        XCTAssertEqual(netdev, ["user,id=net0,hostfwd=tcp:127.0.0.1:33891-:3389"])
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

    func testGuestScriptEnablesRemoteApp() {
        XCTAssertTrue(GuestTools.setupScript.contains("fDisabledAllowList"))
        XCTAssertTrue(GuestTools.setupScript.contains("fDenyTSConnections"))
    }

    func testHeadlessDisplay() {
        XCTAssertEqual(values(makeBuilder(display: .headless).arguments(), after: "-display"), ["none"])
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
