import Foundation
import ForgeCore
import Darwin

func execute(_ request: WriteRequest, reporter: JobReporter) throws {
    let fm = FileManager.default
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let tool = executable.deletingLastPathComponent().appendingPathComponent("wimlib-imagex")
    guard app.path == request.appPath, tool.path == request.wimToolPath else {
        throw ForgeError.message("Некоректне розташування допоміжного компонента. Перевстановіть ISO Forge.")
    }
    let protectedPaths = [request.image.path, executable.path, request.sessionPath]
    let validate = {
        try FileSafety.assertIdentity(request.image)
        if let partition = request.partition {
            guard !request.eject else { throw ForgeError.message("У режимі розділу вилучення всього диска заборонено.") }
            try DiskCatalog.validatePartition(partition, parent: request.device, protecting: protectedPaths,
                                              capacity: request.image.requiredCapacity, windows: request.image.mode == .windows)
        } else {
            try DiskCatalog.validate(request.device, protecting: protectedPaths, capacity: request.image.requiredCapacity)
        }
    }
    try reporter.checkCancellation()
    reporter.update(JobStatus(phase: .preparing, message: "Перевіряю ISO, ціль \(request.targetID) та захист системних дисків…"))
    try validate()
    let inspected = try ImageInspector.inspect(URL(fileURLWithPath: request.image.path), scope: request.scope)
    guard inspected.mode == request.image.mode, inspected.requiredCapacity == request.image.requiredCapacity else {
        throw ForgeError.message("Вміст образу змінився. Оберіть ISO ще раз.")
    }
    var touched = false
    var finished = false
    let parentDetails = try DiskCatalog.info(request.device.id)
    let parentBlock = (parentDetails["DeviceBlockSize"] as? NSNumber)?.intValue ?? 512
    let map = try request.partition.map { _ in
        try PartitionMapSnapshot.capture(path: request.device.rawPath, deviceSize: request.device.size, blockSize: parentBlock)
    }
    if let partition = request.partition { try map?.assertDisjoint(offset: partition.offset, size: partition.size) }
    defer {
        if touched && !finished {
            if let partition = request.partition {
                reporter.append("Операцію перервано; відмонтую лише \(partition.id).")
                if let args = try? PartitionOperations.unmountArguments(partitionID: partition.id, parentID: request.device.id) {
                    _ = try? CommandRunner.run("/usr/sbin/diskutil", args)
                }
            } else {
                reporter.append("Операцію перервано; намагаюся безпечно вилучити USB.")
                _ = try? CommandRunner.run("/usr/sbin/diskutil", ["eject", request.device.devicePath])
            }
        }
    }
    var checksum: String?
    if request.image.mode == .raw {
        reporter.update(JobStatus(phase: .preparing, fraction: 0.02,
                                  message: request.partition == nil ? "Відмонтую розділи USB…" : "Відмонтую лише \(request.targetID)…"))
        if let partition = request.partition {
            try PartitionOperations.unmount(partitionID: partition.id, parentID: request.device.id)
        } else {
            _ = try CommandRunner.checked("/usr/sbin/diskutil", ["unmountDisk", request.device.devicePath])
        }
        try reporter.checkCancellation()
        try validate()
        let details = try DiskCatalog.info(request.targetID)
        let block = (details["DeviceBlockSize"] as? NSNumber)?.intValue ?? 512
        guard block > 0 && block <= ByteIO.chunkSize && ByteIO.chunkSize % block == 0 else { throw ForgeError.message("Непідтримуваний розмір сектора USB.") }
        let sourceFD = try ByteIO.openRead(request.image.path)
        defer { close(sourceFD) }
        let destinationFD = open(request.rawTargetPath, O_RDWR | O_NOFOLLOW)
        guard destinationFD >= 0 else { throw ByteIO.systemError("Не вдалося відкрити USB для запису") }
        defer { close(destinationFD) }
        var node = stat()
        guard fstat(destinationFD, &node) == 0, (node.st_mode & S_IFMT) == S_IFCHR else { throw ForgeError.message("Ціль не є фізичним пристроєм.") }
        _ = fcntl(destinationFD, F_NOCACHE, 1)
        try validate()
        try reporter.checkCancellation()
        touched = true
        checksum = try RawImageWriter.write(sourceFD: sourceFD, destinationFD: destinationFD, sourceSize: request.image.size,
                                             targetSize: request.partition?.size ?? request.device.size, block: block, scope: request.scope,
                                             cancellation: { reporter.isCancelled }, status: reporter.update)
        try FileSafety.assertIdentity(request.image)
    } else {
        guard fm.isExecutableFile(atPath: tool.path) else { throw ForgeError.message("Компонент wimlib відсутній. Перевстановіть ISO Forge.") }
        let mounted = try MountedImage(path: request.image.path)
        defer { mounted.detach() }
        let layout = try WindowsLayout.read(root: mounted.root)
        if !layout.splitFiles.isEmpty {
            let free = (try fm.attributesOfFileSystem(forPath: request.sessionPath)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            let largest = layout.splitFiles.map(\.size).max() ?? 0
            let multiplier: UInt64 = layout.splitFiles.contains(where: { $0.relative.lowercased().hasSuffix(".esd") }) ? 6 : 2
            guard free > largest * multiplier + 1_073_741_824 else {
                throw ForgeError.message("Для підготовки великих WIM/ESD звільніть щонайменше \(Formatters.bytes(largest * multiplier + 1_073_741_824)) на диску Mac.")
            }
        }
        try validate()
        try reporter.checkCancellation()
        reporter.update(JobStatus(phase: .formatting, fraction: 0.03,
                                  message: request.partition == nil ? "Створюю таблицю MBR та розділ FAT32 WINUSB…"
                                      : "Форматую лише \(request.targetID) у FAT32. Таблиця розділів зберігається…"))
        touched = true
        // Do not terminate diskutil halfway through partition-table updates.
        if let partition = request.partition {
            try PartitionOperations.formatFAT32(partitionID: partition.id, parentID: request.device.id, validate: validate)
            try map?.assertUnchanged(path: request.device.rawPath)
            try validate()
        } else {
            _ = try CommandRunner.checked("/usr/sbin/diskutil", ["eraseDisk", "MS-DOS", "WINUSB", "MBR", request.device.devicePath])
        }
        if request.formatOnly {
            guard request.image.mode == .windows else { throw ForgeError.message("Режим лише форматування дозволений тільки для Windows.") }
            try map?.assertUnchanged(path: request.device.rawPath)
            finished = true
            return
        }
        try reporter.checkCancellation()
        let partition = request.partition?.id ?? request.device.id + "s1"
        let detail = try DiskCatalog.info(partition)
        guard detail["ParentWholeDisk"] as? String == request.device.id,
              (detail["FilesystemType"] as? String)?.lowercased() == "msdos",
              let mount = detail["MountPoint"] as? String, !mount.isEmpty else {
            throw ForgeError.message("Не вдалося змонтувати новий розділ FAT32 на USB.")
        }
        let destination = URL(fileURLWithPath: mount)
        let free = (try fm.attributesOfFileSystem(forPath: mount)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard free >= layout.totalSize else { throw ForgeError.message("Після форматування на USB замало місця.") }
        try WindowsInstaller.populate(source: mounted.root, destination: destination, layout: layout,
                                          wimTool: tool.path, workDirectory: reporter.session,
                                          cancellation: { reporter.isCancelled }, status: reporter.update)
        try FileSafety.assertIdentity(request.image)
        if let partition = request.partition {
            try PartitionOperations.unmount(partitionID: partition.id, parentID: request.device.id)
        } else {
            _ = try CommandRunner.checked("/usr/sbin/diskutil", ["unmountDisk", request.device.devicePath])
        }
        if !request.eject && request.partition == nil { _ = try CommandRunner.checked("/usr/sbin/diskutil", ["mount", partition]) }
    }
    try reporter.checkCancellation()
    try map?.assertUnchanged(path: request.device.rawPath)
    if request.eject {
        reporter.update(JobStatus(phase: .ejecting, fraction: 0.98, message: "Запис перевірено. Вилучаю USB…"))
        _ = try CommandRunner.checked("/usr/sbin/diskutil", ["eject", request.device.devicePath])
    }
    finished = true
    let message: String
    if request.partition != nil {
        message = "Запис у \(request.targetID) перевірено. Таблиця розділів не змінилася; інші розділи залишилися підключеними."
            + (request.image.mode == .raw ? " Завантаження залежить від підтримки запису в розділ самим образом." : "")
    } else {
        message = request.eject ? "Запис перевірено. USB безпечно вилучено — його можна від'єднати."
            : "Запис перевірено. Вилучіть USB у Finder перед від'єднанням."
    }
    reporter.update(JobStatus(phase: .complete, fraction: 1, message: message, checksum: checksum))
}

func main() -> Int32 {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--version" { print("ISO Forge Writer 1.2.2"); return 0 }
    guard args.count == 3, args[1] == "--request", geteuid() == 0 else {
        fputs("ForgeWriter requires an authorized ISO Forge write request.\n", stderr); return 2
    }
    var reporter: JobReporter?
    do {
        let requestURL = URL(fileURLWithPath: args[2])
        guard requestURL.lastPathComponent == "request.json" else { throw ForgeError.message("Некоректний запит.") }
        let request = try JSONDecoder().decode(WriteRequest.self, from: Data(contentsOf: requestURL))
        let session = requestURL.deletingLastPathComponent()
        var node = stat()
        guard request.sessionPath == session.path, lstat(session.path, &node) == 0,
              (node.st_mode & S_IFMT) == S_IFDIR, node.st_uid == request.ownerUID, request.ownerUID != 0,
              node.st_mode & 0o077 == 0 else { throw ForgeError.message("Небезпечний каталог операції. Запис заборонено.") }
        let current = JobReporter(session: session)
        reporter = current
        try execute(request, reporter: current)
        return 0
    } catch {
        let cancelled = (error as? ForgeError) == .cancelled
        reporter?.update(JobStatus(phase: cancelled ? .cancelled : .failed, message: error.localizedDescription))
        fputs(error.localizedDescription + "\n", stderr)
        return cancelled ? 130 : 1
    }
}

exit(main())
