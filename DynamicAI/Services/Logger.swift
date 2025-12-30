import Foundation

/// Thread-safe logger to prevent interleaved console output
final class Log {
    static let shared = Log()
    private let queue = DispatchQueue(label: "com.dynamicai.logger")

    private init() {}

    func print(_ subsystem: String, _ message: String) {
        queue.sync {
            Swift.print("[\(subsystem)] \(message)")
        }
    }
}

// Convenience functions
func log(_ subsystem: String, _ message: String) {
    Log.shared.print(subsystem, message)
}
