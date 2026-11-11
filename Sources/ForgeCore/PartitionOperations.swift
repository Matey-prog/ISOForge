import Foundation
import Darwin

/// Saves the MBR and both GPT headers/entry arrays without unmounting sibling volumes.
public struct PartitionMapSnapshot {
    public struct Region {
        public let offset: UInt64
        public let data: Data
    }
    public let regions: [Region]
    private let layoutSignature: String?

    private static func diskIdentifier(from path: String) -> String? {
        guard let match = path.range(of: "/dev/r?(disk[0-9]+)$", options: .regularExpression) else { return nil }
        let tail = String(path[match])
        return tail.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "rdisk", with: "disk")
    }

    private static func captureLayoutSignature(_ diskID: String) throws -> String {
        let result = try CommandRunner.plist("/usr/sbin/diskutil", ["list", "-plist", diskID])
        guard let layout = (result["AllDisksAndPartitions"] as? [[String: Any]])?.first(where: { $0["DeviceIdentifier"] as? String == diskID }),
              let partitions = layout["Partitions"] as? [[String: Any]] else {
            throw ForgeError.message("Не вдалося отримати таблицю розділів через diskutil.")
        }
        var fields = [diskID, String((layout["Size"] as? NSNumber)?.uint64Value ?? 0), layout["Content"] as? String ?? ""]
        for partition in partitions {
            guard let id = partition["DeviceIdentifier"] as? String else { throw ForgeError.message("diskutil повернув неповний список розділів.") }
            let info = try DiskCatalog.info(id)
            fields.append([id, String((info["Size"] as? NSNumber)?.uint64Value ?? 0),
                           String((info["PartitionMapPartitionOffset"] as? NSNumber)?.uint64Value ?? 0),
                           info["Content"] as? String ?? ""].joined(separator: "|"))
        }
        return fields.joined(separator: "\n")
    }

    private static func readExactly(fd: Int32, offset: UInt64, count: Int, failure: String) throws -> Data {
        var data = Data(count: count)
        var completed = 0
        while completed < count {
            let result = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Int(pread(fd, base.advanced(by: completed), count - completed, off_t(offset + UInt64(completed))))
            }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else {
                if result < 0 { throw ByteIO.systemError(failure) }
                throw ForgeError.message(failure)
            }
            completed += result
        }
        return data
    }

    public static func capture(path: String, deviceSize: UInt64, blockSize: Int) throws -> PartitionMapSnapshot {
        guard [512, 1024, 2048, 4096].contains(blockSize), deviceSize >= UInt64(blockSize * 3) else {
            throw ForgeError.message("Не вдалося перевірити таблицю розділів диска.")
        }
        if let diskID = diskIdentifier(from: path) {
            return PartitionMapSnapshot(regions: [], layoutSignature: try captureLayoutSignature(diskID))
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ByteIO.systemError("Не вдалося відкрити диск для перевірки таблиці розділів") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        func readRegion(offset: UInt64, count: Int) throws -> Region {
            guard count > 0, count <= 8 * 1024 * 1024, offset <= deviceSize,
                  UInt64(count) <= deviceSize - offset else { throw ForgeError.message("Некоректні межі таблиці розділів.") }
            let data = try readExactly(fd: fd, offset: offset, count: count, failure: "Не вдалося зчитати таблицю розділів")
            return Region(offset: offset, data: data)
        }
        func little(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << ($1 * 8)) }
        }
        let mbr = try readRegion(offset: 0, count: blockSize)
        guard mbr.data[510] == 0x55, mbr.data[511] == 0xaa else {
            throw ForgeError.message("У диска немає відомої таблиці MBR/GPT. Запис у розділ заборонено.")
        }
        let primary = try readRegion(offset: UInt64(blockSize), count: blockSize)
        var regions = [mbr]
        let isGPT = primary.data.prefix(8) == Data("EFI PART".utf8)
        if !isGPT {
            guard !(0..<4).contains(where: { mbr.data[446 + $0 * 16 + 4] == 0xee }) else {
                throw ForgeError.message("Захисний MBR є, але GPT пошкоджено. Запис у розділ заборонено.")
            }
            guard !(0..<4).contains(where: { [0x05, 0x0f, 0x85].contains(mbr.data[446 + $0 * 16 + 4]) }) else {
                throw ForgeError.message("Розширені розділи MBR не підтримуються. Використайте звичайний розділ GPT або MBR.")
            }
            return PartitionMapSnapshot(regions: regions, layoutSignature: nil)
        }
        func entries(_ header: Region) throws -> Region {
            let lba = little(header.data, 72, 8)
            let count = little(header.data, 80, 4)
            let entrySize = little(header.data, 84, 4)
            guard lba < deviceSize / UInt64(blockSize), count > 0, count <= 16384,
                  entrySize >= 128, entrySize <= 1024 else { throw ForgeError.message("Некоректна структура GPT.") }
            let bytes = count * entrySize
            let aligned = (bytes + UInt64(blockSize) - 1) / UInt64(blockSize) * UInt64(blockSize)
            return try readRegion(offset: lba * UInt64(blockSize), count: Int(aligned))
        }
        let backupLBA = little(primary.data, 32, 8)
        guard backupLBA == deviceSize / UInt64(blockSize) - 1 else { throw ForgeError.message("Резервна GPT має некоректне розташування.") }
        let backup = try readRegion(offset: backupLBA * UInt64(blockSize), count: blockSize)
        guard backup.data.prefix(8) == Data("EFI PART".utf8) else { throw ForgeError.message("Резервна GPT пошкоджена.") }
        regions += [primary, try entries(primary), backup, try entries(backup)]
        return PartitionMapSnapshot(regions: regions, layoutSignature: nil)
    }

    public func assertDisjoint(offset: UInt64, size: UInt64) throws {
        guard size > 0, offset <= UInt64.max - size else { throw ForgeError.message("Некоректні межі розділу.") }
        let end = offset + size
        for region in regions where offset < region.offset + UInt64(region.data.count) && region.offset < end {
            throw ForgeError.message("Розділ перекриває таблицю MBR/GPT. Запис заборонено.")
        }
    }

    public func assertUnchanged(path: String) throws {
        if let layoutSignature {
            guard let diskID = Self.diskIdentifier(from: path), try Self.captureLayoutSignature(diskID) == layoutSignature else {
                throw ForgeError.message("Структура розділів змінилася під час операції. Перевірте диск перед подальшим використанням.")
            }
            return
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ByteIO.systemError("Не вдалося відкрити диск для повторної перевірки таблиці розділів") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        for region in regions {
            let data = try Self.readExactly(fd: fd, offset: region.offset, count: region.data.count,
                                            failure: "Не вдалося перевірити таблицю розділів після запису")
            guard data == region.data else { throw ForgeError.message("Таблиця розділів змінилася під час операції. Перевірте диск перед подальшим використанням.") }
        }
    }
}

public enum PartitionOperations {
    public static func unmountArguments(partitionID: String, parentID: String) throws -> [String] {
        guard DiskSafety.validPartitionID(partitionID, parent: parentID) else { throw ForgeError.message("Некоректний фізичний розділ.") }
        return ["unmount", "/dev/" + partitionID]
    }

    public static func unmount(partitionID: String, parentID: String) throws {
        let args = try unmountArguments(partitionID: partitionID, parentID: parentID)
        let info = try DiskCatalog.info(partitionID)
        guard info["ParentWholeDisk"] as? String == parentID, info["WholeDisk"] as? Bool == false else {
            throw ForgeError.message("Розділ змінився перед відмонтуванням.")
        }
        // diskutil returns a nonzero status for an already-unmounted partition on some macOS versions.
        guard let mount = info["MountPoint"] as? String, !mount.isEmpty else { return }
        _ = try CommandRunner.checked("/usr/sbin/diskutil", args)
    }

    public static func formatArguments(partitionID: String, parentID: String) throws -> [String] {
        guard DiskSafety.validPartitionID(partitionID, parent: parentID) else { throw ForgeError.message("Некоректний фізичний розділ.") }
        // newfs operates on the partition node, leaving the existing MBR/GPT type and geometry intact.
        return ["eraseVolume", "MS-DOS", "WINUSB", "/dev/" + partitionID]
    }

    public static func formatFAT32(partitionID: String, parentID: String, validate: () throws -> Void) throws {
        let format = try formatArguments(partitionID: partitionID, parentID: parentID)
        try validate()
        try unmount(partitionID: partitionID, parentID: parentID)
        try validate()
        _ = try CommandRunner.checked("/usr/sbin/diskutil", format)
    }

}

public enum RawImageWriter {
    @discardableResult
    public static func write(sourceFD: Int32, destinationFD: Int32, sourceSize: UInt64, targetSize: UInt64,
                             block: Int, scope: TargetScope,
                             cancellation: () -> Bool, status: (JobStatus) -> Void) throws -> String {
        guard block > 0, block <= ByteIO.chunkSize, ByteIO.chunkSize % block == 0,
              sourceSize <= UInt64.max - UInt64(block - 1) else { throw ForgeError.message("Некоректний розмір сектора або образу.") }
        let padded = (sourceSize + UInt64(block) - 1) / UInt64(block) * UInt64(block)
        guard sourceSize > 0, padded <= targetSize else {
            throw ForgeError.message("Образ не вміщується у вибрану ціль з урахуванням розміру сектора.")
        }
        if cancellation() { throw ForgeError.cancelled }
        if scope == .disk {
            try ByteIO.clearTrailingMetadata(fd: destinationFD, imageSize: sourceSize, deviceSize: targetSize, block: block)
        }
        let expected = try ByteIO.copy(sourceFD: sourceFD, destinationFD: destinationFD, size: sourceSize,
                                        alignTo: block, cancellation: cancellation) { done, total, speed in
            status(JobStatus(phase: .writing, fraction: 0.03 + Double(done) / Double(total) * 0.59,
                             bytesDone: done, bytesTotal: total, bytesPerSecond: speed,
                             message: scope == .partition ? "Записую дані лише у вибраний розділ…" : "Записую образ на USB…"))
        }
        guard lseek(destinationFD, 0, SEEK_SET) == 0 else { throw ByteIO.systemError("Не вдалося почати перевірку запису") }
        let actual = try ByteIO.hash(fd: destinationFD, size: sourceSize, alignTo: block,
                                     cancellation: cancellation) { done, total, speed in
            status(JobStatus(phase: .verifying, fraction: 0.62 + Double(done) / Double(total) * 0.34,
                             bytesDone: done, bytesTotal: total, bytesPerSecond: speed, message: "Зчитую записані дані й порівнюю SHA-256 з образом…"))
        }
        guard actual == expected else { throw ForgeError.message("SHA-256 записаних даних не збігається з образом. Спробуйте інший накопичувач.") }
        return actual
    }
}
