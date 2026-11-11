import Foundation
import Darwin
import IOKit

public struct CommandResult {
    public let data: Data
    public let errorData: Data
    public let code: Int32
    public var text: String { String(decoding: data + errorData, as: UTF8.self) }
}

public enum CommandRunner {
    // Files avoid pipe-buffer deadlocks for tools with large diagnostic output.
    public static func run(_ executable: String, _ arguments: [String],
                           cancellation: () -> Bool = { false },
                           heartbeat: () -> Void = {}) throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forge-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("out")
        let err = directory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        var environment = ProcessInfo.processInfo.environment
        // Privileged subprocesses use a fixed PATH and never inherit loader overrides.
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        for key in environment.keys where key.hasPrefix("DYLD_") { environment.removeValue(forKey: key) }
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        var wasCancelled = false
        while process.isRunning {
            if cancellation() {
                wasCancelled = true
                process.terminate()
                for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            heartbeat()
            Thread.sleep(forTimeInterval: 0.2)
        }
        process.waitUntilExit()
        if wasCancelled { throw ForgeError.cancelled }
        return CommandResult(data: try Data(contentsOf: out), errorData: try Data(contentsOf: err), code: process.terminationStatus)
    }

    @discardableResult
    public static func checked(_ executable: String, _ arguments: [String],
                               cancellation: () -> Bool = { false },
                               heartbeat: () -> Void = {}) throws -> Data {
        let result = try run(executable, arguments, cancellation: cancellation, heartbeat: heartbeat)
        guard result.code == 0 else {
            throw ForgeError.message("\(URL(fileURLWithPath: executable).lastPathComponent): \(result.text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1800))")
        }
        return result.data
    }

    public static func plist(_ executable: String, _ arguments: [String]) throws -> [String: Any] {
        let data = try checked(executable, arguments)
        guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ForgeError.message("Система повернула некоректні відомості про диск.")
        }
        if let error = value["ErrorMessage"] as? String { throw ForgeError.message(error) }
        return value
    }
}

public enum FileSafety {
    public static func identity(_ path: String) throws -> FileIdentity {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ForgeError.message("Оберіть звичайний локальний файл ISO або IMG. Символічні посилання не підтримуються.")
        }
        guard info.st_size > 0 else { throw ForgeError.message("Образ порожній.") }
        return FileIdentity(size: UInt64(info.st_size), device: UInt64(info.st_dev), inode: info.st_ino,
                            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    public static func mountPoint(for path: String) throws -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw ForgeError.message("Не вдалося визначити диск для \(path).") }
        return withUnsafePointer(to: &fs.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
    }

    public static func assertIdentity(_ image: ImageInfo) throws {
        guard try identity(image.path) == image.identity else {
            throw ForgeError.message("Образ змінився після вибору. Оберіть файл ще раз.")
        }
    }
}

public enum DiskSafety {
    public static func wholeID(_ identifier: String) -> String? {
        guard let match = identifier.range(of: "^disk[0-9]+", options: .regularExpression) else { return nil }
        return String(identifier[match])
    }
    public static func validWholeID(_ identifier: String) -> Bool {
        identifier.range(of: "^disk[0-9]+$", options: .regularExpression) != nil
    }
    public static func validPartitionID(_ identifier: String, parent: String) -> Bool {
        validWholeID(parent) && identifier.range(of: "^" + parent + "s[1-9][0-9]*$", options: .regularExpression) != nil
    }
    public static func partitionParentRejection(_ info: [String: Any]) -> String? {
        guard let id = info["DeviceIdentifier"] as? String, validWholeID(id), info["WholeDisk"] as? Bool == true else {
            return "Потрібен цілий фізичний диск із таблицею розділів."
        }
        guard info["Internal"] as? Bool == false else { return "Внутрішні диски захищені від запису." }
        guard info["VirtualOrPhysical"] as? String == "Physical" else { return "Віртуальні диски не доступні для запису." }
        guard info["WritableMedia"] as? Bool == true else { return "Диск захищений від запису." }
        guard (info["TotalSize"] as? NSNumber)?.uint64Value ?? 0 > 0 else { return "Невідомий обсяг диска." }
        return nil
    }

    public static let dataPartitionTypes: Set<String> = [
        "microsoft basic data", "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
        "dos_fat_12", "dos_fat_16", "dos_fat_32", "dos_fat_16_s", "windows_fat_32",
        "windows_fat_32_lba", "windows_fat_16", "linux", "linux filesystem",
        "linux_filesystem", "0fc63daf-8483-4772-8e79-3d69d8477de4", "apple_hfs", "apple_hfsx"
    ]
    public static let windowsPartitionTypes: Set<String> = [
        "microsoft basic data", "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
        "dos_fat_12", "dos_fat_16", "dos_fat_32", "dos_fat_16_s", "windows_fat_32",
        "windows_fat_32_lba", "windows_fat_16"
    ]
    public static func partitionRejection(_ info: [String: Any], parent: String, windows: Bool = false) -> String? {
        guard let id = info["DeviceIdentifier"] as? String, validPartitionID(id, parent: parent),
              info["ParentWholeDisk"] as? String == parent,
              info["WholeDisk"] as? Bool == false, info["PartitionMapPartition"] as? Bool == true else {
            return "Потрібен окремий фізичний розділ; логічні томи й знімки не підтримуються."
        }
        guard info["Internal"] as? Bool == false else { return "Внутрішні розділи захищені від запису." }
        guard info["WritableMedia"] as? Bool == true else { return "Розділ захищений від запису." }
        guard let size = info["Size"] as? NSNumber, size.uint64Value > 0,
              let offset = info["PartitionMapPartitionOffset"] as? NSNumber, offset.uint64Value > 0 else {
            return "Не вдалося перевірити межі розділу."
        }
        let content = (info["Content"] as? String ?? "").lowercased()
        guard dataPartitionTypes.contains(content) else {
            return "Захищено: службовий розділ, APFS-контейнер або непідтримуваний тип розділу."
        }
        if windows && !windowsPartitionTypes.contains(content) {
            return "Для Windows потрібен розділ Microsoft Basic Data, ExFAT, NTFS або FAT. Тип таблиці розділів не змінюється."
        }
        return nil
    }

    public static func partitionIDs(_ info: [String: Any]) -> Set<String> {
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]], !stores.isEmpty {
            return Set(stores.compactMap { $0["APFSPhysicalStore"] as? String })
        }
        if let id = info["DeviceIdentifier"] as? String { return [id] }
        return []
    }
    public static func rejection(_ info: [String: Any]) -> String? {
        guard let id = info["DeviceIdentifier"] as? String, validWholeID(id) else { return "Оберіть цілий фізичний диск." }
        guard info["WholeDisk"] as? Bool == true else { return "Розділи диска не підтримуються." }
        guard info["Internal"] as? Bool == false else { return "Внутрішні диски захищені від стирання." }
        guard info["VirtualOrPhysical"] as? String == "Physical" else { return "Віртуальні диски захищені від стирання." }
        guard info["BusProtocol"] as? String == "USB" else { return "Підтримуються лише USB-накопичувачі." }
        guard info["WritableMedia"] as? Bool == true else { return "Накопичувач захищений від запису." }
        guard (info["TotalSize"] as? NSNumber)?.uint64Value ?? 0 > 0 else { return "Невідомий обсяг накопичувача." }
        return nil
    }
    public static func physicalIDs(_ info: [String: Any]) -> Set<String> {
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]], !stores.isEmpty {
            return Set(stores.compactMap { ($0["APFSPhysicalStore"] as? String).flatMap(wholeID) })
        }
        return Set([(info["ParentWholeDisk"] as? String ?? info["DeviceIdentifier"] as? String ?? "")].compactMap(wholeID))
    }
}

public enum DiskCatalog {
    public static func info(_ path: String) throws -> [String: Any] {
        try CommandRunner.plist("/usr/sbin/diskutil", ["info", "-plist", path])
    }

    public static func protectedDisks(paths: [String]) throws -> Set<String> {
        var protected: Set<String> = []
        for path in paths {
            let mount = try FileSafety.mountPoint(for: path)
            let ids = DiskSafety.physicalIDs(try info(mount))
            guard !ids.isEmpty else { throw ForgeError.message("Не вдалося перевірити захист диска для \(path).") }
            protected.formUnion(ids)
        }
        return protected
    }

    private static func registryID(_ id: String) throws -> UInt64 {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, id) else { throw ForgeError.message("Накопичувач від'єднано.") }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw ForgeError.message("Накопичувач від'єднано.") }
        defer { IOObjectRelease(service) }
        var registry: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registry) == KERN_SUCCESS else { throw ForgeError.message("Не вдалося перевірити ідентичність USB.") }
        return registry
    }

    public static func device(_ id: String, scope: TargetScope = .disk) throws -> USBDevice {
        guard DiskSafety.validWholeID(id) else { throw ForgeError.message("Некоректний ідентифікатор диска.") }
        let detail = try info(id)
        let size = (detail["TotalSize"] as? NSNumber)?.uint64Value ?? 0
        let name = detail["MediaName"] as? String ?? "USB-накопичувач"
        let registry = try registryID(id)
        return USBDevice(id: id, name: name.isEmpty ? "USB-накопичувач" : name, size: size,
                         fingerprint: "\(id)|\(registry)|\(size)|\(detail["DeviceTreePath"] as? String ?? "")",
                         volumes: [], blockedReason: scope == .disk ? DiskSafety.rejection(detail) : DiskSafety.partitionParentRejection(detail))
    }

    public static func list(protecting paths: [String], scope: TargetScope = .disk) throws -> [USBDevice] {
        let protected = try protectedDisks(paths: scope == .disk ? ["/"] + paths : ["/"])
        let listing = try CommandRunner.plist("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        let layouts = listing["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        return try (listing["WholeDisks"] as? [String] ?? []).map { id in
            var usb = try device(id, scope: scope)
            let layout = layouts.first { $0["DeviceIdentifier"] as? String == id }
            usb.volumes = (layout?["Partitions"] as? [[String: Any]] ?? []).compactMap { $0["VolumeName"] as? String }.filter { !$0.isEmpty && $0 != "EFI" }
            if protected.contains(id) { usb.blockedReason = "Захищено: цей диск містить macOS, ISO або саму програму." }
            return usb
        }.sorted { $0.size < $1.size }
    }

    public static func protectedPartitions(paths: [String]) throws -> Set<String> {
        var protected: Set<String> = []
        for path in paths {
            let mount = try FileSafety.mountPoint(for: path)
            let ids = DiskSafety.partitionIDs(try info(mount))
            guard !ids.isEmpty else { throw ForgeError.message("Не вдалося перевірити розділ для \(path).") }
            protected.formUnion(ids)
        }
        return protected
    }

    public static func partition(_ id: String, parent: USBDevice, windows: Bool = false) throws -> DiskPartition {
        guard DiskSafety.validPartitionID(id, parent: parent.id) else { throw ForgeError.message("Некоректний ідентифікатор розділу.") }
        let detail = try info(id)
        let volume = detail["VolumeName"] as? String ?? ""
        let content = detail["Content"] as? String ?? ""
        return DiskPartition(id: id, parentID: parent.id, parentFingerprint: parent.fingerprint,
                             name: volume.isEmpty ? content : volume,
                             size: (detail["Size"] as? NSNumber)?.uint64Value ?? 0,
                             offset: (detail["PartitionMapPartitionOffset"] as? NSNumber)?.uint64Value ?? 0,
                             uuid: detail["DiskUUID"] as? String ?? "", content: content,
                             filesystem: detail["FilesystemUserVisibleName"] as? String ?? detail["FilesystemType"] as? String ?? content,
                             blockedReason: DiskSafety.partitionRejection(detail, parent: parent.id, windows: windows))
    }

    public static func listPartitions(devices: [USBDevice], protecting paths: [String], windows: Bool) throws -> [DiskPartition] {
        let protected = try protectedPartitions(paths: paths)
        let listing = try CommandRunner.plist("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        let layouts = listing["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        var partitions: [DiskPartition] = []
        for parent in devices {
            let layout = layouts.first { $0["DeviceIdentifier"] as? String == parent.id }
            for entry in layout?["Partitions"] as? [[String: Any]] ?? [] {
                guard let id = entry["DeviceIdentifier"] as? String else { continue }
                var part = try partition(id, parent: parent, windows: windows)
                if let reason = parent.blockedReason { part.blockedReason = reason }
                else if protected.contains(id) { part.blockedReason = "Захищено: розділ містить ISO, програму або журнал операції." }
                partitions.append(part)
            }
        }
        return partitions
    }

    public static func validatePartition(_ expected: DiskPartition, parent: USBDevice,
                                         protecting paths: [String], capacity: UInt64, windows: Bool) throws {
        let actualParent = try device(parent.id, scope: .partition)
        if let reason = actualParent.blockedReason { throw ForgeError.message(reason) }
        guard parent.fingerprint == actualParent.fingerprint, expected.parentFingerprint == actualParent.fingerprint else {
            throw ForgeError.message("Диск змінився або був перепідключений. Оберіть розділ ще раз.")
        }
        let actual = try partition(expected.id, parent: actualParent, windows: windows)
        if let reason = actual.blockedReason { throw ForgeError.message(reason) }
        guard actual.matches(expected) else { throw ForgeError.message("Ідентичність або межі розділу змінилися. Оберіть його ще раз.") }
        guard actual.offset <= actualParent.size, actual.size <= actualParent.size - actual.offset,
              actual.size >= capacity else { throw ForgeError.message("Образ не вміщується у вибраний розділ або його межі некоректні.") }
        let systemDisks = try protectedDisks(paths: ["/"])
        guard !systemDisks.contains(parent.id) else { throw ForgeError.message("Розділи системного диска захищені від запису.") }
        let protected = try protectedPartitions(paths: paths)
        guard !protected.contains(actual.id), !protected.contains(parent.id) else {
            throw ForgeError.message("Запис заборонено: вибраний розділ містить ISO, програму або журнал.")
        }
    }

    public static func validate(_ expected: USBDevice, protecting paths: [String], capacity: UInt64) throws {
        let actual = try device(expected.id)
        if let reason = actual.blockedReason { throw ForgeError.message(reason) }
        guard expected.fingerprint == actual.fingerprint else { throw ForgeError.message("USB-накопичувач змінився або був перепідключений. Оберіть його ще раз.") }
        guard actual.size >= capacity else { throw ForgeError.message("На накопичувачі замало місця для цього образу.") }
        let protected = try protectedDisks(paths: ["/"] + paths)
        guard !protected.contains(actual.id) else { throw ForgeError.message("Запис заборонено: диск містить macOS, вихідний ISO або програму.") }
    }
}
