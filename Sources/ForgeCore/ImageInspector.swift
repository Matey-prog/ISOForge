import Foundation

public final class MountedImage {
    public let root: URL
    private let device: String
    private var attached = true

    public init(path: String) throws {
        let mountRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ISOForge-mount-" + UUID().uuidString)
        root = mountRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let plist = try CommandRunner.plist("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", root.path, "-plist", path])
            let entities = plist["system-entities"] as? [[String: Any]] ?? []
            guard let whole = entities.compactMap({ $0["dev-entry"] as? String }).first,
                  entities.contains(where: {
                      guard let path = $0["mount-point"] as? String else { return false }
                      return URL(fileURLWithPath: path).standardizedFileURL.path == mountRoot.standardizedFileURL.path
                  }) else {
                if let first = entities.compactMap({ $0["dev-entry"] as? String }).first {
                    _ = try? CommandRunner.run("/usr/bin/hdiutil", ["detach", first])
                }
                throw ForgeError.message("Не вдалося прочитати файлову систему ISO.")
            }
            device = whole
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    public func detach() {
        guard attached else { return }
        if let result = try? CommandRunner.run("/usr/bin/hdiutil", ["detach", device]), result.code == 0 {
            attached = false
            try? FileManager.default.removeItem(at: root)
        }
    }
    deinit { detach() }
}

public struct ImageSignatures: Equatable {
    public let iso: Bool
    public let hybrid: Bool
    public let opticalBoot: Bool
}

public struct WindowsFile: Sendable {
    public let relative: String
    public let size: UInt64
    public var needsSplit: Bool { size > WindowsLayout.fat32Limit }
}

public struct WindowsLayout: Sendable {
    public static let fat32Limit: UInt64 = 4_294_967_295
    public let files: [WindowsFile]
    public let directories: [String]
    public let architectures: [String]
    public var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }
    public var splitFiles: [WindowsFile] { files.filter(\.needsSplit) }
    public var requiredCapacity: UInt64 { totalSize + max(268_435_456, totalSize / 10) }

    public static func read(root: URL) throws -> WindowsLayout {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absolutePrefix = "/" + prefix + "/"
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else {
            throw ForgeError.message("Не вдалося прочитати вміст ISO.")
        }
        var files: [WindowsFile] = [], directories: [String] = [], seen: Set<String> = []
        for case let url as URL in iterator {
            let name = url.lastPathComponent
            if name.hasPrefix("._") || [".DS_Store", ".Trashes", ".Spotlight-V100", ".fseventsd"].contains(name) {
                iterator.skipDescendants(); continue
            }
            let entryPath = url.standardizedFileURL.path
            guard entryPath.hasPrefix(absolutePrefix) else { throw ForgeError.message("Шлях виходить за межі ISO.") }
            let relative = String(entryPath.dropFirst(absolutePrefix.count))
            guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                throw ForgeError.message("ISO містить некоректний шлях.")
            }
            guard seen.insert(relative.lowercased()).inserted else {
                throw ForgeError.message("ISO містить імена, що відрізняються лише регістром і несумісні з FAT32: \(relative).")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ForgeError.message("ISO містить символічні посилання; такий образ Windows не підтримується.") }
            if values.isDirectory == true { directories.append(relative) }
            else if values.isRegularFile == true { files.append(WindowsFile(relative: relative, size: UInt64(values.fileSize ?? 0))) }
        }
        let names = Set(files.map { $0.relative.lowercased() })
        guard names.contains("sources/boot.wim") else { throw ForgeError.message("В ISO немає sources/boot.wim — це не стандартний інсталяційний образ Windows.") }
        let arches = [("efi/boot/bootx64.efi", "x64"), ("efi/boot/bootaa64.efi", "ARM64"), ("efi/boot/bootia32.efi", "x86")]
            .filter { names.contains($0.0) }.map(\.1)
        guard !arches.isEmpty else { throw ForgeError.message("В образі Windows немає завантажувача EFI/BOOT. Для цієї програми потрібен ISO з підтримкою UEFI.") }
        for file in files where file.needsSplit {
            let path = file.relative.lowercased()
            guard path.hasSuffix(".wim") || path == "sources/install.esd" else {
                throw ForgeError.message("Файл \(file.relative) більший за ліміт FAT32 (4 ГБ). Автоматично поділити можна для будь-якого .wim та sources/install.esd.")
            }
            let directory = (file.relative as NSString).deletingLastPathComponent
            let stem = URL(fileURLWithPath: file.relative).deletingPathExtension().lastPathComponent.lowercased()
            let prefix = directory == "." ? "" : directory.lowercased() + "/"
            let hasExistingParts = files.contains { candidate in
                let candidatePath = candidate.relative.lowercased()
                guard candidatePath.hasPrefix(prefix), candidatePath.hasSuffix(".swm") else { return false }
                let candidateName = (candidate.relative as NSString).lastPathComponent.lowercased()
                guard candidateName.hasPrefix(stem), candidateName.hasSuffix(".swm") else { return false }
                let suffix = candidateName.dropFirst(stem.count).dropLast(4)
                return suffix.isEmpty || suffix.allSatisfy(\.isNumber)
            }
            if hasExistingParts {
                throw ForgeError.message("Образ містить одночасно великий \(file.relative) та готові частини \(stem)*.swm у цій папці. Приберіть одну з версій, щоб уникнути змішування наборів.")
            }
        }
        return WindowsLayout(files: files.sorted { $0.relative < $1.relative }, directories: directories.sorted(), architectures: arches)
    }
}

public enum ImageInspector {
    public static func signatures(_ data: Data) -> ImageSignatures {
        let bytes = [UInt8](data)
        let mbr = bytes.count >= 512 && bytes[510] == 0x55 && bytes[511] == 0xaa &&
            (0..<4).contains { bytes[446 + $0 * 16 + 4] != 0 && bytes[(446 + $0 * 16 + 12)..<(446 + $0 * 16 + 16)].contains(where: { $0 != 0 }) }
        let gpt = bytes.count >= 520 && String(decoding: bytes[512..<520], as: UTF8.self) == "EFI PART"
        var iso = false, optical = false
        if bytes.count > 32774 {
            for offset in stride(from: 32768, to: min(bytes.count - 80, 131072), by: 2048) {
                let marker = String(decoding: bytes[(offset + 1)..<(offset + 6)], as: UTF8.self)
                if ["CD001", "NSR02", "NSR03", "BEA01"].contains(marker) { iso = true }
                if marker == "CD001", bytes[offset] == 0 {
                    optical = String(decoding: bytes[(offset + 7)..<(offset + 39)], as: UTF8.self).hasPrefix("EL TORITO SPECIFICATION")
                }
            }
        }
        return ImageSignatures(iso: iso, hybrid: mbr || gpt, opticalBoot: optical)
    }

    public static func inspect(_ url: URL, scope: TargetScope = .disk) throws -> ImageInfo {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        guard ["iso", "img"].contains(ext) else { throw ForgeError.message("Підтримуються файли .iso та .img.") }
        let identity = try FileSafety.identity(path)
        guard identity.size >= 32768 else { throw ForgeError.message("Файл надто малий для завантажувального образу.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let signatures = signatures(try handle.read(upToCount: 131072) ?? Data())
        if ext == "iso" {
            guard signatures.iso else { throw ForgeError.message("У файлі немає сигнатури ISO/UDF. Перевірте, чи образ завантажено повністю.") }
            do {
                let mounted = try MountedImage(path: path)
                defer { mounted.detach() }
                if findCaseInsensitive(root: mounted.root, components: ["sources", "boot.wim"]) != nil {
                    let layout = try WindowsLayout.read(root: mounted.root)
                    return ImageInfo(path: path, identity: identity, mode: .windows, isHybrid: signatures.hybrid,
                                     hasOpticalBoot: signatures.opticalBoot, requiredCapacity: layout.requiredCapacity,
                                     bootArchitectures: layout.architectures, largeWindowsFiles: layout.splitFiles.count)
                }
            } catch {
                // A malformed Windows image must never fall back to raw flashing.
                if !signatures.hybrid { throw error }
                if case ForgeError.message(let text) = error,
                   !text.hasPrefix("hdiutil:") && !text.hasPrefix("Не вдалося прочитати файлову систему") { throw error }
            }
            guard signatures.hybrid || scope == .partition else {
                throw ForgeError.message("Цей ISO призначений для CD/DVD і не має таблиці розділів для завантаження з USB. Оберіть гібридний ISO Linux або інсталяційний ISO Windows UEFI.")
            }
        } else {
            guard signatures.hybrid else { throw ForgeError.message("IMG не містить MBR або GPT. Оберіть повний образ завантажувального диска.") }
        }
        return ImageInfo(path: path, identity: identity, mode: .raw, isHybrid: signatures.hybrid,
                         hasOpticalBoot: signatures.opticalBoot, requiredCapacity: identity.size,
                         bootArchitectures: [], largeWindowsFiles: 0)
    }

    public static func findCaseInsensitive(root: URL, components: [String]) -> URL? {
        var current = root
        for name in components {
            guard let children = try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil),
                  let match = children.first(where: { $0.lastPathComponent.lowercased() == name.lowercased() }) else { return nil }
            current = match
        }
        return current
    }
}
