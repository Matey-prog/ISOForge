import Foundation
import CryptoKit

public enum WindowsInstaller {
    public typealias Status = (JobStatus) -> Void

    // The destination is a freshly formatted FAT32 volume in production;
    // tests use private temporary directories or a disposable mounted disk image.
    public static func populate(source: URL, destination: URL, layout: WindowsLayout,
                                wimTool: String, workDirectory: URL,
                                cancellation: () -> Bool, status: Status) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { throw ForgeError.message("USB-том не змонтовано.") }
        let contents = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        guard contents.allSatisfy({ $0.lastPathComponent.hasPrefix(".") }) else {
            throw ForgeError.message("Цільовий том не порожній. Запис зупинено.")
        }
        for directory in layout.directories {
            if cancellation() { throw ForgeError.cancelled }
            try fm.createDirectory(at: destination.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        var manifest: [(path: String, size: UInt64, hash: String)] = []
        var done: UInt64 = 0
        let regularFiles = layout.files.filter { !$0.needsSplit }
        let regularSize = regularFiles.reduce(UInt64(0)) { $0 + $1.size }
        for file in regularFiles {
            if cancellation() { throw ForgeError.cancelled }
            let base = done
            let hash = try ByteIO.copyFile(from: source.appendingPathComponent(file.relative),
                                          to: destination.appendingPathComponent(file.relative), size: file.size,
                                          cancellation: cancellation) { bytes, _, speed in
                let fraction = Double(base + bytes) / Double(max(regularSize, 1))
                status(JobStatus(phase: .writing, fraction: 0.08 + fraction * 0.47,
                                 bytesDone: base + bytes, bytesTotal: regularSize, bytesPerSecond: speed,
                                 message: file.relative))
            }
            done += file.size
            manifest.append((file.relative, file.size, hash))
        }

        for file in layout.splitFiles {
            if cancellation() { throw ForgeError.cancelled }
            let original = source.appendingPathComponent(file.relative)
            let relativeDirectory = (file.relative as NSString).deletingLastPathComponent
            let outputDirectory = workDirectory.appendingPathComponent("split-" + UUID().uuidString)
            try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: outputDirectory) }
            var wimSource = original
            let outputStem = original.deletingPathExtension().lastPathComponent
            let outputBase = outputStem + ".swm"
            status(JobStatus(phase: .splitting, fraction: 0.55, message: "Поділ \(file.relative) на частини до 3 800 МБ…"))
            if original.pathExtension.lowercased() == "esd" {
                wimSource = outputDirectory.appendingPathComponent("converted.wim")
                _ = try CommandRunner.checked(wimTool, ["export", original.path, "all", wimSource.path, "--compress=LZX"],
                                              cancellation: cancellation,
                                              heartbeat: { status(JobStatus(phase: .splitting, fraction: 0.55, message: "Перетворення великого install.esd у WIM…")) })
            }
            _ = try CommandRunner.checked(wimTool, ["split", wimSource.path, outputDirectory.appendingPathComponent(outputBase).path, "3800", "--check"],
                                          cancellation: cancellation,
                                          heartbeat: { status(JobStatus(phase: .splitting, fraction: 0.57, message: "Створення частин \(outputStem)*.swm…")) })
            let parts = try fm.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "swm" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !parts.isEmpty else { throw ForgeError.message("wimlib не створив файли SWM.") }
            for part in parts {
                let identity = try FileSafety.identity(part.path)
                guard identity.size <= WindowsLayout.fat32Limit else {
                    throw ForgeError.message("Одна з частин WIM перевищила 4 ГБ. Цей образ не можна розмістити на FAT32.")
                }
                let relative = relativeDirectory + "/" + part.lastPathComponent
                let hash = try ByteIO.copyFile(from: part, to: destination.appendingPathComponent(relative), size: identity.size,
                                              cancellation: cancellation) { bytes, total, speed in
                    status(JobStatus(phase: .writing, fraction: 0.58 + Double(bytes) / Double(total) * 0.07,
                                     bytesDone: bytes, bytesTotal: total, bytesPerSecond: speed, message: relative))
                }
                manifest.append((relative, identity.size, hash))
            }
            let first = destination.appendingPathComponent(relativeDirectory + "/" + outputBase)
            _ = try CommandRunner.checked(wimTool, ["verify", first.path, "--ref=" + destination.appendingPathComponent(relativeDirectory + "/" + outputStem + "*.swm").path],
                                          cancellation: cancellation,
                                          heartbeat: { status(JobStatus(phase: .verifying, fraction: 0.65, message: "Перевірка цілісності частин WIM…")) })
        }

        let total = manifest.reduce(UInt64(0)) { $0 + $1.size }
        var verified: UInt64 = 0
        for file in manifest {
            if cancellation() { throw ForgeError.cancelled }
            let base = verified
            let actual = try ByteIO.hashFile(destination.appendingPathComponent(file.path).path, cancellation: cancellation) { bytes, _, speed in
                status(JobStatus(phase: .verifying, fraction: 0.66 + Double(base + bytes) / Double(max(total, 1)) * 0.30,
                                 bytesDone: base + bytes, bytesTotal: total, bytesPerSecond: speed, message: file.path))
            }
            guard actual == file.hash else { throw ForgeError.message("Перевірка SHA-256 не пройшла для \(file.path). Спробуйте інший USB-накопичувач.") }
            verified += file.size
        }
        status(JobStatus(phase: .verifying, fraction: 0.96, bytesDone: total, bytesTotal: total,
                         message: "Перевірено SHA-256 усіх \(manifest.count) записаних файлів."))
    }

}
