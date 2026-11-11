import Foundation
import CryptoKit
import Darwin

public enum ByteIO {
    public static let chunkSize = 4 * 1024 * 1024
    public typealias Progress = (UInt64, UInt64, Double) -> Void

    public static func openRead(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError("Не вдалося відкрити \(path)") }
        return fd
    }
    public static func systemError(_ message: String) -> ForgeError {
        ForgeError.message(message + ": " + String(cString: strerror(errno)))
    }
    private static func readChunk(_ fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        while true {
            let readCount = Darwin.read(fd, buffer, count)
            if readCount < 0 && errno == EINTR { continue }
            if readCount < 0 { throw systemError("Помилка читання") }
            return readCount
        }
    }
    private static func writeAll(_ fd: Int32, from buffer: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, buffer.advanced(by: offset), count - offset)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw systemError("Помилка запису на накопичувач") }
            offset += written
        }
    }
    private static func digest(_ value: SHA256.Digest) -> String { value.map { String(format: "%02x", $0) }.joined() }

    // Descriptor-based API is shared by raw devices and safe temporary-file tests.
    @discardableResult
    public static func copy(sourceFD: Int32, destinationFD: Int32, size: UInt64,
                            alignTo block: Int = 1, cancellation: () -> Bool,
                            progress: Progress) throws -> String {
        guard block > 0, block <= chunkSize, chunkSize % block == 0 else { throw ForgeError.message("Некоректний розмір сектора USB.") }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize + block, alignment: max(block, 4096))
        defer { buffer.deallocate() }
        var hasher = SHA256(), done: UInt64 = 0
        let clockStart = ProcessInfo.processInfo.systemUptime
        while done < size {
            if cancellation() { throw ForgeError.cancelled }
            let wanted = min(chunkSize, Int(min(UInt64(chunkSize), size - done)))
            // Regular files may return short reads; fill the block before raw writes.
            var readTotal = 0
            while readTotal < wanted {
                let n = try readChunk(sourceFD, into: buffer.advanced(by: readTotal), count: wanted - readTotal)
                guard n > 0 else { throw ForgeError.message("Образ закінчився раніше очікуваного. Файл пошкоджено або змінено.") }
                readTotal += n
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: readTotal))
            let padded = ((readTotal + block - 1) / block) * block
            if padded > readTotal { buffer.advanced(by: readTotal).initializeMemory(as: UInt8.self, repeating: 0, count: padded - readTotal) }
            try writeAll(destinationFD, from: buffer, count: padded)
            done += UInt64(readTotal)
            let seconds = max(ProcessInfo.processInfo.systemUptime - clockStart, 0.01)
            progress(done, size, Double(done) / seconds)
        }
        guard fsync(destinationFD) == 0 else { throw systemError("Не вдалося зберегти дані на накопичувачі") }
        return digest(hasher.finalize())
    }

    public static func hash(fd: Int32, size: UInt64, alignTo block: Int = 1,
                            cancellation: () -> Bool, progress: Progress) throws -> String {
        guard block > 0, block <= chunkSize, chunkSize % block == 0 else { throw ForgeError.message("Некоректний розмір сектора USB.") }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize + max(block, 1), alignment: 4096)
        defer { buffer.deallocate() }
        var hasher = SHA256(), done: UInt64 = 0
        let start = ProcessInfo.processInfo.systemUptime
        while done < size {
            if cancellation() { throw ForgeError.cancelled }
            let wanted = Int(min(UInt64(chunkSize), size - done))
            let padded = ((wanted + block - 1) / block) * block
            let n = try readChunk(fd, into: buffer, count: padded)
            guard n >= wanted else { throw ForgeError.message("Накопичувач повернув неповні дані під час перевірки.") }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: wanted))
            done += UInt64(wanted)
            progress(done, size, Double(done) / max(ProcessInfo.processInfo.systemUptime - start, 0.01))
        }
        return digest(hasher.finalize())
    }

    public static func copyFile(from source: URL, to destination: URL, size: UInt64,
                                cancellation: () -> Bool, progress: Progress) throws -> String {
        let src = try openRead(source.path)
        defer { close(src) }
        let dst = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard dst >= 0 else { throw systemError("Не вдалося створити \(destination.lastPathComponent)") }
        defer { close(dst) }
        return try copy(sourceFD: src, destinationFD: dst, size: size, cancellation: cancellation, progress: progress)
    }

    public static func hashFile(_ path: String, cancellation: () -> Bool = { false }, progress: Progress = { _, _, _ in }) throws -> String {
        let fd = try openRead(path)
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ForgeError.message("Не вдалося перевірити файл.") }
        return try hash(fd: fd, size: UInt64(info.st_size), cancellation: cancellation, progress: progress)
    }

    public static func clearTrailingMetadata(fd: Int32, imageSize: UInt64, deviceSize: UInt64, block: Int) throws {
        let paddedImage = ((imageSize + UInt64(block) - 1) / UInt64(block)) * UInt64(block)
        guard deviceSize >= paddedImage else { throw ForgeError.message("На USB замало місця з урахуванням розміру сектора.") }
        let length = min(UInt64(1024 * 1024), deviceSize - paddedImage) / UInt64(block) * UInt64(block)
        guard length > 0 else { return }
        let offset = deviceSize - length
        guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { throw systemError("Не вдалося очистити стару резервну таблицю розділів") }
        let zero = Data(count: Int(length))
        try zero.withUnsafeBytes { pointer in
            try writeAll(fd, from: pointer.baseAddress!, count: pointer.count)
        }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw systemError("Не вдалося перейти до початку USB") }
    }
}
