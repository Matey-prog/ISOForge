import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import ForgeCore

final class PartitionTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("ISOForge-partitions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private var validPartition: [String: Any] {
        ["DeviceIdentifier": "disk7s3", "ParentWholeDisk": "disk7", "WholeDisk": false,
         "PartitionMapPartition": true, "Internal": false, "WritableMedia": true,
         "Size": 1_000_000_000, "PartitionMapPartitionOffset": 268_435_456, "Content": "Microsoft Basic Data"]
    }
    private func partition(size: UInt64 = 1_000_000_000, offset: UInt64 = 268_435_456,
                           uuid: String = "GPT-UUID", fingerprint: String = "disk7|123", filesystem: String = "ExFAT") -> DiskPartition {
        DiskPartition(id: "disk7s3", parentID: "disk7", parentFingerprint: fingerprint, name: "Data",
                      size: size, offset: offset, uuid: uuid, content: "Microsoft Basic Data", filesystem: filesystem, blockedReason: nil)
    }
    private func write(_ bytes: Data, _ name: String) throws -> URL {
        let url = temp.appendingPathComponent(name); try bytes.write(to: url); return url
    }

    func testPartitionSafetyRejectsSystemServiceLogicalAndMalformedTargets() throws {
        XCTAssertNil(DiskSafety.partitionRejection(validPartition, parent: "disk7", windows: true))
        for id in ["disk7", "disk7s0", "disk7s3s1", "disk8s3", "disk7s3;id", "../disk7s3"] {
            XCTAssertFalse(DiskSafety.validPartitionID(id, parent: "disk7"), id)
            XCTAssertThrowsError(try PartitionOperations.formatArguments(partitionID: id, parentID: "disk7"))
        }
        for (key, value) in [("WholeDisk", true as Any), ("Internal", true), ("WritableMedia", false),
                             ("PartitionMapPartition", false), ("Size", 0), ("PartitionMapPartitionOffset", 0),
                             ("ParentWholeDisk", "disk8"), ("Content", "EFI"), ("Content", "Apple_APFS"),
                             ("Content", "Apple_Boot"), ("Content", "Apple_CoreStorage"), ("Content", "Apple_RAID")] {
            var info = validPartition; info[key] = value
            XCTAssertNotNil(DiskSafety.partitionRejection(info, parent: "disk7"), "\(key)=\(value)")
        }
        for key in validPartition.keys {
            var info = validPartition; info.removeValue(forKey: key)
            XCTAssertNotNil(DiskSafety.partitionRejection(info, parent: "disk7"), key)
        }
        var hfs = validPartition; hfs["Content"] = "Apple_HFS"
        XCTAssertNil(DiskSafety.partitionRejection(hfs, parent: "disk7"))
        XCTAssertNotNil(DiskSafety.partitionRejection(hfs, parent: "disk7", windows: true))
    }

    func testPartitionProtectionResolvesAPFSStoresWithoutBlockingSiblings() {
        let info: [String: Any] = ["DeviceIdentifier": "disk3s1s1", "APFSPhysicalStores": [
            ["APFSPhysicalStore": "disk0s2"], ["APFSPhysicalStore": "disk7s2"]]]
        let protected = DiskSafety.partitionIDs(info)
        XCTAssertEqual(protected, ["disk0s2", "disk7s2"])
        XCTAssertFalse(protected.contains("disk7s3"))
        XCTAssertEqual(DiskSafety.partitionIDs(["DeviceIdentifier": "disk7s3"]), ["disk7s3"])
        XCTAssertTrue(DiskSafety.partitionIDs([:]).isEmpty)
        var parent: [String: Any] = ["DeviceIdentifier": "disk7", "WholeDisk": true, "Internal": false,
                                   "VirtualOrPhysical": "Physical", "WritableMedia": true, "TotalSize": 2_000_000_000, "BusProtocol": "Thunderbolt"]
        XCTAssertNil(DiskSafety.partitionParentRejection(parent))
        parent["Internal"] = true
        XCTAssertNotNil(DiskSafety.partitionParentRejection(parent))
        parent["Internal"] = false; parent["VirtualOrPhysical"] = "Virtual"
        XCTAssertNotNil(DiskSafety.partitionParentRejection(parent))
    }

    func testPartitionIdentitySurvivesFormattingButRejectsGeometryAndReconnectChanges() {
        XCTAssertTrue(partition().matches(partition(filesystem: "FAT32")))
        for changed in [partition(size: 500_000_000), partition(offset: 512), partition(uuid: "OTHER"), partition(fingerprint: "disk7|456")] {
            XCTAssertFalse(partition().matches(changed))
        }
    }

    func testWriteRequestsRetainLegacyWholeDiskAndExactPartitionTargets() throws {
        let file = try write(Data(repeating: 1, count: 65536), "source.img")
        let identity = try FileSafety.identity(file.path)
        let image = ImageInfo(path: file.path, identity: identity, mode: .raw, isHybrid: true, hasOpticalBoot: false,
                              requiredCapacity: identity.size, bootArchitectures: [], largeWindowsFiles: 0)
        let disk = USBDevice(id: "disk7", name: "Test", size: 2_000_000_000, fingerprint: "disk7|123", volumes: [], blockedReason: nil)
        let old = WriteRequest(image: image, device: disk, eject: true, ownerUID: 501, sessionPath: temp.path, appPath: "/Applications/Test.app", wimToolPath: "/tool")
        let decoded = try JSONDecoder().decode(WriteRequest.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded.scope, .disk); XCTAssertEqual(decoded.rawTargetPath, "/dev/rdisk7")
        let new = WriteRequest(image: image, device: disk, eject: false, ownerUID: 501, sessionPath: temp.path, appPath: "/Applications/Test.app", wimToolPath: "/tool", partition: partition())
        let restored = try JSONDecoder().decode(WriteRequest.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(restored.scope, .partition); XCTAssertEqual(restored.targetID, "disk7s3")
        XCTAssertEqual(restored.rawTargetPath, "/dev/rdisk7s3"); XCTAssertFalse(restored.eject)
    }

    func testRawPartitionCopyPreservesUnusedTailAndVerifiesSHA() throws {
        let bytes = Data((0..<131_077).map { UInt8(truncatingIfNeeded: $0 * 19) })
        let source = try write(bytes, "input.img")
        let target = try write(Data(repeating: 0x7f, count: 2_097_152), "partition.img")
        let input = try ByteIO.openRead(source.path); let output = open(target.path, O_RDWR)
        defer { close(input); close(output) }
        let hash = try RawImageWriter.write(sourceFD: input, destinationFD: output, sourceSize: UInt64(bytes.count), targetSize: 2_097_152,
                                            block: 512, scope: .partition, cancellation: { false }, status: { _ in })
        XCTAssertEqual(hash, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let result = try Data(contentsOf: target)
        XCTAssertEqual(result.prefix(bytes.count), bytes)
        let padded = (bytes.count + 511) / 512 * 512
        XCTAssertTrue(result[bytes.count..<padded].allSatisfy { $0 == 0 })
        XCTAssertTrue(result[padded...].allSatisfy { $0 == 0x7f })
        XCTAssertEqual(result.count, 2_097_152)
    }

    func testCapacityOverflowAndCancellationLeavePartitionUntouched() throws {
        let source = try write(Data(repeating: 1, count: 513), "source.img")
        let original = Data(repeating: 0x7a, count: 4096)
        let target = try write(original, "partition.img")
        let input = try ByteIO.openRead(source.path); let output = open(target.path, O_RDWR)
        defer { close(input); close(output) }
        for (size, capacity) in [(UInt64(513), UInt64(513)), (0, 4096), (UInt64.max, UInt64.max)] {
            XCTAssertThrowsError(try RawImageWriter.write(sourceFD: input, destinationFD: output, sourceSize: size,
                                                         targetSize: capacity, block: 512, scope: .partition,
                                                         cancellation: { false }, status: { _ in }))
        }
        XCTAssertThrowsError(try RawImageWriter.write(sourceFD: input, destinationFD: output, sourceSize: 513,
                                                     targetSize: 4096, block: 512, scope: .partition,
                                                     cancellation: { true }, status: { _ in })) { XCTAssertEqual($0 as? ForgeError, .cancelled) }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    private func gptFixture() -> Data {
        var data = Data(repeating: 0, count: 1024 * 1024)
        func little(_ value: UInt64, at offset: Int, bytes: Int) {
            for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        data[510] = 0x55; data[511] = 0xaa; data[450] = 0xee
        for header in [512, data.count - 512] {
            data.replaceSubrange(header..<(header + 8), with: Data("EFI PART".utf8))
            little(2047, at: header + 32, bytes: 8)
            little(header == 512 ? 2 : 2046, at: header + 72, bytes: 8)
            little(4, at: header + 80, bytes: 4); little(128, at: header + 84, bytes: 4)
        }
        return data
    }

    func testGPTSnapshotDetectsBothTablesAndOverlappingTargets() throws {
        let original = gptFixture()
        let file = try write(original, "gpt.img")
        let snapshot = try PartitionMapSnapshot.capture(path: file.path, deviceSize: UInt64(original.count), blockSize: 512)
        XCTAssertEqual(snapshot.regions.count, 5)
        try snapshot.assertDisjoint(offset: 32768, size: 524288)
        XCTAssertThrowsError(try snapshot.assertDisjoint(offset: 0, size: 32768))
        XCTAssertThrowsError(try snapshot.assertDisjoint(offset: UInt64(original.count - 1024), size: 1024))
        for index in [0, 512, 1024, original.count - 1024, original.count - 512] {
            var changed = original; changed[index] ^= 1; try changed.write(to: file)
            XCTAssertThrowsError(try snapshot.assertUnchanged(path: file.path), "Changed metadata offset \(index)")
        }
        try original.write(to: file); try snapshot.assertUnchanged(path: file.path)
    }

    func testMalformedAndExtendedPartitionMapsAreRefused() throws {
        var bytes = Data(repeating: 0, count: 65536)
        let file = try write(bytes, "mbr.img")
        XCTAssertThrowsError(try PartitionMapSnapshot.capture(path: file.path, deviceSize: 65536, blockSize: 512))
        bytes[510] = 0x55; bytes[511] = 0xaa; bytes[450] = 0xee; try bytes.write(to: file)
        XCTAssertThrowsError(try PartitionMapSnapshot.capture(path: file.path, deviceSize: 65536, blockSize: 512))
        bytes[450] = 0x0f; try bytes.write(to: file)
        XCTAssertThrowsError(try PartitionMapSnapshot.capture(path: file.path, deviceSize: 65536, blockSize: 512))
        bytes[450] = 0x0c; try bytes.write(to: file)
        let snapshot = try PartitionMapSnapshot.capture(path: file.path, deviceSize: 65536, blockSize: 512)
        XCTAssertEqual(snapshot.regions.count, 1)
        var gpt = gptFixture(); gpt[512 + 80] = 0
        let broken = try write(gpt, "brokenGPT.img")
        XCTAssertThrowsError(try PartitionMapSnapshot.capture(path: broken.path, deviceSize: UInt64(gpt.count), blockSize: 512))
    }
}
