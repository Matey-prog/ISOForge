import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import ForgeCore

final class CoreTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("ISOForge-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    private var validDisk: [String: Any] {
        ["DeviceIdentifier": "disk7", "WholeDisk": true, "Internal": false,
         "VirtualOrPhysical": "Physical", "BusProtocol": "USB", "WritableMedia": true, "TotalSize": 16_000_000_000]
    }

    func testDiskSafetyAllowsOnlyWritableExternalWholePhysicalUSB() {
        XCTAssertNil(DiskSafety.rejection(validDisk))
        let forbidden: [(String, Any)] = [
            ("DeviceIdentifier", "disk7s1"), ("DeviceIdentifier", "disk7; touch /tmp/unsafe"),
            ("WholeDisk", false), ("Internal", true), ("VirtualOrPhysical", "Virtual"),
            ("BusProtocol", "Thunderbolt"), ("WritableMedia", false), ("TotalSize", 0)
        ]
        for (key, value) in forbidden {
            var info = validDisk; info[key] = value
            XCTAssertNotNil(DiskSafety.rejection(info), key)
        }
        for key in validDisk.keys {
            var info = validDisk; info.removeValue(forKey: key)
            XCTAssertNotNil(DiskSafety.rejection(info), "Missing " + key)
        }
    }

    func testProtectsAllPhysicalStoresBehindAnAPFSVolume() {
        let info: [String: Any] = ["ParentWholeDisk": "disk3", "APFSPhysicalStores": [
            ["APFSPhysicalStore": "disk0s2"], ["APFSPhysicalStore": "disk6s2"]]]
        XCTAssertEqual(DiskSafety.physicalIDs(info), ["disk0", "disk6"])
        XCTAssertEqual(DiskSafety.physicalIDs(["ParentWholeDisk": "disk6"]), ["disk6"])
        XCTAssertFalse(DiskSafety.validWholeID("disk3s1s1"))
        XCTAssertNil(DiskSafety.wholeID("/dev/disk5"))
    }

    func testFileIdentityRejectsSymlinksAndChangedSources() throws {
        let file = try write(Data(repeating: 3, count: 65536), "source.img")
        let original = try FileSafety.identity(file.path)
        let image = ImageInfo(path: file.path, identity: original, mode: .raw, isHybrid: true, hasOpticalBoot: false,
                              requiredCapacity: original.size, bootArchitectures: [], largeWindowsFiles: 0)
        try FileSafety.assertIdentity(image)
        try Data(repeating: 1, count: 70000).write(to: file)
        XCTAssertThrowsError(try FileSafety.assertIdentity(image))
        let link = temp.appendingPathComponent("symlink.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try FileSafety.identity(link.path))
        XCTAssertThrowsError(try FileSafety.identity(temp.path))
        let empty = try write(Data(), "empty.iso")
        XCTAssertThrowsError(try FileSafety.identity(empty.path))
    }

    func testShellAndAppleScriptQuotingPreserveUntrustedFilenames() throws {
        let value = "Український ISO 'quoted' \"double\" $HOME $(touch /tmp/should-never-run) `whoami` \\ end\nnext line"
        let result = try CommandRunner.checked("/bin/sh", ["-c", "printf %s " + Formatters.shellQuote(value)])
        XCTAssertEqual(String(decoding: result, as: UTF8.self), value)
        let apple = try CommandRunner.checked("/usr/bin/osascript", ["-e", "return " + Formatters.appleScriptQuote(value)])
        XCTAssertEqual(String(decoding: apple, as: UTF8.self), value + "\n")
    }

    func testImageDetectionDistinguishesHybridFromOpticalOnly() {
        var bytes = Data(repeating: 0, count: 131072)
        bytes.replaceSubrange(32769..<32774, with: Data("CD001".utf8))
        bytes.replaceSubrange(32775..<32798, with: Data("EL TORITO SPECIFICATION\0".utf8))
        XCTAssertTrue(ImageInspector.signatures(bytes).iso)
        XCTAssertTrue(ImageInspector.signatures(bytes).opticalBoot)
        XCTAssertFalse(ImageInspector.signatures(bytes).hybrid)
        bytes[510] = 0x55; bytes[511] = 0xaa; bytes[450] = 0x83; bytes[458] = 1
        XCTAssertTrue(ImageInspector.signatures(bytes).hybrid)
        bytes[450] = 0
        XCTAssertFalse(ImageInspector.signatures(bytes).hybrid)
        bytes.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        XCTAssertTrue(ImageInspector.signatures(bytes).hybrid)
        XCTAssertFalse(ImageInspector.signatures(Data()).iso)
    }

    func testRawCopyPaddingSHAAndTrailingGPTCleanup() throws {
        let data = Data((0..<2_000_003).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let src = try write(data, "input.img")
        let dst = try write(Data(repeating: 0x7f, count: 4_194_304), "target.img")
        let sourceFD = try ByteIO.openRead(src.path)
        defer { close(sourceFD) }
        let destinationFD = open(dst.path, O_RDWR)
        defer { close(destinationFD) }
        try ByteIO.clearTrailingMetadata(fd: destinationFD, imageSize: UInt64(data.count), deviceSize: 4_194_304, block: 512)
        var last: UInt64 = 0
        let hash = try ByteIO.copy(sourceFD: sourceFD, destinationFD: destinationFD, size: UInt64(data.count), alignTo: 512, cancellation: { false }) { done, total, _ in
            XCTAssertGreaterThanOrEqual(done, last); XCTAssertLessThanOrEqual(done, total); last = done
        }
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expected)
        XCTAssertEqual(last, UInt64(data.count))
        _ = lseek(destinationFD, 0, SEEK_SET)
        let actual = try ByteIO.hash(fd: destinationFD, size: UInt64(data.count), alignTo: 512, cancellation: { false }, progress: { _, _, _ in })
        XCTAssertEqual(actual, expected)
        let written = try Data(contentsOf: dst)
        XCTAssertEqual(written.prefix(data.count), data)
        XCTAssertTrue(written[data.count..<2_000_384].allSatisfy { $0 == 0 })
        XCTAssertTrue(written.suffix(1_048_576).allSatisfy { $0 == 0 })
        XCTAssertEqual(written.count, 4_194_304)
    }

    func testRawCancellationStopsBeforeNextBlockAndTruncationFails() throws {
        let src = try write(Data(repeating: 4, count: ByteIO.chunkSize * 2), "input.img")
        let dst = try write(Data(), "out.img")
        let sourceFD = try ByteIO.openRead(src.path)
        let destinationFD = open(dst.path, O_WRONLY)
        defer { close(sourceFD); close(destinationFD) }
        var cancel = false
        XCTAssertThrowsError(try ByteIO.copy(sourceFD: sourceFD, destinationFD: destinationFD,
                                             size: UInt64(ByteIO.chunkSize * 2), cancellation: { cancel }, progress: { _, _, _ in cancel = true })) { error in
            XCTAssertEqual(error as? ForgeError, .cancelled)
        }
        XCTAssertEqual(try Data(contentsOf: dst).count, ByteIO.chunkSize)
        _ = lseek(sourceFD, 0, SEEK_SET)
        XCTAssertThrowsError(try ByteIO.copy(sourceFD: sourceFD, destinationFD: destinationFD,
                                             size: UInt64(ByteIO.chunkSize * 3), cancellation: { false }, progress: { _, _, _ in }))
    }

    func testCorruptionAndUnalignedCapacityAreDetected() throws {
        let first = try write(Data(repeating: 1, count: 66000), "original")
        let second = try write(Data(repeating: 2, count: 66000), "corrupted")
        XCTAssertNotEqual(try ByteIO.hashFile(first.path), try ByteIO.hashFile(second.path))
        let fd = open(second.path, O_RDWR)
        defer { close(fd) }
        XCTAssertThrowsError(try ByteIO.clearTrailingMetadata(fd: fd, imageSize: 66000, deviceSize: 66000, block: 512))
        XCTAssertThrowsError(try ByteIO.hash(fd: fd, size: 66000, alignTo: 0, cancellation: { false }, progress: { _, _, _ in }))
    }

    func testWindowsLayoutAndVerifiedCopyWithUnicodeNames() throws {
        let source = temp.appendingPathComponent("Windows ISO 'тест'")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, data) in [("EFI/BOOT/BOOTX64.EFI", Data(repeating: 5, count: 12000)),
                             ("sources/boot.wim", Data(repeating: 4, count: 65536)),
                             ("sources/install.wim", Data(repeating: 2, count: 100000)),
                             ("Українська/довідка.txt", Data("Привіт!".utf8)), ("empty.txt", Data())] {
            let file = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let layout = try WindowsLayout.read(root: source)
        XCTAssertEqual(layout.architectures, ["x64"])
        XCTAssertGreaterThan(layout.requiredCapacity, layout.totalSize)
        let destination = temp.appendingPathComponent("USB")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var phases: Set<JobPhase> = []
        try WindowsInstaller.populate(source: source, destination: destination, layout: layout, wimTool: "/nonexistent",
                                      workDirectory: temp, cancellation: { false }, status: { phases.insert($0.phase) })
        XCTAssertTrue(phases.contains(.writing)); XCTAssertTrue(phases.contains(.verifying))
        for file in layout.files {
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(file.relative)),
                           try Data(contentsOf: destination.appendingPathComponent(file.relative)))
        }
        XCTAssertThrowsError(try WindowsInstaller.populate(source: source, destination: destination, layout: layout,
                                                            wimTool: "/nonexistent", workDirectory: temp, cancellation: { false }, status: { _ in }))
    }

    func testWindowsLayoutRejectsMissingEFIAndUnsupportedOversizedFile() throws {
        _ = try write(Data(repeating: 1, count: 128), "sources/boot.wim")
        XCTAssertThrowsError(try WindowsLayout.read(root: temp))
        _ = try write(Data(repeating: 1, count: 128), "efi/boot/bootx64.efi")
        let giant = try write(Data(), "payload.bin")
        let fd = open(giant.path, O_WRONLY)
        XCTAssertEqual(ftruncate(fd, off_t(WindowsLayout.fat32Limit + 1)), 0)
        close(fd)
        XCTAssertThrowsError(try WindowsLayout.read(root: temp))
        try FileManager.default.removeItem(at: giant)
        let wim = try write(Data(), "sources/install.wim")
        let wimFD = open(wim.path, O_WRONLY)
        XCTAssertEqual(ftruncate(wimFD, off_t(WindowsLayout.fat32Limit + 1)), 0)
        close(wimFD)
        let layout = try WindowsLayout.read(root: temp)
        XCTAssertEqual(layout.splitFiles.count, 1)
    }

    func testWindowsCancellationDoesNotCopyFiles() throws {
        _ = try write(Data(repeating: 1, count: 64), "sources/boot.wim")
        _ = try write(Data(repeating: 2, count: 64), "efi/boot/bootaa64.efi")
        let layout = try WindowsLayout.read(root: temp)
        XCTAssertEqual(layout.architectures, ["ARM64"])
        let dest = temp.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try WindowsInstaller.populate(source: temp, destination: dest, layout: layout,
                                                            wimTool: "/missing", workDirectory: temp, cancellation: { true }, status: { _ in })) { error in
            XCTAssertEqual(error as? ForgeError, .cancelled)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    func testStatusRoundTripAndCancellationSignal() throws {
        let reporter = JobReporter(session: temp)
        XCTAssertFalse(reporter.isCancelled)
        reporter.update(JobStatus(phase: .complete, fraction: 1, message: "Перевірено", checksum: "abcd"))
        let data = try Data(contentsOf: temp.appendingPathComponent("status.json"))
        let status = try JSONDecoder().decode(JobStatus.self, from: data)
        XCTAssertEqual(status.phase, .complete); XCTAssertEqual(status.checksum, "abcd")
        _ = try write(Data(), "cancel")
        XCTAssertTrue(reporter.isCancelled)
        XCTAssertThrowsError(try reporter.checkCancellation())
        XCTAssertTrue(try String(contentsOf: temp.appendingPathComponent("operation.log")).contains("Перевірено"))
    }

    func testSystemDiskProtectionFromLiveDiskutil() throws {
        let protected = try DiskCatalog.protectedDisks(paths: ["/", temp.path])
        XCTAssertFalse(protected.isEmpty)
        let list = try DiskCatalog.list(protecting: [temp.path])
        for device in list where protected.contains(device.id) { XCTAssertFalse(device.isAvailable) }
    }
}
