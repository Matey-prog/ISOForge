import Foundation
import Darwin

public final class JobReporter {
    public let session: URL
    private var lastUpdate: TimeInterval = 0
    private var lastPhase: JobPhase?

    public init(session: URL) { self.session = session }
    public var isCancelled: Bool { FileManager.default.fileExists(atPath: session.appendingPathComponent("cancel").path) }
    public func checkCancellation() throws { if isCancelled { throw ForgeError.cancelled } }

    public func update(_ status: JobStatus) {
        let now = ProcessInfo.processInfo.systemUptime
        guard status.phase != lastPhase || status.phase.isTerminal || now - lastUpdate >= 0.15 else { return }
        let phaseChanged = status.phase != lastPhase
        lastUpdate = now; lastPhase = status.phase
        if let data = try? JSONEncoder().encode(status) {
            try? data.write(to: session.appendingPathComponent("status.json"), options: .atomic)
        }
        if phaseChanged || status.phase.isTerminal {
            append("\(status.phase.title): \(status.message)")
        }
    }
    public func append(_ text: String) {
        let path = session.appendingPathComponent("operation.log").path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(text)\n"
        line.withCString { _ = write(fd, $0, strlen($0)) }
    }
}
