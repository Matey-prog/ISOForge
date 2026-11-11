import XCTest
import Foundation
import Darwin
@testable import ForgeCore

final class PartitionIntegrationTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ISOForge-partition-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private struct VirtualDisk {
        let parent: USBDevice
        let keepID: String
        let target: DiskPartition
        let block: Int
    }

    /// Mutations are permitted only after verifying that this exact new image backs the device.
    private func withDisposableDisk(scheme: String, operation: (VirtualDisk) throws -> Void) throws {
        let image = temp.appendingPathComponent("Disposable-" + scheme + ".img")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: nil))
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: 512 * 1024 * 1024); try handle.close()
        let attached = try CommandRunner.plist("/usr/bin/hdiutil", ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", image.path])
        let entities = attached["system-entities"] as? [[String: Any]] ?? []
        let path = try XCTUnwrap(entities.compactMap { $0["dev-entry"] as? String }.first {
            $0.hasPrefix("/dev/") && DiskSafety.validWholeID(String($0.dropFirst(5)))
        })
        defer { _ = try? CommandRunner.checked("/usr/bin/hdiutil", ["detach", path]) }
        let parentID = String(path.dropFirst(5))
        let detail = try DiskCatalog.info(path)
        guard detail["WholeDisk"] as? Bool == true, detail["VirtualOrPhysical"] as? String != "Physical" else {
            throw ForgeError.message("Test refuses to mutate a physical disk")
        }
        let images = try CommandRunner.plist("/usr/bin/hdiutil", ["info", "-plist"])["images"] as? [[String: Any]] ?? []
        guard images.contains(where: { entry in
            guard let imagePath = entry["image-path"] as? String,
                  URL(fileURLWithPath: imagePath).resolvingSymlinksInPath() == image.resolvingSymlinksInPath() else { return false }
            return (entry["system-entities"] as? [[String: Any]] ?? []).contains { $0["dev-entry"] as? String == path }
        }) else { throw ForgeError.message("Test image/device association is unverified") }
        let suffix = UUID().uuidString.prefix(5)
        let keepName = "KEEP" + suffix, targetName = "TARGET" + suffix
        _ = try CommandRunner.checked("/usr/sbin/diskutil", ["partitionDisk", path, scheme, "ExFAT", keepName, "64m", "ExFAT", targetName, "R"])
        let listing = try CommandRunner.plist("/usr/sbin/diskutil", ["list", "-plist", path])
        let layout = (listing["AllDisksAndPartitions"] as? [[String: Any]])?.first?["Partitions"] as? [[String: Any]] ?? []
        let keepID = try XCTUnwrap(layout.first { $0["VolumeName"] as? String == keepName }?["DeviceIdentifier"] as? String)
        let targetID = try XCTUnwrap(layout.first { $0["VolumeName"] as? String == targetName }?["DeviceIdentifier"] as? String)
        let parent = try DiskCatalog.device(parentID, scope: .partition)
        let target = try DiskCatalog.partition(targetID, parent: parent)
        XCTAssertNotNil(parent.blockedReason, "Production writer must still reject virtual disks")
        let block = (try DiskCatalog.info(parentID)["DeviceBlockSize"] as? NSNumber)?.intValue ?? 512
        try operation(VirtualDisk(parent: parent, keepID: keepID, target: target, block: block))
    }

    private func storeSource(_ source: URL, on disk: VirtualDisk) throws -> (URL, URL, String) {
        let mount = try XCTUnwrap(try DiskCatalog.info(disk.keepID)["MountPoint"] as? String)
        let iso = URL(fileURLWithPath: mount).appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: iso)
        let sentinel = URL(fileURLWithPath: mount).appendingPathComponent("Keep these files.txt")
        try Data("Сусідній розділ і вихідний образ мають зберегтися.".utf8).write(to: sentinel)
        let hash = try ByteIO.hashFile(sentinel.path)
        _ = try CommandRunner.checked("/usr/sbin/diskutil", ["unmount", "/dev/" + disk.keepID])
        _ = try CommandRunner.checked("/usr/sbin/diskutil", ["mount", "readOnly", "/dev/" + disk.keepID])
        XCTAssertEqual(try FileSafety.mountPoint(for: iso.path), mount)
        let protected = try DiskCatalog.protectedPartitions(paths: [iso.path])
        XCTAssertTrue(protected.contains(disk.keepID)); XCTAssertFalse(protected.contains(disk.target.id))
        XCTAssertThrowsError(try DiskCatalog.validatePartition(disk.target, parent: disk.parent, protecting: [iso.path], capacity: 1, windows: false))
        return (iso, sentinel, hash)
    }

    private func outsideHashes(_ disk: VirtualDisk) throws -> [String] {
        let fd = try ByteIO.openRead(disk.parent.rawPath)
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var result: [String] = []
        for (offset, size) in [(UInt64(0), disk.target.offset),
                               (disk.target.offset + disk.target.size, disk.parent.size - disk.target.offset - disk.target.size)] where size > 0 {
            guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { throw ByteIO.systemError("Test read seek failed") }
            result.append(try ByteIO.hash(fd: fd, size: size, alignTo: disk.block, cancellation: { false }, progress: { _, _, _ in }))
        }
        return result
    }

    private func exerciseRawWrite(_ source: URL, scheme: String) throws {
        try withDisposableDisk(scheme: scheme) { disk in
            let (iso, sentinel, sentinelHash) = try storeSource(source, on: disk)
            let sourceHash = try ByteIO.hashFile(iso.path)
            let image = try ImageInspector.inspect(iso, scope: .partition)
            if source.pathExtension == "iso" {
                XCTAssertFalse(image.isHybrid)
                XCTAssertThrowsError(try ImageInspector.inspect(iso, scope: .disk))
            }
            _ = try CommandRunner.checked("/usr/sbin/diskutil", PartitionOperations.unmountArguments(partitionID: disk.target.id, parentID: disk.parent.id))
            let snapshot = try PartitionMapSnapshot.capture(path: disk.parent.devicePath, deviceSize: disk.parent.size, blockSize: disk.block)
            try snapshot.assertDisjoint(offset: disk.target.offset, size: disk.target.size)
            let before = try outsideHashes(disk)
            let input = try ByteIO.openRead(iso.path), output = open(disk.target.rawPath, O_RDWR | O_NOFOLLOW)
            guard output >= 0 else { close(input); throw ByteIO.systemError("Test partition open failed") }
            let actual: String
            do {
                defer { close(input); close(output) }
                _ = fcntl(output, F_NOCACHE, 1)
                actual = try RawImageWriter.write(sourceFD: input, destinationFD: output, sourceSize: image.size,
                                                   targetSize: disk.target.size, block: disk.block, scope: .partition,
                                                   cancellation: { false }, status: { _ in })
            }
            XCTAssertEqual(actual, sourceHash)
            try snapshot.assertUnchanged(path: disk.parent.devicePath)
            XCTAssertEqual(try outsideHashes(disk), before, "Every byte outside target partition must remain unchanged")
            XCTAssertEqual(try ByteIO.hashFile(sentinel.path), sentinelHash)
            XCTAssertEqual(try ByteIO.hashFile(iso.path), sourceHash)
            XCTAssertNotNil(try DiskCatalog.info(disk.keepID)["MountPoint"])
        }
    }

    func testOpticalISOWriteToGPTPartitionPreservesSiblingAndBothGPTTables() throws {
        let folder = temp.appendingPathComponent("OpticalSource")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data(repeating: 0x6b, count: 524288).write(to: folder.appendingPathComponent("payload.bin"))
        let iso = temp.appendingPathComponent("Optical.iso")
        _ = try CommandRunner.checked("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", iso.path, folder.path])
        try exerciseRawWrite(iso, scheme: "GPT")
    }

    func testRawIMGWriteToMBRPartitionPreservesSiblingAndMBR() throws {
        var bytes = Data(repeating: 0x3a, count: 1_048_577)
        bytes[510] = 0x55; bytes[511] = 0xaa
        let image = temp.appendingPathComponent("Hybrid.img"); try bytes.write(to: image)
        try exerciseRawWrite(image, scheme: "MBR")
    }

    func testWindowsPartitionFormatAndCopyPreservesSourceSiblingAndPartitionGeometry() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Windows-layout-test.iso")
        try withDisposableDisk(scheme: "GPT") { disk in
            let (iso, sentinel, sentinelHash) = try storeSource(fixture, on: disk)
            let sourceHash = try ByteIO.hashFile(iso.path)
            let inspected = try ImageInspector.inspect(iso, scope: .partition)
            XCTAssertEqual(inspected.mode, .windows)
            let mounted = try MountedImage(path: iso.path); defer { mounted.detach() }
            let layout = try WindowsLayout.read(root: mounted.root)
            _ = try CommandRunner.checked("/usr/sbin/diskutil", PartitionOperations.unmountArguments(partitionID: disk.target.id, parentID: disk.parent.id))
            let snapshot = try PartitionMapSnapshot.capture(path: disk.parent.devicePath, deviceSize: disk.parent.size, blockSize: disk.block)
            let before = try outsideHashes(disk)
            try PartitionOperations.formatFAT32(partitionID: disk.target.id, parentID: disk.parent.id) {
                let parentInfo = try DiskCatalog.info(disk.parent.id)
                guard parentInfo["VirtualOrPhysical"] as? String != "Physical" else { throw ForgeError.message("Unsafe test target") }
                let current = try DiskCatalog.partition(disk.target.id, parent: disk.parent, windows: true)
                guard current.matches(disk.target), current.isAvailable else { throw ForgeError.message("Test target changed") }
            }
            let afterFormat = try DiskCatalog.partition(disk.target.id, parent: disk.parent)
            XCTAssertTrue(afterFormat.matches(disk.target))
            try snapshot.assertUnchanged(path: disk.parent.devicePath)
            let targetInfo = try DiskCatalog.info(disk.target.id)
            XCTAssertEqual(targetInfo["FilesystemType"] as? String, "msdos")
            let mount = try XCTUnwrap(targetInfo["MountPoint"] as? String)
            try WindowsInstaller.populate(source: mounted.root, destination: URL(fileURLWithPath: mount), layout: layout,
                                          wimTool: "/unused-for-small-fixture", workDirectory: temp, cancellation: { false }, status: { _ in })
            for file in layout.files {
                XCTAssertEqual(try ByteIO.hashFile(mounted.root.appendingPathComponent(file.relative).path),
                               try ByteIO.hashFile(URL(fileURLWithPath: mount).appendingPathComponent(file.relative).path))
            }
            _ = try CommandRunner.checked("/usr/sbin/diskutil", PartitionOperations.unmountArguments(partitionID: disk.target.id, parentID: disk.parent.id))
            try snapshot.assertUnchanged(path: disk.parent.devicePath)
            XCTAssertEqual(try outsideHashes(disk), before)
            XCTAssertEqual(try ByteIO.hashFile(sentinel.path), sentinelHash)
            XCTAssertEqual(try ByteIO.hashFile(iso.path), sourceHash)
            XCTAssertNotNil(try DiskCatalog.info(disk.keepID)["MountPoint"])
        }
    }
}
