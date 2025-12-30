import Foundation
import Security

/// Sandbox-compliant API key storage using macOS Keychain
class KeychainService {
    static let shared = KeychainService()

    private let serviceName = "com.dynamicai.app"

    private init() {}

    // MARK: - API Keys

    enum APIKeyType: String {
        case anthropic = "anthropic_api_key"
        case openWeather = "openweather_api_key"
        case tmdb = "tmdb_api_key"
        case groq = "groq_api_key"
    }

    func saveAPIKey(_ key: String, for type: APIKeyType) -> Bool {
        // Delete existing key first
        deleteAPIKey(for: type)

        let keyData = key.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: type.rawValue,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func getAPIKey(for type: APIKeyType) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: type.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    func deleteAPIKey(for type: APIKeyType) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: type.rawValue
        ]

        SecItemDelete(query as CFDictionary)
    }

    func hasAPIKey(for type: APIKeyType) -> Bool {
        return getAPIKey(for: type) != nil
    }

    // MARK: - Migration Helper

    /// Migrate API keys from legacy file-based storage to Keychain
    /// Call this once on first launch after update
    func migrateFromLegacyStorage() {
        // Try to read from legacy locations
        let legacyPaths = [
            NSHomeDirectory() + "/.interview-master-keys",
            NSHomeDirectory() + "/.dynamicai-keys"
        ]

        for path in legacyPaths {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }

            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("ANTHROPIC_API_KEY=") {
                    let key = String(trimmed.dropFirst("ANTHROPIC_API_KEY=".count))
                    if !key.isEmpty && !hasAPIKey(for: .anthropic) {
                        _ = saveAPIKey(key, for: .anthropic)
                    }
                }

                if trimmed.hasPrefix("OPENWEATHER_API_KEY=") {
                    let key = String(trimmed.dropFirst("OPENWEATHER_API_KEY=".count))
                    if !key.isEmpty && !hasAPIKey(for: .openWeather) {
                        _ = saveAPIKey(key, for: .openWeather)
                    }
                }

                if trimmed.hasPrefix("TMDB_API_KEY=") {
                    let key = String(trimmed.dropFirst("TMDB_API_KEY=".count))
                    if !key.isEmpty && !hasAPIKey(for: .tmdb) {
                        _ = saveAPIKey(key, for: .tmdb)
                    }
                }
            }
        }
    }
}

// MARK: - User Defaults for Non-Sensitive Settings

extension UserDefaults {
    private enum Keys {
        static let dailyQueryCount = "dailyQueryCount"
        static let lastQueryDate = "lastQueryDate"
        static let isPro = "isPro"
        static let hasByok = "hasByok" // Bring Your Own Key purchased
    }

    var dailyQueryCount: Int {
        get { integer(forKey: Keys.dailyQueryCount) }
        set { set(newValue, forKey: Keys.dailyQueryCount) }
    }

    var lastQueryDate: Date? {
        get { object(forKey: Keys.lastQueryDate) as? Date }
        set { set(newValue, forKey: Keys.lastQueryDate) }
    }

    var isPro: Bool {
        get { bool(forKey: Keys.isPro) }
        set { set(newValue, forKey: Keys.isPro) }
    }

    var hasByok: Bool {
        get { bool(forKey: Keys.hasByok) }
        set { set(newValue, forKey: Keys.hasByok) }
    }

    /// Reset daily count if it's a new day
    func resetDailyCountIfNeeded() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if let lastDate = lastQueryDate {
            let lastDay = calendar.startOfDay(for: lastDate)
            if today > lastDay {
                dailyQueryCount = 0
                lastQueryDate = today
            }
        } else {
            lastQueryDate = today
            dailyQueryCount = 0
        }
    }
}
