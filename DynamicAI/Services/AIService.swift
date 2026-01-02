import Foundation
import Combine
import MapKit
import CoreLocation
import Photos
import AppKit

// MARK: - AI Provider Selection

enum AIProvider: String {
    case claude = "Claude (Anthropic)"
    case groq = "Llama (Groq)"
}

// MARK: - AI Service Configuration

struct AIConfig {
    // Toggle this to switch providers
    static var provider: AIProvider = .groq  // Changed to Groq for testing

    static let model = "claude-haiku-4-5-20251001"
    static let maxTokens = 500
    static let apiEndpoint = "https://api.anthropic.com/v1/messages"

    static let systemPrompt = """
    You are a helpful AI assistant in a macOS notch app. Be concise but helpful.

    Available tools:
    - smart_trip: USE THIS when user mentions going somewhere/traveling. Checks weather, battery, calendar automatically.
    - get_weather: Get weather for a location
    - get_battery: Check Mac and connected device batteries
    - system_info: Get CPU, memory, disk usage and uptime
    - control_music: Play/pause music, play playlists (e.g., "christmas music", "jazz")
    - calendar_query: Check user's calendar/schedule
    - reminders_query: View, create, or complete reminders
    - contacts_search: Look up contact info by name
    - launch_app: Open any app (e.g., "open Slack", "launch Safari")
    - set_timer: Set a timer with notification
    - clipboard: Read or write clipboard contents
    - dark_mode: Check or toggle dark mode
    - volume_control: Get/set volume or mute
    - search_movies: Search movies/films only
    - search_places: Search for restaurants, cafes, hotels, attractions
    - search_photos: Search photos/videos in user's library (e.g., "my 5 latest photos", "show me my photos", "find videos where I'm cooking")

    IMPORTANT - Smart suggestions:
    - When user says "I'm going to X" or "trip to X" → use smart_trip
    - When user asks about weather → use get_weather
    - When user wants music → use control_music
    - When user asks about battery → use get_battery
    - When user wants restaurants, cafes, hotels → use search_places
    - When user asks to open/launch an app → use launch_app
    - When user asks about contacts/phone/email → use contacts_search
    - When user wants a timer/alarm → use set_timer
    - When user asks about clipboard/copied → use clipboard
    - When user asks about dark mode/appearance → use dark_mode
    - When user asks about volume/sound → use volume_control
    - When user asks about CPU/memory/disk/system → use system_info
    - When user asks to find photos/videos/pictures → use search_photos
    - When user says "show me my photos", "latest photos", "my photos", "recent photos" → use search_photos with that exact query (no clarification needed)
    - When user says "index videos" or "index my videos" → use index_videos with action=start
    - When user asks about video index status → use index_videos with action=status
    - When user says "index photos" or "index my photos" → use index_photos with action=start
    - When user says "index my library" or "index media" → use both index_videos and index_photos with action=start

    Guidelines:
    - Answer general knowledge directly without tools
    - Keep responses concise (2-3 sentences)
    - Support any language

    You are a general assistant like Apple Intelligence - help with anything!
    """
}

// MARK: - Tool Definitions

enum AITool: String, CaseIterable {
    case contactsSearch = "contacts_search"
    case searchPhotos = "search_photos"
    case manageIndex = "manage_index"

    var definition: [String: Any] {
        switch self {
        case .contactsSearch:
            return [
                "name": rawValue,
                "description": "Search contacts by name to get phone numbers, emails, addresses",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Name to search for"]
                    ],
                    "required": ["query"]
                ]
            ]
        case .searchPhotos:
            return [
                "name": rawValue,
                "description": "Search photos and videos using natural language. Supports location ('photos from Greece'), time ('last summer'), visual content ('beach sunset'), and people ('photos with Sarah').",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Natural language search (e.g., 'beach photos from Greece last summer', 'videos of the wedding', 'sunset pictures')"]
                    ],
                    "required": ["query"]
                ]
            ]
        case .manageIndex:
            return [
                "name": rawValue,
                "description": "Manage photo/video search indexes. Build indexes for fast location and visual label search.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["start", "status", "clear"], "description": "start=build indexes, status=check index stats, clear=delete indexes"]
                    ],
                    "required": ["action"]
                ]
            ]
        }
    }
}

// MARK: - Tool Call Models

struct ToolCall: Codable {
    let id: String
    let name: String
    let input: [String: AnyCodable]
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let int = value as? Int {
            try container.encode(int)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        }
    }

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
}

// MARK: - Response Cache

actor ResponseCache {
    private var cache: [String: (data: Data, timestamp: Date)] = [:]
    private let ttl: TimeInterval = 300

    func get(_ key: String) -> Data? {
        guard let entry = cache[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > ttl {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.data
    }

    func set(_ key: String, data: Data) {
        cache[key] = (data, Date())
    }

    func clear() {
        cache.removeAll()
    }
}

// MARK: - AI Service

@MainActor
class AIService: ObservableObject {
    static let shared = AIService()

    private nonisolated let cache = ResponseCache()

    @Published var isProcessing = false
    @Published var lastError: String?

    // Services
    private let contactsProvider = ContactsProvider()
    private let photosProvider = PhotosProvider()
    private let keychainService = KeychainService.shared

    private init() {
        // Migrate legacy keys on first launch
        keychainService.migrateFromLegacyStorage()
    }

    // MARK: - API Key Access

    private var apiKey: String? {
        // First check Keychain
        if let key = keychainService.getAPIKey(for: .anthropic) {
            return key
        }
        // Fallback to environment variable (for development)
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    

    // MARK: - Main Query Method

    func query(_ message: String) async -> AIResponse {
        isProcessing = true
        defer { isProcessing = false }

        // Route to appropriate provider
        switch AIConfig.provider {
        case .groq:
            return await queryWithGroq(message)
        case .claude:
            guard let apiKey = apiKey, !apiKey.isEmpty else {
                return .error("API key not set. Open Settings to add your API key.")
            }
            do {
                let response = try await sendToClaudeWithTools(message: message, apiKey: apiKey)
                return await processResponse(response)
            } catch {
                lastError = error.localizedDescription
                return .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Groq Llama Query

    private func queryWithGroq(_ message: String) async -> AIResponse {
        do {
            // Check if this is a photo/video search query
            if isPhotoSearchQuery(message) {
                return await handlePhotoSearch(query: message)
            }

            // For other queries, use Groq chat
            let systemPrompt = """
            You are a helpful AI assistant in a macOS notch app. Be concise but helpful.
            When the user asks about photos, videos, or images from their library, let them know you can search for them.
            """

            let response = try await GroqService.shared.chat(message: message, systemPrompt: systemPrompt)
            return .text(response)
        } catch {
            lastError = error.localizedDescription
            return .error("Groq error: \(error.localizedDescription)")
        }
    }

    private func isPhotoSearchQuery(_ message: String) -> Bool {
        let lowered = message.lowercased()
        
        // Direct media keywords
        let mediaKeywords = ["photo", "photos", "picture", "pictures", "image", "images", "video", "videos", "clip", "clips", "recording", "recordings"]
        if mediaKeywords.contains(where: { lowered.contains($0) }) {
            return true
        }
        
        // Action + context patterns (show/find + activity/place)
        let actionKeywords = ["show me", "find my", "find me", "search for", "look for", "where i", "where we", "when i", "when we", "from my library"]
        if actionKeywords.contains(where: { lowered.contains($0) }) {
            return true
        }
        
        // Known places/activities that imply media search
        let contextKeywords = ["miraggio", "vacation", "trip to", "holiday"]
        if contextKeywords.contains(where: { lowered.contains($0) }) {
            return true
        }
        
        return false
    }

    private func handlePhotoSearch(query: String) async -> AIResponse {
        print("[PhotoSearch] Using SmartPhotoSearch for: '\(query)'")

        do {
            // Use the new SmartPhotoSearch system
            let response = try await SmartPhotoSearch.shared.search(query)

            // Convert to PhotoSearchResults for UI
            let assets = await SmartPhotoSearch.shared.fetchAssets(from: response)

            if assets.isEmpty {
                return .text("No photos found matching '\(query)'")
            }

            // Create PhotoSearchResults
            let results = await withTaskGroup(of: PhotoSearchResult?.self) { group in
                for asset in assets {
                    group.addTask {
                        let dateStr: String? = asset.creationDate.map { date in
                            let formatter = DateFormatter()
                            formatter.dateStyle = .medium
                            formatter.timeStyle = .short
                            return formatter.string(from: date)
                        }
                        return PhotoSearchResult(
                            asset: asset,
                            thumbnail: nil,
                            info: PhotoAssetInfo(
                                id: asset.localIdentifier,
                                mediaType: asset.mediaType == .video ? "video" : "photo",
                                creationDate: dateStr,
                                duration: asset.mediaType == .video ? self.formatDuration(asset.duration) : nil,
                                location: asset.location?.coordinate,
                                isFavorite: asset.isFavorite
                            ),
                            confidence: "smart-search"
                        )
                    }
                }

                var results: [PhotoSearchResult] = []
                for await result in group {
                    if let r = result { results.append(r) }
                }
                return results
            }

            let toolResult = ToolResult(
                id: UUID().uuidString,
                name: "search_photos",
                result: .photoResults(results, nil)
            )

            let summary = "Found \(results.count) photo(s) matching '\(query)'"
            return .toolResults(summary, [toolResult])

        } catch {
            print("[PhotoSearch] SmartPhotoSearch error: \(error)")
            return .error("Photo search failed: \(error.localizedDescription)")
        }
    }

    private func extractLimitFromQuery(_ query: String) -> Int? {
        let patterns = [
            "(\\d+)\\s*photos?",
            "(\\d+)\\s*pictures?",
            "(\\d+)\\s*videos?",
            "(\\d+)\\s*images?",
            "show\\s*me\\s*(\\d+)",
            "find\\s*(\\d+)",
            "top\\s*(\\d+)",
            "last\\s*(\\d+)",
            "latest\\s*(\\d+)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                return Int(query[range])
            }
        }
        return nil
    }

    /// Use Llama to extract the actual search terms from natural language
    private func extractSearchTermsWithLlama(_ query: String) async -> String {
        let prompt = """
        Extract the search keywords from this photo search query. Return ONLY the key search terms, nothing else.

        Examples:
        - "show me photos from Miraggio" → "Miraggio"
        - "find pictures of the beach in Greece" → "beach Greece"
        - "photos from my vacation in Paris last summer" → "Paris vacation"
        - "show me 10 photos of Tesla cars" → "Tesla cars"
        - "pictures with my dog at the park" → "dog park"

        Query: "\(query)"

        Search terms:
        """

        do {
            let response = try await GroqService.shared.chat(message: prompt, systemPrompt: "You extract search keywords from queries. Reply with ONLY the keywords, no explanation.")
            let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "Search terms:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // If Llama returns something reasonable, use it; otherwise fall back to original
            if !cleaned.isEmpty && cleaned.count < query.count * 2 {
                return cleaned
            }
        } catch {
            print("[PhotoSearch] Llama extraction failed: \(error.localizedDescription)")
        }

        // Fallback: extract location if found, otherwise use original query
        if let location = extractLocationFromQuery(query) {
            return location
        }
        return query
    }

    // MARK: - Claude API Call

    private func sendToClaudeWithTools(message: String, apiKey: String) async throws -> ClaudeResponse {
        var request = URLRequest(url: URL(string: AIConfig.apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var userMessage = message
        let context = ContentManager.shared.currentContext
        if !context.isEmpty {
            if let contextData = try? JSONSerialization.data(withJSONObject: context),
               let contextString = String(data: contextData, encoding: .utf8) {
                userMessage = "[Context: \(contextString)]\n\nUser: \(message)"
            }
        }

        let body: [String: Any] = [
            "model": AIConfig.model,
            "max_tokens": AIConfig.maxTokens,
            "system": AIConfig.systemPrompt,
            "tools": AITool.allCases.map { $0.definition },
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(httpResponse.statusCode, errorBody)
        }

        return try JSONDecoder().decode(ClaudeResponse.self, from: data)
    }

    // MARK: - Process Response & Execute Tools

    private func processResponse(_ response: ClaudeResponse) async -> AIResponse {
        var textContent = ""
        var toolResults: [ToolResult] = []

        for content in response.content {
            switch content {
            case .text(let text):
                textContent = text

            case .toolUse(let id, let name, let input):
                let result = await executeToolCall(name: name, input: input)
                toolResults.append(ToolResult(id: id, name: name, result: result))
            }
        }

        if !toolResults.isEmpty {
            return .toolResults(textContent, toolResults)
        }

        return .text(textContent)
    }

    private func executeToolCall(name: String, input: [String: Any]) async -> ToolExecutionResult {
        guard let tool = AITool(rawValue: name) else {
            return .error("Unknown tool: \(name)")
        }

        switch tool {
        case .contactsSearch:
            let query = input["query"] as? String ?? ""
            return await contactsProvider.search(query: query)

        case .searchPhotos:
            let query = input["query"] as? String ?? ""
            return await executeSmartPhotoSearch(query: query)

        case .manageIndex:
            let action = input["action"] as? String ?? "status"
            return await handleSmartIndexing(action: action)
        }
    }

    // MARK: - Smart Photo Search

    private func executeSmartPhotoSearch(query: String) async -> ToolExecutionResult {
        do {
            let response = try await SmartPhotoSearch.shared.search(query)
            let assets = await SmartPhotoSearch.shared.fetchAssets(from: response)

            if assets.isEmpty {
                return .text("No photos found matching '\(query)'")
            }

            let results = await withTaskGroup(of: PhotoSearchResult?.self) { group in
                for asset in assets {
                    group.addTask {
                        let dateStr: String? = asset.creationDate.map { date in
                            let formatter = DateFormatter()
                            formatter.dateStyle = .medium
                            formatter.timeStyle = .short
                            return formatter.string(from: date)
                        }
                        return PhotoSearchResult(
                            asset: asset,
                            thumbnail: nil,
                            info: PhotoAssetInfo(
                                id: asset.localIdentifier,
                                mediaType: asset.mediaType == .video ? "video" : "photo",
                                creationDate: dateStr,
                                duration: asset.mediaType == .video ? self.formatDuration(asset.duration) : nil,
                                location: asset.location?.coordinate,
                                isFavorite: asset.isFavorite
                            ),
                            confidence: "smart-search"
                        )
                    }
                }

                var results: [PhotoSearchResult] = []
                for await result in group {
                    if let r = result { results.append(r) }
                }
                return results
            }

            return .photoResults(results, nil)
        } catch {
            return .error("Photo search failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Smart Indexing

    private func handleSmartIndexing(action: String) async -> ToolExecutionResult {
        switch action {
        case "start":
            // Start building indexes in background
            Task {
                _ = await SmartPhotoSearch.shared.buildIndexes { phase, current, total in
                    let progress = IndexingProgress(
                        current: current,
                        total: total,
                        phase: .analyzing
                    )
                    Task { @MainActor in
                        ContentManager.shared.showIndexingProgress(progress)
                    }
                }
                await MainActor.run {
                    ContentManager.shared.showChat()
                }
            }
            return .text("Started building indexes. GeoHash index (~3 seconds) + Label index (~50ms per photo). Progress shows in the notch.")

        case "clear":
            await GeoHashIndex.shared.clear()
            await LabelIndex.shared.clear()
            return .text("Indexes cleared. Rebuild with 'index my photos'.")

        case "status":
            let geoStats = await GeoHashIndex.shared.stats
            let labelStats = await LabelIndex.shared.stats

            if geoStats.photosIndexed == 0 && labelStats.photosIndexed == 0 {
                return .text("No indexes built yet. Say 'index my photos' to build fast location and label indexes.")
            }

            return .text("Indexes ready: \(geoStats.photosIndexed) photos with geo data, \(labelStats.photosIndexed) photos with labels. \(geoStats.uniqueCells) unique geohash locations, \(labelStats.uniqueLabels) unique labels.")

        default:
            return .text("Unknown action. Use: start, status, or clear.")
        }
    }

    /// Parse time period expressions like "last summer", "2023", "winter 2022"
    private func parseDateRange(from timePeriod: String) -> (start: Date, end: Date)? {
        let lowercased = timePeriod.lowercased().trimmingCharacters(in: .whitespaces)
        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        
        // Extract year if present (e.g., "summer 2023", "2022")
        let yearPattern = try? NSRegularExpression(pattern: "\\b(20\\d{2})\\b")
        let yearMatch = yearPattern?.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased))
        let specifiedYear: Int? = yearMatch.flatMap {
            Range($0.range(at: 1), in: lowercased).map { Int(lowercased[$0])! }
        }
        
        // Determine if "last" is present
        let isLast = lowercased.contains("last")
        
        // Season definitions (month ranges)
        let seasons: [(name: String, startMonth: Int, endMonth: Int)] = [
            ("winter", 12, 2),   // Dec-Feb
            ("spring", 3, 5),    // Mar-May
            ("summer", 6, 8),    // Jun-Aug
            ("fall", 9, 11),     // Sep-Nov
            ("autumn", 9, 11)    // Sep-Nov (alias)
        ]
        
        // Check for seasons
        for season in seasons {
            if lowercased.contains(season.name) {
                var year = specifiedYear ?? currentYear
                
                // "last summer" means previous occurrence
                if isLast && specifiedYear == nil {
                    let currentMonth = calendar.component(.month, from: now)
                    // If we're past this season, use current year; otherwise use last year
                    if currentMonth > season.endMonth || (season.name == "winter" && currentMonth > 2) {
                        // Season already passed this year
                    } else {
                        year -= 1
                    }
                }
                
                // Handle winter spanning two years
                let startYear = (season.name == "winter") ? year - 1 : year
                let endYear = (season.name == "winter") ? year : year
                
                let startComponents = DateComponents(year: startYear, month: season.startMonth, day: 1)
                let endComponents = DateComponents(year: endYear, month: season.endMonth + 1, day: 1)
                
                if let start = calendar.date(from: startComponents),
                   let end = calendar.date(from: endComponents) {
                    print("[DateParse] '\(timePeriod)' → \(start) to \(end)")
                    return (start, end)
                }
            }
        }
        
        // Check for just a year like "2023"
        if let year = specifiedYear, lowercased.trimmingCharacters(in: .decimalDigits).isEmpty || 
           lowercased == "\(year)" || lowercased.contains("in \(year)") {
            let startComponents = DateComponents(year: year, month: 1, day: 1)
            let endComponents = DateComponents(year: year + 1, month: 1, day: 1)
            if let start = calendar.date(from: startComponents),
               let end = calendar.date(from: endComponents) {
                print("[DateParse] '\(timePeriod)' → full year \(year)")
                return (start, end)
            }
        }
        
        // "last year"
        if lowercased.contains("last year") {
            let lastYear = currentYear - 1
            let startComponents = DateComponents(year: lastYear, month: 1, day: 1)
            let endComponents = DateComponents(year: currentYear, month: 1, day: 1)
            if let start = calendar.date(from: startComponents),
               let end = calendar.date(from: endComponents) {
                return (start, end)
            }
        }
        
        // "last month"
        if lowercased.contains("last month") {
            if let start = calendar.date(byAdding: .month, value: -1, to: now),
               let startOfLastMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: start)),
               let endOfLastMonth = calendar.date(byAdding: .month, value: 1, to: startOfLastMonth) {
                return (startOfLastMonth, endOfLastMonth)
            }
        }
        
        print("[DateParse] Could not parse '\(timePeriod)'")
        return nil
    }
    
    /// Extract time period from query (e.g., "last summer", "2023", "winter 2022")
    private func extractTimePeriodFromQuery(_ query: String) -> String? {
        let lowercased = query.lowercased()
        
        // Check for seasons with optional year
        let seasonPatterns = [
            "(last\\s+)?(summer|winter|spring|fall|autumn)(\\s+\\d{4})?",
            "(summer|winter|spring|fall|autumn)\\s+(\\d{4})",
            "last\\s+year",
            "last\\s+month",
            "\\b(20\\d{2})\\b"  // Just a year like 2023
        ]
        
        for pattern in seasonPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)),
               let range = Range(match.range, in: lowercased) {
                let period = String(lowercased[range]).trimmingCharacters(in: .whitespaces)
                print("[TimePeriodExtract] Found time period in query: '\(period)'")
                return period
            }
        }
        
        return nil
    }
    
    /// Extract location from query (e.g., "photos from Greece" → "Greece", "Miraggion hotel" → "Miraggion hotel")
    private func extractLocationFromQuery(_ query: String) -> String? {
        let lowercased = query.lowercased()
        
        // Pattern: "from <location>", "in <location>", "at <location>"
        let patterns = [
            "from ([a-zA-Z][a-zA-Z0-9 ]+)",
            "in ([a-zA-Z][a-zA-Z0-9 ]+)",
            "at ([a-zA-Z][a-zA-Z0-9 ]+)",
            "near ([a-zA-Z][a-zA-Z0-9 ]+)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                let location = String(query[range]).trimmingCharacters(in: .whitespaces)
                // Filter out common non-location words
                let nonLocations = ["me", "my", "the", "a", "an", "photos", "pictures", "videos", "last", "this"]
                if !nonLocations.contains(location.lowercased()) && location.count > 2 {
                    print("[LocationExtract] Found location in query: '\(location)'")
                    return location
                }
            }
        }
        
        // Check if query contains place indicators and extract the place name
        let placeIndicators = ["hotel", "restaurant", "beach", "airport", "museum", "park", "station", "resort", "spa", "cafe", "bar", "club"]
        for indicator in placeIndicators {
            if lowercased.contains(indicator) {
                // Try to extract just the place name, e.g., "Miraggio hotel" from "photos from Miraggio hotel"
                // Pattern: look for word(s) before or including the indicator
                let patterns = [
                    // "miraggio hotel", "the miraggio", "hotel miraggio"
                    "([a-zA-Z]+(?:\\s+[a-zA-Z]+)?\\s+\(indicator))",
                    "(\(indicator)\\s+[a-zA-Z]+(?:\\s+[a-zA-Z]+)?)",
                    // Just the indicator with preceding word
                    "([a-zA-Z]+\\s+\(indicator))"
                ]
                
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                       let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
                       let range = Range(match.range(at: 1), in: query) {
                        let placeName = String(query[range]).trimmingCharacters(in: .whitespaces)
                        if placeName.count > indicator.count + 1 { // More than just the indicator
                            print("[LocationExtract] Extracted place name: '\(placeName)' from query")
                            return placeName
                        }
                    }
                }
                
                // Fallback: use the indicator and surrounding context
                print("[LocationExtract] Query contains place indicator '\(indicator)', using semantic search")
                return query
            }
        }
        
        return nil
    }
    
    /// Geocode a location string to coordinates, with AI fallback for unknown places
    private func geocodeLocation(_ location: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        
        // First try direct geocoding
        do {
            let placemarks = try await geocoder.geocodeAddressString(location)
            if let coordinate = placemarks.first?.location?.coordinate {
                print("[Geocode] '\(location)' → \(coordinate.latitude), \(coordinate.longitude)")
                return coordinate
            }
        } catch {
            print("[Geocode] Direct geocode failed for '\(location)', trying AI resolution...")
        }
        
        // Fallback: Ask AI to resolve the location to a known place
        if let resolvedLocation = await resolveLocationWithAI(location) {
            print("[Geocode] AI resolved '\(location)' → '\(resolvedLocation)'")
            do {
                let placemarks = try await geocoder.geocodeAddressString(resolvedLocation)
                if let coordinate = placemarks.first?.location?.coordinate {
                    print("[Geocode] '\(resolvedLocation)' → \(coordinate.latitude), \(coordinate.longitude)")
                    return coordinate
                }
            } catch {
                print("[Geocode] Failed to geocode resolved location '\(resolvedLocation)': \(error)")
            }
        }
        
        return nil
    }
    
    /// Use AI to resolve an unknown location name to a known geographic location
    private func resolveLocationWithAI(_ location: String) async -> String? {
        guard let apiKey = apiKey else { return nil }
        
        let prompt = """
        What is the geographic location (city, region, or country) of "\(location)"?
        Reply with ONLY the location name that can be geocoded (e.g., "Corfu, Greece" or "Paris, France").
        If you don't know, reply with "UNKNOWN".
        """
        
        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 50,
            "messages": [["role": "user", "content": prompt]]
        ]
        
        guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = httpBody
        request.timeoutInterval = 10
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                let resolved = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if resolved != "UNKNOWN" && !resolved.isEmpty && resolved.count < 100 {
                    return resolved
                }
            }
        } catch {
            print("[Geocode] AI resolution failed: \(error)")
        }
        
        return nil
    }
    
    /// Use AI to resolve a location name directly to GPS coordinates
    /// This uses Groq/Llama to get approximate coordinates for places that don't geocode
    private func resolveLocationWithAI(locationName: String) async -> CLLocationCoordinate2D? {
        let prompt = """
        What are the approximate GPS coordinates (latitude, longitude) of "\(locationName)"?
        Reply with ONLY two numbers separated by a comma, like: 39.926, 23.706
        If you don't know or it's not a real place, reply with: UNKNOWN
        """
        
        do {
            let response = try await GroqService.shared.chat(
                message: prompt, 
                systemPrompt: "You are a geography expert. Provide GPS coordinates for locations."
            )
            
            let text = response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            // Parse "39.926, 23.706" format
            if text != "UNKNOWN" && !text.contains("UNKNOWN") {
                let parts = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
                if parts.count >= 2,
                   let lat = Double(parts[0].filter { $0.isNumber || $0 == "." || $0 == "-" }),
                   let lon = Double(parts[1].filter { $0.isNumber || $0 == "." || $0 == "-" }),
                   lat >= -90 && lat <= 90,
                   lon >= -180 && lon <= 180 {
                    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
            }
        } catch {
            print("[Geocode] AI GPS resolution failed: \(error)")
        }
        
        return nil
    }
    
    /// Reverse geocode coordinates to get place name
    private func reverseGeocodeLocation(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                // Build a searchable string from placemark components
                let components = [
                    placemark.name,
                    placemark.locality,           // City
                    placemark.subLocality,        // Neighborhood
                    placemark.administrativeArea, // State/Province
                    placemark.country
                ].compactMap { $0 }
                return components.joined(separator: " ")
            }
        } catch {
            // Silently fail - reverse geocoding often has rate limits
        }
        return nil
    }
    
    /// Check if a location string refers to a country (needs larger search radius)
    private func isCountryLevelLocation(_ location: String) async -> Bool {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(location)
            if let placemark = placemarks.first {
                // If the location resolves to just a country (no city/locality), use larger radius
                let hasCity = placemark.locality != nil || placemark.subLocality != nil
                let hasSpecificPlace = placemark.name != nil && placemark.name != placemark.country
                return !hasCity && !hasSpecificPlace
            }
        } catch {
            // If geocoding fails, assume country-level for common country names
            let commonCountries = ["greece", "italy", "france", "spain", "germany", "uk", "usa", 
                                   "japan", "australia", "mexico", "brazil", "india", "china",
                                   "portugal", "netherlands", "belgium", "austria", "switzerland"]
            return commonCountries.contains(location.lowercased())
        }
        return false
    }
    
    /// Check if a photo's location is near the target location (within ~100km)
    private func isNearLocation(_ assetLocation: CLLocation, target: CLLocationCoordinate2D, radiusKm: Double = 100) -> Bool {
        let targetLocation = CLLocation(latitude: target.latitude, longitude: target.longitude)
        let distance = assetLocation.distance(from: targetLocation) / 1000 // Convert to km
        return distance <= radiusKm
    }
    
    /// Extract a number from a query like "5 latest photos" -> 5
    private func extractNumberFromQuery(_ query: String) -> Int? {
        let words = query.lowercased().split(separator: " ")
        for word in words {
            if let num = Int(word), num > 0 && num <= 100 {
                return num
            }
        }
        // Check for written numbers
        let writtenNumbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                             "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        for word in words {
            if let num = writtenNumbers[String(word)] {
                return num
            }
        }
        return nil
    }
    
    /// Format video duration from seconds to human-readable format
    private nonisolated func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

// MARK: - Response Types

enum AIResponse {
    case text(String)
    case toolResults(String, [ToolResult])
    case error(String)
}

struct ToolResult {
    let id: String
    let name: String
    let result: ToolExecutionResult
}

enum ToolExecutionResult {
    case contacts([ContactInfo])
    case photoResults([PhotoSearchResult], NSImage?) // Results with contact sheet preview
    case text(String)
    case error(String)
}

// MARK: - Claude Response Models

struct ClaudeResponse: Codable {
    let id: String
    let content: [ContentBlock]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case id, content
        case stopReason = "stop_reason"
    }
}

enum ContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let inputData = try container.decode([String: AnyCodable].self, forKey: .input)
            let input = inputData.mapValues { $0.value }
            self = .toolUse(id: id, name: name, input: input)
        default:
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, _):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
        }
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(Int, String)
    case rateLimitExceeded

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "API key not configured"
        case .invalidResponse: return "Invalid API response"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .rateLimitExceeded: return "Daily query limit reached"
        }
    }
}


