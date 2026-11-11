import Foundation

public enum ForgeError: LocalizedError, Equatable {
    case message(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "Запис зупинено. Накопичувач може містити неповний образ — запишіть його знову перед використанням."
        }
    }
}

public enum WriteMode: String, Codable, CaseIterable, Sendable {
    case raw, windows
    public var title: String { self == .raw ? "Прямий запис образу" : "Windows · UEFI" }
    public var detail: String {
        self == .raw ? "Побайтовий запис гібридних ISO та IMG, з перевіркою SHA-256."
            : "FAT32 для UEFI. Будь-який великий .wim та sources/install.esd поділяються на частини SWM."
    }
}

public enum TargetScope: String, Codable, CaseIterable, Sendable {
    case disk, partition
    public var title: String { self == .disk ? "Увесь USB" : "Окремий розділ" }
}

public struct FileIdentity: Codable, Equatable, Sendable {
    public let size: UInt64
    public let device: UInt64
    public let inode: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
}

public struct ImageInfo: Codable, Sendable {
    public let path: String
    public let identity: FileIdentity
    public let mode: WriteMode
    public let isHybrid: Bool
    public let hasOpticalBoot: Bool
    public let requiredCapacity: UInt64
    public let bootArchitectures: [String]
    public let largeWindowsFiles: Int
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var size: UInt64 { identity.size }
}

public struct USBDevice: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let size: UInt64
    public let fingerprint: String
    public var volumes: [String]
    public var blockedReason: String?
    public var isAvailable: Bool { blockedReason == nil }
    public var devicePath: String { "/dev/" + id }
    public var rawPath: String { "/dev/r" + id }
}

public struct DiskPartition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let parentID: String
    public let parentFingerprint: String
    public let name: String
    public let size: UInt64
    public let offset: UInt64
    public let uuid: String
    public let content: String
    public let filesystem: String
    public var blockedReason: String?
    public var isAvailable: Bool { blockedReason == nil }
    public var devicePath: String { "/dev/" + id }
    public var rawPath: String { "/dev/r" + id }

    // Volume UUIDs change on formatting; physical geometry and GPT identity must not.
    public func matches(_ other: DiskPartition) -> Bool {
        id == other.id && parentID == other.parentID && parentFingerprint == other.parentFingerprint &&
            size == other.size && offset == other.offset && uuid == other.uuid && content == other.content
    }
}

public enum JobPhase: String, Codable, Sendable {
    case waiting, preparing, formatting, writing, splitting, verifying, ejecting, complete, failed, cancelled
    public var title: String {
        switch self {
        case .waiting: return "Очікування дозволу macOS"
        case .preparing: return "Підготовка"
        case .formatting: return "Форматування"
        case .writing: return "Запис образу"
        case .splitting: return "Підготовка файлів Windows"
        case .verifying: return "Перевірка запису"
        case .ejecting: return "Безпечне вилучення"
        case .complete: return "Накопичувач готовий"
        case .failed: return "Не вдалося завершити"
        case .cancelled: return "Запис зупинено"
        }
    }
    public var isTerminal: Bool { [.complete, .failed, .cancelled].contains(self) }
}

public struct JobStatus: Codable, Sendable {
    public var phase: JobPhase
    public var fraction: Double
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var bytesPerSecond: Double
    public var message: String
    public var checksum: String?
    public var updated: Date

    public init(phase: JobPhase, fraction: Double = 0, bytesDone: UInt64 = 0,
                bytesTotal: UInt64 = 0, bytesPerSecond: Double = 0, message: String, checksum: String? = nil) {
        self.phase = phase; self.fraction = fraction; self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal; self.bytesPerSecond = bytesPerSecond
        self.message = message; self.checksum = checksum; self.updated = Date()
    }
}

public struct WriteRequest: Codable, Sendable {
    public let image: ImageInfo
    public let device: USBDevice
    public let eject: Bool
    public let ownerUID: UInt32
    public let sessionPath: String
    public let appPath: String
    public let wimToolPath: String
    public let partition: DiskPartition?
    public let formatOnly: Bool
    public var scope: TargetScope { partition == nil ? .disk : .partition }
    public var targetID: String { partition?.id ?? device.id }
    public var targetPath: String { partition?.devicePath ?? device.devicePath }
    public var rawTargetPath: String { partition?.rawPath ?? device.rawPath }

    public init(image: ImageInfo, device: USBDevice, eject: Bool, ownerUID: UInt32,
                sessionPath: String, appPath: String, wimToolPath: String, partition: DiskPartition? = nil,
                formatOnly: Bool = false) {
        self.image = image; self.device = device; self.eject = eject; self.ownerUID = ownerUID
        self.sessionPath = sessionPath; self.appPath = appPath; self.wimToolPath = wimToolPath
        self.partition = partition; self.formatOnly = formatOnly
    }
}

public enum Formatters {
    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    public static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public static func appleScriptQuote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
