import XCTest
import Foundation
import Darwin
@testable import ForgeCore

final class IntegrationTests: XCTestCase {
    private var temp: URL!
    private var wimTool: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/wimlib/bin/wimlib-imagex").path
    }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ISOForge-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        guard FileManager.default.isExecutableFile(atPath: wimTool) else { throw XCTSkip("Run scripts/fetch-wimlib.sh first") }
    }
    override func tearDownWithError() throws { if let temp { try FileManager.default.removeItem(at: temp) } }

    private func fixture(solid: Bool = false) throws -> URL {
        let source = temp.appendingPathComponent("WindowsSource")
        let payload = temp.appendingPathComponent("CapturedFiles")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data((0..<32768).map { UInt8(truncatingIfNeeded: $0 * 23) }).write(to: payload.appendingPathComponent("kernel-fixture.bin"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
        try Data(repeating: 0x4d, count: 65536).write(to: source.appendingPathComponent("efi/boot/bootx64.efi"))
        let wim = source.appendingPathComponent(solid ? "sources/install.esd" : "sources/install.wim")
        var options = ["capture", payload.path, wim.path, "Test", "--compress=" + (solid ? "LZMS" : "LZX")]
        if solid { options.append("--solid") }
        _ = try CommandRunner.checked(wimTool, options)
        try FileManager.default.copyItem(at: wim, to: source.appendingPathComponent("sources/boot.wim"))
        try Data("ISO Forge integration fixture — not a real OS installer.".utf8).write(to: source.appendingPathComponent("README.txt"))
        return source
    }

    func testWimSplitAndVerifyUsingBundledBinary() throws {
        let source = try fixture()
        let input = source.appendingPathComponent("sources/install.wim")
        // Sparse padding exercises the >4 GiB code path without a huge fixture.
        let fd = open(input.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(WindowsLayout.fat32Limit + 1)), 0)
        close(fd)
        let layout = try WindowsLayout.read(root: source)
        XCTAssertEqual(layout.splitFiles.count, 1)
        let usb = temp.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: false)
        var splitting = false
        try WindowsInstaller.populate(source: source, destination: usb, layout: layout, wimTool: wimTool,
                                      workDirectory: temp, cancellation: { false }, status: { if $0.phase == .splitting { splitting = true } })
        XCTAssertTrue(splitting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: usb.appendingPathComponent("sources/install.swm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: usb.appendingPathComponent("sources/install.wim").path))
        _ = try CommandRunner.checked(wimTool, ["verify", usb.appendingPathComponent("sources/install.swm").path])
        let extracted = temp.appendingPathComponent("Extracted")
        _ = try CommandRunner.checked(wimTool, ["apply", usb.appendingPathComponent("sources/install.swm").path, "1", extracted.path])
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("kernel-fixture.bin")),
                       try Data(contentsOf: temp.appendingPathComponent("CapturedFiles/kernel-fixture.bin")))
    }

    func testLargeSolidESDConvertsAndSplits() throws {
        let source = try fixture(solid: true)
        let input = source.appendingPathComponent("sources/install.esd")
        let fd = open(input.path, O_WRONLY)
        XCTAssertEqual(ftruncate(fd, off_t(WindowsLayout.fat32Limit + 1)), 0)
        close(fd)
        let layout = try WindowsLayout.read(root: source)
        let usb = temp.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: false)
        try WindowsInstaller.populate(source: source, destination: usb, layout: layout, wimTool: wimTool,
                                      workDirectory: temp, cancellation: { false }, status: { _ in })
        _ = try CommandRunner.checked(wimTool, ["verify", usb.appendingPathComponent("sources/install.swm").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: usb.appendingPathComponent("sources/install.esd").path))
    }

    func testWindowsISOInspectionAndPersistentFAT32Volume() throws {
        let source = try fixture()
        let iso = temp.appendingPathComponent("Windows тест.iso")
        _ = try CommandRunner.checked("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", iso.path, source.path])
        let inspected = try ImageInspector.inspect(iso)
        XCTAssertEqual(inspected.mode, .windows)
        XCTAssertEqual(inspected.bootArchitectures, ["x64"])
        let diskImage = temp.appendingPathComponent("Disposable USB.dmg")
        _ = try CommandRunner.checked("/usr/bin/hdiutil", ["create", "-size", "128m", "-fs", "MS-DOS FAT32", "-volname", "FORGETEST", "-layout", "MBRSPUD", diskImage.path])
        let mount = temp.appendingPathComponent("MountedUSB")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let attached = try CommandRunner.plist("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-plist", diskImage.path])
        let entries = attached["system-entities"] as? [[String: Any]] ?? []
        let device = try XCTUnwrap(entries.compactMap { $0["dev-entry"] as? String }.first)
        defer { _ = try? CommandRunner.run("/usr/bin/hdiutil", ["detach", device]) }
        let detail = try DiskCatalog.info(device)
        // Some macOS versions omit VirtualOrPhysical for image attachments.
        // Both an explicit Virtual value and missing physical identity fail closed.
        XCTAssertNotEqual(detail["VirtualOrPhysical"] as? String, "Physical")
        XCTAssertNotNil(DiskSafety.rejection(detail))
        let mountedISO = try MountedImage(path: iso.path)
        let layout = try WindowsLayout.read(root: mountedISO.root)
        try WindowsInstaller.populate(source: mountedISO.root, destination: mount, layout: layout, wimTool: wimTool,
                                      workDirectory: temp, cancellation: { false }, status: { _ in })
        _ = try CommandRunner.checked("/usr/bin/hdiutil", ["detach", device])
        let readBack = try MountedImage(path: diskImage.path)
        defer { readBack.detach() }
        for file in layout.files {
            XCTAssertEqual(try ByteIO.hashFile(source.appendingPathComponent(file.relative).path),
                           try ByteIO.hashFile(readBack.root.appendingPathComponent(file.relative).path))
        }
        mountedISO.detach()
    }
}
