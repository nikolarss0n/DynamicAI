import Foundation

// MARK: - Logger
/// Thread-safe, single-line logging with consistent formatting

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case success = 2
    case warning = 3
    case error = 4

    var symbol: String {
        switch self {
        case .debug: return "·"
        case .info: return "→"
        case .success: return "✓"
        case .warning: return "⚠"
        case .error: return "✗"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum LogCategory: String {
    case embedding = "Embed"
    case vector = "Vector"
    case vision = "Vision"
    case index = "Index"
    case search = "Search"
    case photos = "Photos"
    case video = "Video"
    case app = "App"

    var icon: String {
        switch self {
        case .embedding: return "🔵"
        case .vector: return "🟣"
        case .vision: return "🟢"
        case .index: return "🟡"
        case .search: return "🔍"
        case .photos: return "📷"
        case .video: return "🎬"
        case .app: return "📱"
        }
    }
}

final class Logger: @unchecked Sendable {
    static let shared = Logger()

    // MARK: - Configuration

    var minimumLevel: LogLevel = .debug
    var enabledCategories: Set<LogCategory>? = nil  // nil = all enabled

    // MARK: - Thread Safety

    private let lock = NSLock()

    // MARK: - Formatters

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    // MARK: - Core Logging (Thread-Safe)

    private func output(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        print(message)
    }

    func log(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: String,
        details: [String: Any]? = nil
    ) {
        guard level >= minimumLevel else { return }

        if let enabled = enabledCategories, !enabled.contains(category) {
            return
        }

        let timestamp = timeFormatter.string(from: Date())
        let cat = "\(category.icon)\(category.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))"

        // Build single line
        var line = "\(timestamp) \(cat) \(level.symbol) \(message)"

        // Append details inline
        if let details = details, !details.isEmpty {
            let detailStr = details.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            line += " [\(detailStr)]"
        }

        output(line)
    }

    // MARK: - Convenience Methods

    func debug(_ category: LogCategory, _ message: String, details: [String: Any]? = nil) {
        log(.debug, category, message, details: details)
    }

    func info(_ category: LogCategory, _ message: String, details: [String: Any]? = nil) {
        log(.info, category, message, details: details)
    }

    func success(_ category: LogCategory, _ message: String, details: [String: Any]? = nil) {
        log(.success, category, message, details: details)
    }

    func warning(_ category: LogCategory, _ message: String, details: [String: Any]? = nil) {
        log(.warning, category, message, details: details)
    }

    func error(_ category: LogCategory, _ message: String, details: [String: Any]? = nil) {
        log(.error, category, message, details: details)
    }

    // MARK: - Section Headers

    func section(_ title: String) {
        output("\n━━━ \(title) ━━━")
    }

    // MARK: - Progress

    func progress(_ category: LogCategory, current: Int, total: Int, item: String) {
        let percent = total > 0 ? Int((Double(current) / Double(total)) * 100) : 0
        let filled = percent / 5  // 20 chars = 100%
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
        log(.info, category, "[\(bar)] \(current)/\(total) \(item)")
    }

    // MARK: - Timing

    func timed<T>(_ category: LogCategory, _ operation: String, block: () async throws -> T) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await block()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        log(.success, category, "\(operation)", details: ["time": String(format: "%.2fs", elapsed)])
        return result
    }
}

// MARK: - Global Shorthand

let log = Logger.shared
