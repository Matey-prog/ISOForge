import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ForgeCore
import Darwin

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ukrainian, english
    var id: String { rawValue }
    var effectiveCode: String {
        switch self {
        case .ukrainian: return "uk"
        case .english: return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? Locale.current.identifier.lowercased()
            return preferred.hasPrefix("uk") ? "uk" : "en"
        }
    }
}

extension String {
    var appLocalized: String {
        let stored = UserDefaults.standard.string(forKey: "ISOForge.language") ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: stored) ?? .system
        let code = language.effectiveCode
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else { return self }
        return bundle.localizedString(forKey: self, value: self, table: "Localizable")
    }
}


private func populateWindowsFiles(_ request: WriteRequest) throws {
    let reporter = JobReporter(session: URL(fileURLWithPath: request.sessionPath))
    try reporter.checkCancellation()
    try FileSafety.assertIdentity(request.image)
    let mounted = try MountedImage(path: request.image.path)
    defer { mounted.detach() }
    let layout = try WindowsLayout.read(root: mounted.root)
    let partitionID = request.partition?.id ?? request.device.id + "s1"
    let detail = try DiskCatalog.info(partitionID)
    guard detail["ParentWholeDisk"] as? String == request.device.id,
          (detail["FilesystemType"] as? String)?.lowercased() == "msdos",
          let mount = detail["MountPoint"] as? String, !mount.isEmpty else {
        throw ForgeError.message("Розділ FAT32 не змонтовано для копіювання файлів.")
    }
    let destination = URL(fileURLWithPath: mount)
    let free = (try FileManager.default.attributesOfFileSystem(forPath: mount)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
    guard free >= layout.totalSize else { throw ForgeError.message("Після форматування на USB замало місця.") }
    try WindowsInstaller.populate(source: mounted.root, destination: destination, layout: layout,
                                  wimTool: request.wimToolPath, workDirectory: reporter.session,
                                  cancellation: { reporter.isCancelled }, status: reporter.update)
    try FileSafety.assertIdentity(request.image)
    if request.partition == nil {
        _ = try CommandRunner.checked("/usr/sbin/diskutil", ["unmountDisk", request.device.devicePath])
        if request.eject {
            _ = try CommandRunner.checked("/usr/sbin/diskutil", ["eject", request.device.devicePath])
        } else {
            _ = try CommandRunner.checked("/usr/sbin/diskutil", ["mount", "/dev/" + partitionID])
        }
    }
    let message = request.partition != nil
        ? "Запис у \(request.targetID) перевірено. Таблиця розділів не змінилася; інші розділи залишилися підключеними."
        : request.eject ? "Запис перевірено. USB безпечно вилучено — його можна від'єднати."
        : "Запис перевірено. Вилучіть USB у Finder перед від'єднанням."
    reporter.update(JobStatus(phase: .complete, fraction: 1, message: message))
}

@MainActor
final class AppModel: ObservableObject {
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "ISOForge.language") }
    }
    @Published var image: ImageInfo?
    @Published var imageLoading = false
    @Published var devices: [USBDevice] = []
    @Published var partitions: [DiskPartition] = []
    @Published private(set) var scope: TargetScope = .disk
    @Published var selectedID: String?
    @Published var selectedPartitionID: String?
    @Published var scanning = false
    @Published var busy = false
    @Published var cancellationRequested = false
    @Published var ejectAfterWrite = true
    @Published var status: JobStatus?
    @Published var notice: String?
    @Published var showConfirmation = false
    @Published var showHelp = false
    @Published var confirmationText = ""
    @Published var acknowledged = false
    @Published var rawPartitionAcknowledged = false
    @Published var operationStarted: Date?
    private(set) var session: URL?
    private var timer: Timer?
    private var imageGeneration = UUID()
    private var scanHasSucceeded = false
    private var scannedImagePath: String?
    private var scannedScope: TargetScope?
    private var imageURL: URL?
    private var activity: NSObjectProtocol?
    private let fm = FileManager.default

    var locale: Locale { Locale(identifier: language.effectiveCode) }

    var selectedDevice: USBDevice? { devices.first { $0.id == selectedID } }
    var visiblePartitions: [DiskPartition] { partitions.filter { $0.parentID == selectedID } }
    var selectedPartition: DiskPartition? { visiblePartitions.first { $0.id == selectedPartitionID } }
    var targetID: String? { scope == .partition ? selectedPartition?.id : selectedDevice?.id }
    var targetSize: UInt64 { scope == .partition ? selectedPartition?.size ?? 0 : selectedDevice?.size ?? 0 }
    var targetAvailable: Bool { selectedDevice?.isAvailable == true && (scope == .disk || selectedPartition?.isAvailable == true) }
    var needsRawPartitionAcknowledgment: Bool { scope == .partition && image?.mode == .raw }
    var createTitle: String { scope == .partition ? "Записати у розділ" : "Створити завантажувальний USB" }
    var ready: Bool {
        guard !busy, !imageLoading, !scanning, scanHasSucceeded, scannedScope == scope,
              let image, scannedImagePath == image.path, targetAvailable else { return false }
        return targetSize >= image.requiredCapacity
    }
    var availableCount: Int { devices.filter(\.isAvailable).count }
    var buttonHint: String {
        if imageLoading { return "Перевіряю образ…" }
        if image == nil { return "Оберіть ISO або IMG, щоб почати." }
        guard let selectedDevice else { return scope == .partition ? "Оберіть зовнішній диск і його розділ." : "Оберіть USB-накопичувач." }
        if let reason = selectedDevice.blockedReason { return reason }
        if scope == .partition {
            guard let selectedPartition else { return "Оберіть розділ для запису." }
            if let reason = selectedPartition.blockedReason { return reason }
        }
        if let image, targetSize < image.requiredCapacity { return "Потрібен обсяг щонайменше \(Formatters.bytes(image.requiredCapacity))." }
        return scope == .partition ? "Дані лише вибраного розділу буде стерто. Інші розділи збережуться." : "Усі дані на вибраному USB буде стерто."
    }

    private var protectedPaths: [String] {
        var paths = [Bundle.main.bundleURL.path] + (image.map { [$0.path] } ?? [])
        let jobs = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ISO Forge/Jobs")
        if fm.fileExists(atPath: jobs.path) { paths.append(jobs.path) }
        return paths
    }

    func setScope(_ value: TargetScope) {
        guard !busy, value != scope else { return }
        scope = value; selectedID = nil; selectedPartitionID = nil
        showConfirmation = false; scanHasSucceeded = false; status = nil
        if let imageURL { loadImage(imageURL) } else { refreshDisks() }
    }

    func selectDevice(_ id: String?) {
        selectedID = id; selectedPartitionID = nil; showConfirmation = false
        if status?.phase.isTerminal == true { status = nil }
    }

    func selectPartition(_ id: String) {
        selectedPartitionID = id; showConfirmation = false
        if status?.phase.isTerminal == true { status = nil }
    }

    init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "ISOForge.language") ?? "") ?? .system
        refreshDisks()
    }

    func chooseImage() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Оберіть завантажувальний образ"
        panel.prompt = "Обрати образ"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data, UTType(filenameExtension: "img") ?? .diskImage]
        if panel.runModal() == .OK, let url = panel.url { loadImage(url) }
    }

    func loadImage(_ url: URL) {
        guard !busy else { return }
        let hasScope = url.startAccessingSecurityScopedResource()
        let generation = UUID()
        let requestedScope = scope
        imageGeneration = generation
        imageURL = url
        imageLoading = true; image = nil; status = nil; notice = nil; showConfirmation = false
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ImageInfo, Error> in
                Result { try ImageInspector.inspect(url, scope: requestedScope) }
            }.value
            if hasScope { url.stopAccessingSecurityScopedResource() }
            guard generation == imageGeneration else { return }
            imageLoading = false
            switch result {
            case .success(let value): image = value
            case .failure(let error): notice = error.localizedDescription
            }
            refreshDisks()
        }
    }

    func clearImage() {
        guard !busy else { return }
        imageGeneration = UUID(); imageURL = nil; imageLoading = false; image = nil; status = nil; notice = nil; showConfirmation = false
        refreshDisks()
    }

    func refreshDisks(silent: Bool = false) {
        guard !busy, !scanning else { return }
        scanning = true
        let paths = protectedPaths
        let requestedScope = scope
        let windows = image?.mode == .windows
        Task {
            let result = await Task.detached { () -> Result<([USBDevice], [DiskPartition]), Error> in
                Result {
                    let disks = try DiskCatalog.list(protecting: paths, scope: requestedScope)
                    let partitions = requestedScope == .partition ? try DiskCatalog.listPartitions(devices: disks, protecting: paths, windows: windows) : []
                    return (disks, partitions)
                }
            }.value
            scanning = false
            if paths != protectedPaths || requestedScope != scope || windows != (image?.mode == .windows) {
                refreshDisks(silent: silent); return
            }
            switch result {
            case .success(let (devices, partitions)):
                let previous = selectedDevice
                let previousPartition = selectedPartition
                scanHasSucceeded = true
                scannedImagePath = image?.path
                scannedScope = scope
                self.devices = devices
                self.partitions = partitions
                if let selectedID, !devices.contains(where: { $0.id == selectedID && $0.isAvailable && (previous == nil || $0.fingerprint == previous?.fingerprint) }) {
                    self.selectedID = nil
                    self.selectedPartitionID = nil
                    self.showConfirmation = false
                }
                if let selectedPartitionID, !visiblePartitions.contains(where: { $0.id == selectedPartitionID && $0.isAvailable && previousPartition.map($0.matches) != false }) {
                    self.selectedPartitionID = nil; self.showConfirmation = false
                }
            case .failure(let error):
                scanHasSucceeded = false
                devices = []; partitions = []; selectedID = nil; selectedPartitionID = nil; showConfirmation = false
                if !silent { notice = "Не вдалося оновити диски: " + error.localizedDescription }
            }
        }
    }

    func prepareConfirmation() {
        guard ready else { return }
        confirmationText = ""; acknowledged = false; rawPartitionAcknowledged = false; showConfirmation = true
    }

    func startWrite() {
        guard ready, let image, let device = selectedDevice,
              acknowledged, confirmationText == targetID,
              !needsRawPartitionAcknowledgment || rawPartitionAcknowledged else { return }
        showConfirmation = false
        notice = nil; busy = true; cancellationRequested = false
        operationStarted = Date()
        status = JobStatus(phase: .waiting, message: "Підтвердьте дозвіл на запис у системному вікні macOS.")
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Створення завантажувального USB")
        do {
            let jobs = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ISO Forge/Jobs")
            try fm.createDirectory(at: jobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let session = jobs.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.session = session
            guard let imageURL, imageURL.startAccessingSecurityScopedResource() else {
                throw ForgeError.message("Немає дозволу читати вибраний ISO. Оберіть файл ще раз із вікна програми.")
            }
            defer { imageURL.stopAccessingSecurityScopedResource() }
            let stagedImage = session.appendingPathComponent("source-image.iso")
            do {
                try fm.copyItem(at: imageURL, to: stagedImage)
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedImage.path)
            } catch {
                throw ForgeError.message("Не вдалося підготувати ISO для запису: \(error.localizedDescription)")
            }
            let stagedIdentity = try FileSafety.identity(stagedImage.path)
            guard stagedIdentity.size == image.identity.size else {
                throw ForgeError.message("Розмір копії ISO не збігається з оригіналом. Перевірте вільне місце та оберіть файл ще раз.")
            }
            let stagedHash = try ByteIO.hashFile(stagedImage.path)
            let sourceHash = try ByteIO.hashFile(imageURL.path)
            guard stagedHash == sourceHash else { throw ForgeError.message("Вміст копії ISO не збігається з оригіналом. Оберіть файл ще раз.") }
            let stagedInfo = try ImageInspector.inspect(stagedImage, scope: scope)
            guard stagedInfo.mode == image.mode, stagedInfo.requiredCapacity == image.requiredCapacity else {
                throw ForgeError.message("Перевірка копії ISO не збіглася з оригіналом. Оберіть файл ще раз.")
            }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ForgeWriter")
            let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wimlib-imagex")
            guard fm.isExecutableFile(atPath: helper.path), fm.isExecutableFile(atPath: tool.path) else {
                throw ForgeError.message("Допоміжні компоненти відсутні. Запустіть встановлену програму з /Applications.")
            }
            let request = WriteRequest(image: stagedInfo, device: device, eject: scope == .disk && ejectAfterWrite, ownerUID: getuid(),
                                       sessionPath: session.path, appPath: Bundle.main.bundleURL.path, wimToolPath: tool.path,
                                       partition: scope == .partition ? selectedPartition : nil,
                                       formatOnly: image.mode == .windows)
            let requestURL = session.appendingPathComponent("request.json")
            try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
            let command = Formatters.shellQuote(helper.path) + " --request " + Formatters.shellQuote(requestURL.path)
            let script = "do shell script " + Formatters.appleScriptQuote(command) + " with administrator privileges"
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollStatus() }
            }
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try CommandRunner.run("/usr/bin/osascript", ["-e", script]) }
                }.value
                pollStatus()
                switch result {
                case .success(let commandResult):
                    if commandResult.code != 0 && status?.phase.isTerminal != true {
                        let text = commandResult.text
                        let denied = text.contains("(-128)") || text.lowercased().contains("user canceled")
                        status = JobStatus(phase: denied ? .cancelled : .failed,
                                           message: denied ? "Дозвіл macOS скасовано. USB не змінено." : text.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else if commandResult.code == 0 && request.formatOnly {
                        // The privileged phase owns its log files; the GUI phase creates user-owned ones.
                        try? fm.removeItem(at: session.appendingPathComponent("operation.log"))
                        try? Data().write(to: session.appendingPathComponent("operation.log"), options: .atomic)
                        let copyResult = await Task.detached(priority: .userInitiated) {
                            Result { try populateWindowsFiles(request) }
                        }.value
                        if case .failure(let error) = copyResult {
                            let cancelled = (error as? ForgeError) == .cancelled
                            JobReporter(session: session).update(JobStatus(phase: cancelled ? .cancelled : .failed,
                                                                          message: error.localizedDescription))
                        }
                    } else if commandResult.code == 0 && status?.phase != .complete {
                        status = JobStatus(phase: .failed, message: "Компонент запису завершився без підтвердження перевірки. Перевірте журнал операції.")
                    }
                case .failure(let error):
                    status = JobStatus(phase: .failed, message: error.localizedDescription)
                }
                finishOperation()
            }
        } catch {
            status = JobStatus(phase: .failed, message: error.localizedDescription)
            finishOperation()
        }
    }

    func pollStatus() {
        guard let session, let data = try? Data(contentsOf: session.appendingPathComponent("status.json")),
              let current = try? JSONDecoder().decode(JobStatus.self, from: data) else { return }
        status = current
    }

    func cancelWrite() {
        guard busy, !cancellationRequested, let session else { return }
        do {
            try Data().write(to: session.appendingPathComponent("cancel"), options: .atomic)
            cancellationRequested = true
        } catch { notice = "Не вдалося передати команду зупинки: " + error.localizedDescription }
    }

    private func finishOperation() {
        timer?.invalidate(); timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        busy = false; cancellationRequested = false
        refreshDisks(silent: true)
    }

    func exportLog() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ISO-Forge-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-" )).txt"
        panel.allowedContentTypes = [.plainText]
        panel.title = "Зберегти журнал операції"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                var text = "ISO Forge 1.2.2\n"
                if let image { text += "Образ: \(image.path)\nРежим: \(image.mode.title)\n" }
                text += (try? String(contentsOf: session.appendingPathComponent("operation.log"), encoding: .utf8)) ?? ""
                if let status { text += "\nРезультат: \(status.phase.title)\n\(status.message)\n" }
                if let checksum = status?.checksum { text += "SHA-256: \(checksum)\n" }
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch { notice = error.localizedDescription }
        }
    }
}
