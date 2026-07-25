import Foundation

public struct MTPLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let level: Level
    public let message: String

    public enum Level: String, Sendable { case debug, info, warn, error }
}

/// Buffer circular de diagnóstico. A janela "Diagnóstico" lê daqui — é o que
/// permite entender o que aconteceu quando um aparelho específico se comporta mal.
public final class MTPLog: @unchecked Sendable {
    public static let shared = MTPLog()

    private let lock = NSLock()
    private var entries: [MTPLogEntry] = []
    private let limit = 800

    /// Chamado a cada nova linha (em qualquer thread).
    public var onEntry: (@Sendable (MTPLogEntry) -> Void)?

    public var verbose = false

    public func log(_ level: MTPLogEntry.Level, _ message: @autoclosure () -> String) {
        if level == .debug && !verbose { return }
        let entry = MTPLogEntry(date: Date(), level: level, message: message())
        lock.lock()
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()
        onEntry?(entry)
    }

    public func debug(_ m: @autoclosure () -> String) { log(.debug, m()) }
    public func info(_ m: @autoclosure () -> String)  { log(.info, m()) }
    public func warn(_ m: @autoclosure () -> String)  { log(.warn, m()) }
    public func error(_ m: @autoclosure () -> String) { log(.error, m()) }

    public func snapshot() -> [MTPLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    public func plainText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return snapshot()
            .map { "\(f.string(from: $0.date)) [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}

/// Sinalizador de cancelamento compartilhado entre a UI e a fila USB.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func cancel() {
        lock.lock(); value = true; lock.unlock()
    }
}
