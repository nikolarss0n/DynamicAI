import Foundation
import Combine
import MapKit
import CoreLocation
import Photos
import AppKit

// MARK: - AI Service Configuration

struct AIConfig {
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

    Guidelines:
    - Answer general knowledge directly without tools
    - Keep responses concise (2-3 sentences)
    - Support any language

    You are a general assistant like Apple Intelligence - help with anything!
    """
}

// MARK: - Tool Definitions

enum AITool: String, CaseIterable {
    case searchMovies = "search_movies"
    case showMovieDetail = "show_movie_detail"
    case searchCars = "search_cars"
    case calendarQuery = "calendar_query"
    case remindersQuery = "reminders_query"
    case contactsSearch = "contacts_search"
    case launchApp = "launch_app"
    case systemInfo = "system_info"
    case setTimer = "set_timer"
    case clipboard = "clipboard"
    case darkMode = "dark_mode"
    case volumeControl = "volume_control"
    case webSearch = "web_search"
    case searchPlaces = "search_places"
    case getWeather = "get_weather"
    case getBattery = "get_battery"
    case controlMusic = "control_music"
    case smartTrip = "smart_trip"
    case searchPhotos = "search_photos"
    case indexVideos = "index_videos"

    var definition: [String: Any] {
        switch self {
        case .searchMovies:
            return [
                "name": rawValue,
                "description": "Search movies. Use type='search' with query for specific movies/franchises. Add filter to narrow by release status.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Movie title, franchise or keyword (e.g., 'marvel', 'batman', 'star wars')"],
                        "type": ["type": "string", "enum": ["search", "now_playing", "upcoming", "popular"], "description": "search=keyword search, others=browse lists"],
                        "filter": ["type": "string", "enum": ["upcoming", "now_playing"], "description": "Optional: filter search results by release status"]
                    ],
                    "required": ["type"]
                ]
            ]
        case .showMovieDetail:
            return [
                "name": rawValue,
                "description": "Show detailed view for a movie with additional info.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "movie_title": ["type": "string", "description": "Title of the movie"],
                        "additional_info": ["type": "string", "description": "Additional information to display"]
                    ],
                    "required": ["movie_title", "additional_info"]
                ]
            ]
        case .searchCars:
            return [
                "name": rawValue,
                "description": "Search car information, specs, images",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "make": ["type": "string", "description": "Manufacturer (Toyota, BMW, etc)"],
                        "model": ["type": "string", "description": "Model name"],
                        "year": ["type": "integer", "description": "Model year"]
                    ],
                    "required": ["make"]
                ]
            ]
        case .calendarQuery:
            return [
                "name": rawValue,
                "description": "Query or manage calendar events",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["list", "search", "today", "week"]],
                        "query": ["type": "string", "description": "Search term for events"]
                    ],
                    "required": ["action"]
                ]
            ]
        case .remindersQuery:
            return [
                "name": rawValue,
                "description": "Query, create, or complete reminders",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["list", "today", "overdue", "search", "lists", "create", "complete"], "description": "list=show reminders, today=due today, overdue=past due, search=find by text, lists=show all lists, create=new reminder, complete=mark done"],
                        "list_name": ["type": "string", "description": "Filter by reminder list name (e.g., 'Shopping', 'Work')"],
                        "query": ["type": "string", "description": "Search text or reminder title to create/complete"]
                    ],
                    "required": ["action"]
                ]
            ]
        case .webSearch:
            return [
                "name": rawValue,
                "description": "Search web for current information",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query"]
                    ],
                    "required": ["query"]
                ]
            ]
        case .searchPlaces:
            return [
                "name": rawValue,
                "description": "Search for restaurants, cafes, hotels, attractions, and other places in a specific location. Returns places with addresses, distances, and a map. Can show travel time from user's current location.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "What to search for (e.g., 'amazing restaurants', 'best cafes', 'hotels')"],
                        "location": ["type": "string", "description": "City or area to search in (e.g., 'Sofia', 'Paris', 'Tokyo')"],
                        "category": ["type": "string", "enum": ["restaurant", "cafe", "bar", "hotel", "attraction", "museum", "park", "shopping", "gym"], "description": "Optional category filter"],
                        "from_current_location": ["type": "boolean", "description": "If true, show travel time from user's current location. Use when user asks 'how long to get there', 'from my location', 'from here', etc."]
                    ],
                    "required": ["query", "location"]
                ]
            ]
        case .getWeather:
            return [
                "name": rawValue,
                "description": "Get current weather and forecast for a location",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "location": ["type": "string", "description": "City name or location"]
                    ],
                    "required": ["location"]
                ]
            ]
        case .getBattery:
            return [
                "name": rawValue,
                "description": "Get battery status of Mac and connected devices",
                "input_schema": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        case .controlMusic:
            return [
                "name": rawValue,
                "description": "Control Apple Music - play, pause, skip, or create playlists",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["play", "pause", "next", "previous", "playlist"]],
                        "query": ["type": "string", "description": "Song, artist, genre, or playlist name"]
                    ],
                    "required": ["action"]
                ]
            ]
        case .smartTrip:
            return [
                "name": rawValue,
                "description": "Smart trip assistant - checks weather, battery, calendar and provides suggestions",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "destination": ["type": "string", "description": "Where the user is going"],
                        "departure_time": ["type": "string", "description": "When leaving (optional)"]
                    ],
                    "required": ["destination"]
                ]
            ]
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
        case .launchApp:
            return [
                "name": rawValue,
                "description": "Launch/open an application by name",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "App name (e.g., 'Safari', 'Slack', 'VS Code')"],
                        "action": ["type": "string", "enum": ["open", "list_running"], "description": "open=launch app, list_running=show running apps"]
                    ],
                    "required": ["name"]
                ]
            ]
        case .systemInfo:
            return [
                "name": rawValue,
                "description": "Get system information: CPU usage, memory, disk space, uptime",
                "input_schema": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        case .setTimer:
            return [
                "name": rawValue,
                "description": "Set a timer that will show a notification when complete",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "description": "Timer duration in minutes"],
                        "label": ["type": "string", "description": "Optional label for the timer"]
                    ],
                    "required": ["minutes"]
                ]
            ]
        case .clipboard:
            return [
                "name": rawValue,
                "description": "Read or write clipboard contents",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["read", "write"], "description": "read=get clipboard, write=set clipboard"],
                        "text": ["type": "string", "description": "Text to copy (only for write action)"]
                    ],
                    "required": ["action"]
                ]
            ]
        case .darkMode:
            return [
                "name": rawValue,
                "description": "Check or change dark mode setting",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["get", "toggle", "on", "off"], "description": "get=check status, toggle=switch, on/off=set explicitly"]
                    ],
                    "required": ["action"]
                ]
            ]
        case .volumeControl:
            return [
                "name": rawValue,
                "description": "Get or set system volume",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["get", "set", "mute", "unmute"], "description": "Volume action"],
                        "level": ["type": "integer", "description": "Volume level 0-100 (only for set action)"]
                    ],
                    "required": ["action"]
                ]
            ]
        case .searchPhotos:
            return [
                "name": rawValue,
                "description": "Search user's photo library using AI vision. Can find photos and videos by describing what's in them.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "What to search for (e.g., 'skipping rope', 'my cat', 'beach sunset', 'cooking')"],
                        "media_type": ["type": "string", "enum": ["all", "photos", "videos"], "description": "Filter by media type"],
                        "days_back": ["type": "integer", "description": "Optional: only search media from last N days"]
                    ],
                    "required": ["query"]
                ]
            ]
        case .indexVideos:
            return [
                "name": rawValue,
                "description": "Index videos for faster searching. Creates a searchable index with visual analysis and audio transcription. Use when user wants to index their videos or improve search quality.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["start", "status", "clear"], "description": "start=begin indexing, status=check progress, clear=delete index"],
                        "limit": ["type": "integer", "description": "Optional: max number of videos to index (for testing). Default indexes all."]
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
    private let movieProvider = MovieProvider()
    private let calendarProvider = CalendarProvider()
    private let remindersProvider = RemindersProvider()
    private let contactsProvider = ContactsProvider()
    private let placeProvider = PlaceProvider()
    private let photosProvider = PhotosProvider()
    private let batteryService = BatteryService.shared
    private let musicService = MusicService.shared
    private let keychainService = KeychainService.shared
    private let storeService = StoreService.shared

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

    private var weatherApiKey: String? {
        keychainService.getAPIKey(for: .openWeather)
    }

    // MARK: - Main Query Method

    func query(_ message: String) async -> AIResponse {
        // Check rate limits
        if !storeService.canMakeQueries {
            return .error("Daily limit reached. Upgrade to Pro for unlimited queries!")
        }

        guard let apiKey = apiKey, !apiKey.isEmpty else {
            return .error("API key not set. Open Settings to add your API key.")
        }

        isProcessing = true
        defer { isProcessing = false }

        // Increment query count for free users
        if !storeService.isPro && !storeService.hasByok {
            storeService.incrementQueryCount()
        }

        do {
            let response = try await sendToClaudeWithTools(message: message, apiKey: apiKey)
            return await processResponse(response)
        } catch {
            lastError = error.localizedDescription
            return .error(error.localizedDescription)
        }
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
        case .searchMovies:
            let query = input["query"] as? String ?? ""
            let type = input["type"] as? String ?? "search"
            let filter = input["filter"] as? String
            return await movieProvider.search(query: query, type: type, filter: filter)

        case .showMovieDetail:
            let movieTitle = input["movie_title"] as? String ?? ""
            let additionalInfo = input["additional_info"] as? String ?? ""
            return await showMovieDetail(title: movieTitle, info: additionalInfo)

        case .searchCars:
            let make = input["make"] as? String ?? ""
            let model = input["model"] as? String
            let year = input["year"] as? Int
            return await searchCars(make: make, model: model, year: year)

        case .calendarQuery:
            let action = input["action"] as? String ?? "today"
            let query = input["query"] as? String
            return await calendarProvider.query(action: action, searchQuery: query)

        case .remindersQuery:
            let action = input["action"] as? String ?? "list"
            let listName = input["list_name"] as? String
            let query = input["query"] as? String
            return await remindersProvider.query(action: action, listName: listName, query: query)

        case .webSearch:
            let query = input["query"] as? String ?? ""
            return await webSearch(query: query)

        case .searchPlaces:
            let query = input["query"] as? String ?? ""
            let location = input["location"] as? String
            let categoryStr = input["category"] as? String
            let category = categoryStr.flatMap { PlaceCategory(rawValue: $0) }
            // Default to true - users generally want travel time from their location
            let fromCurrentLocation = input["from_current_location"] as? Bool ?? true
            let result = await placeProvider.searchPlaces(query: query, location: location, category: category, fromCurrentLocation: fromCurrentLocation)
            if let error = result.error {
                return .error(error)
            }
            return .places(result.places, result.mapSnapshot)

        case .getWeather:
            let location = input["location"] as? String ?? "Sofia"
            return await getWeather(location: location)

        case .getBattery:
            return await getBatteryStatus()

        case .controlMusic:
            let action = input["action"] as? String ?? "play"
            let query = input["query"] as? String
            return await controlMusic(action: action, query: query)

        case .smartTrip:
            let destination = input["destination"] as? String ?? ""
            let departureTime = input["departure_time"] as? String
            return await smartTripAssistant(destination: destination, departureTime: departureTime)

        case .contactsSearch:
            let query = input["query"] as? String ?? ""
            return await contactsProvider.search(query: query)

        case .launchApp:
            let name = input["name"] as? String ?? ""
            let action = input["action"] as? String ?? "open"
            if action == "list_running" {
                return await MainActor.run { SystemProvider.shared.listRunningApps() }
            }
            return await MainActor.run { SystemProvider.shared.launchApp(name: name) }

        case .systemInfo:
            return await MainActor.run { SystemProvider.shared.getSystemInfo() }

        case .setTimer:
            let minutes = input["minutes"] as? Int ?? 1
            let label = input["label"] as? String
            return await SystemProvider.shared.setTimer(minutes: minutes, label: label)

        case .clipboard:
            let action = input["action"] as? String ?? "read"
            let text = input["text"] as? String
            return await MainActor.run {
                if action == "write", let text = text {
                    return SystemProvider.shared.setClipboard(text: text)
                }
                return SystemProvider.shared.getClipboard()
            }

        case .darkMode:
            let action = input["action"] as? String ?? "get"
            return await MainActor.run {
                switch action {
                case "toggle": return SystemProvider.shared.toggleDarkMode()
                case "on": return SystemProvider.shared.setDarkMode(enabled: true)
                case "off": return SystemProvider.shared.setDarkMode(enabled: false)
                default: return SystemProvider.shared.getDarkMode()
                }
            }

        case .volumeControl:
            let action = input["action"] as? String ?? "get"
            let level = input["level"] as? Int
            return await MainActor.run {
                switch action {
                case "set":
                    return SystemProvider.shared.setVolume(level: level ?? 50)
                case "mute":
                    return SystemProvider.shared.toggleMute()
                case "unmute":
                    return SystemProvider.shared.toggleMute()
                default:
                    return SystemProvider.shared.getVolume()
                }
            }

        case .searchPhotos:
            let query = input["query"] as? String ?? ""
            let mediaType = input["media_type"] as? String ?? "all"
            let daysBack = input["days_back"] as? Int
            return await searchPhotosWithVision(query: query, mediaType: mediaType, daysBack: daysBack)

        case .indexVideos:
            let action = input["action"] as? String ?? "status"
            let limit = input["limit"] as? Int
            return await handleVideoIndexing(action: action, limit: limit)
        }
    }

    // MARK: - Video Indexing

    private func handleVideoIndexing(action: String, limit: Int? = nil) async -> ToolExecutionResult {
        let indexService = VideoIndexService.shared

        switch action {
        case "start":
            if indexService.isIndexing {
                return .text("Indexing is already in progress. Check the notch for progress.")
            }

            // Start indexing in background
            Task {
                await indexService.startIndexing(videos: nil, limit: limit) { progress in
                    Task { @MainActor in
                        ContentManager.shared.showIndexingProgress(progress)
                    }
                }
                // Return to chat when done
                await MainActor.run {
                    ContentManager.shared.showChat()
                }
            }

            let limitText = limit != nil ? " (limited to \(limit!) videos)" : ""
            return .text("Started indexing videos\(limitText). Progress will show in the notch. This analyzes video frames with Claude and transcribes audio with Groq Whisper. You can continue using the app while indexing runs.")

        case "clear":
            indexService.clearIndex()
            return .text("Video index cleared. You'll need to re-index to search videos by content.")

        case "status":
            let count = indexService.indexedCount
            if indexService.isIndexing {
                if let progress = indexService.indexingProgress {
                    return .text("Indexing in progress: \(progress.current)/\(progress.total) videos. Phase: \(progress.phase.rawValue)")
                }
                return .text("Indexing in progress...")
            } else if count > 0 {
                return .text("\(count) videos indexed and ready for instant search.")
            } else {
                return .text("No videos indexed yet. Say 'index my videos' to start indexing for faster, smarter search with audio transcription.")
            }

        default:
            return .text("Unknown action. Use: start, status, or clear.")
        }
    }

    // MARK: - Movie Detail

    private func showMovieDetail(title: String, info: String) async -> ToolExecutionResult {
        let manager = ContentManager.shared

        if let movie = manager.lastSelectedMovie, movie.title.lowercased().contains(title.lowercased()) {
            return .movieDetail(movie, info)
        }

        if let movie = manager.lastMovieList.first(where: { $0.title.lowercased().contains(title.lowercased()) }) {
            return .movieDetail(movie, info)
        }

        return .text(info)
    }

    // MARK: - Cars (Placeholder)

    private func searchCars(make: String, model: String?, year: Int?) async -> ToolExecutionResult {
        return .carResults([
            CarInfo(make: make, model: model ?? "Various", year: year ?? 2024, imageURL: nil)
        ])
    }

    // MARK: - Web Search (Placeholder)

    private func webSearch(query: String) async -> ToolExecutionResult {
        return .text("Web search for '\(query)' - Coming soon!")
    }

    // MARK: - Weather (Sandbox-compliant)

    private func getWeather(location: String) async -> ToolExecutionResult {
        guard let apiKey = weatherApiKey else {
            return .error("Weather API key not configured. Add it in Settings.")
        }

        let encodedLocation = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? location
        let urlString = "https://api.openweathermap.org/data/2.5/weather?q=\(encodedLocation)&appid=\(apiKey)&units=metric"

        do {
            guard let url = URL(string: urlString) else {
                return .error("Invalid URL")
            }

            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let main = json?["main"] as? [String: Any],
                  let weather = (json?["weather"] as? [[String: Any]])?.first,
                  let temp = main["temp"] as? Double,
                  let humidity = main["humidity"] as? Int,
                  let description = weather["description"] as? String,
                  let iconCode = weather["icon"] as? String else {
                return .error("Failed to parse weather data")
            }

            let feelsLike = main["feels_like"] as? Double ?? temp
            let sfIcon = mapWeatherIcon(iconCode)

            var suggestions: [String] = []
            let isRaining = iconCode.contains("09") || iconCode.contains("10") || iconCode.contains("11")
            let isSnowing = iconCode.contains("13")

            if isRaining { suggestions.append("Bring an umbrella!") }
            if isSnowing { suggestions.append("Dress warmly!") }
            if temp < 10 { suggestions.append("Wear a jacket!") }
            if temp > 30 { suggestions.append("Stay hydrated!") }

            let weatherInfo = WeatherInfo(
                location: location,
                temperature: Int(temp),
                feelsLike: Int(feelsLike),
                condition: description,
                icon: sfIcon,
                humidity: humidity,
                suggestions: suggestions
            )

            return .weather(weatherInfo)
        } catch {
            return .error("Weather fetch failed: \(error.localizedDescription)")
        }
    }

    private func mapWeatherIcon(_ code: String) -> String {
        switch code.prefix(2) {
        case "01": return "sun.max.fill"
        case "02": return "cloud.sun.fill"
        case "03": return "cloud.fill"
        case "04": return "smoke.fill"
        case "09": return "cloud.drizzle.fill"
        case "10": return "cloud.rain.fill"
        case "11": return "cloud.bolt.fill"
        case "13": return "snowflake"
        case "50": return "cloud.fog.fill"
        default: return "cloud.fill"
        }
    }

    // MARK: - Battery (Sandbox-compliant - Uses BatteryService)

    private func getBatteryStatus() async -> ToolExecutionResult {
        let batteryInfo = batteryService.getBatteryInfo()
        return .battery(batteryInfo)
    }

    // MARK: - Music Control (Sandbox-compliant - Uses MusicService)

    private func controlMusic(action: String, query: String?) async -> ToolExecutionResult {
        let result = await musicService.handleAction(action: action, query: query)
        return .text(result)
    }

    // MARK: - Smart Trip Assistant

    private func smartTripAssistant(destination: String, departureTime: String?) async -> ToolExecutionResult {
        var suggestions: [String] = []

        let routeInfo = await getRouteInfo(to: destination)

        var weatherInfo: WeatherInfo? = nil
        let weatherResult = await getWeather(location: destination)
        if case .weather(let weather) = weatherResult {
            weatherInfo = weather
            suggestions.append(contentsOf: weather.suggestions)
        }

        let batteryInfo = batteryService.getBatteryInfo()

        if batteryInfo.macPercent < 30 && !batteryInfo.macIsCharging {
            suggestions.append("Mac at \(batteryInfo.macPercent)% - charge before leaving")
        }
        for device in batteryInfo.devices {
            if device.percent < 30 {
                suggestions.append("\(device.name) at \(device.percent)% - charge it!")
            }
        }

        var calendarEvents: [CalendarDisplayItem] = []
        let calendarResult = await calendarProvider.query(action: "today", searchQuery: nil)
        if case .calendarEvents(let events) = calendarResult {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            calendarEvents = events.prefix(3).map { event in
                let timeStr = event.isAllDay ? "All day" : formatter.string(from: event.startDate)
                return CalendarDisplayItem(
                    id: event.id,
                    title: event.title,
                    time: timeStr,
                    location: event.location,
                    isAllDay: event.isAllDay,
                    startDate: event.startDate
                )
            }
        }

        if suggestions.isEmpty {
            suggestions.append("You're all set for your trip!")
        }

        let tripInfo = TripInfo(
            destination: destination,
            weather: weatherInfo,
            battery: batteryInfo,
            events: calendarEvents,
            suggestions: suggestions,
            route: routeInfo
        )

        return .trip(tripInfo)
    }

    // MARK: - Route Calculation

    private func getRouteInfo(to destination: String) async -> RouteInfo? {
        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.geocodeAddressString(destination)
            guard let destPlacemark = placemarks.first,
                  let destLocation = destPlacemark.location else {
                return nil
            }

            let destCoord = destLocation.coordinate
            let sourceCoord = await getCurrentLocationCoordinate()

            var distance: Double? = nil
            var duration: Double? = nil
            var polyline: MKPolyline? = nil

            if let source = sourceCoord {
                let routeData = await calculateRoute(from: source, to: destCoord)
                distance = routeData?.distance
                duration = routeData?.duration
                polyline = routeData?.polyline
            }

            return RouteInfo(
                destinationCoordinate: destCoord,
                sourceCoordinate: sourceCoord,
                distance: distance,
                duration: duration,
                routePolyline: polyline
            )
        } catch {
            return nil
        }
    }

    private func getCurrentLocationCoordinate() async -> CLLocationCoordinate2D? {
        if let coord = await getIPBasedLocation() {
            return coord
        }
        return nil
    }

    private func getIPBasedLocation() async -> CLLocationCoordinate2D? {
        let apis = [
            "https://ipapi.co/json/",
            "https://ipwho.is/",
            "https://freeipapi.com/api/json"
        ]

        for apiURL in apis {
            guard let url = URL(string: apiURL) else { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let lat = json["latitude"] as? Double ?? json["lat"] as? Double
                    let lon = json["longitude"] as? Double ?? json["lon"] as? Double

                    if let lat = lat, let lon = lon {
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private func calculateRoute(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> (distance: Double, duration: Double, polyline: MKPolyline)? {
        let sourcePlacemark = MKPlacemark(coordinate: source)
        let destPlacemark = MKPlacemark(coordinate: destination)

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: sourcePlacemark)
        request.destination = MKMapItem(placemark: destPlacemark)
        request.transportType = .automobile

        let directions = MKDirections(request: request)

        do {
            let response = try await directions.calculate()
            if let route = response.routes.first {
                return (route.distance, route.expectedTravelTime, route.polyline)
            }
        } catch {
            // Route calculation failed
        }
        return nil
    }

    // MARK: - Photo/Video Search with Vision

    private func searchPhotosWithVision(query: String, mediaType: String, daysBack: Int?) async -> ToolExecutionResult {
        guard let apiKey = apiKey else {
            return .error("API key not configured")
        }

        // FIRST: Check for simple "my photos" queries - handle before any vision/index search
        let lowercaseQuery = query.lowercased()
        let isMyPhotosQuery = lowercaseQuery.contains("my ") || 
                              lowercaseQuery.contains(" me") ||
                              lowercaseQuery.contains("of me") ||
                              lowercaseQuery.hasPrefix("my") ||
                              lowercaseQuery.hasSuffix(" me") ||
                              lowercaseQuery == "all photos" ||
                              lowercaseQuery == "latest" ||
                              lowercaseQuery == "recent" ||
                              lowercaseQuery.contains("latest photo") ||
                              lowercaseQuery.contains("recent photo")
        
        let isSimpleMyPhotosQuery = isMyPhotosQuery && 
            !lowercaseQuery.contains("where") && 
            !lowercaseQuery.contains("with") &&
            !lowercaseQuery.contains("at the") &&
            !lowercaseQuery.contains("doing") &&
            !lowercaseQuery.contains("playing")
        
        // Detect if query mentions photos explicitly
        let queryMentionsPhotos = lowercaseQuery.contains("photo") || lowercaseQuery.contains("picture")
        let limitFromQuery = extractNumberFromQuery(query) ?? 10
        
        print("[PhotoSearch] Query: '\(query)', isMyPhotosQuery: \(isMyPhotosQuery), isSimple: \(isSimpleMyPhotosQuery), queryMentionsPhotos: \(queryMentionsPhotos)")
        
        // Handle simple "my photos" queries FIRST - before video index
        if isSimpleMyPhotosQuery && queryMentionsPhotos {
            print("[PhotoSearch] Using person-based filtering for 'my photos' query")
            let assets = await photosProvider.fetchMyPhotos(limit: limitFromQuery, mediaType: .image)
            print("[PhotoSearch] fetchMyPhotos returned \(assets.count) assets")
            
            if !assets.isEmpty {
                let results = await withTaskGroup(of: PhotoSearchResult?.self) { group in
                    for asset in assets.prefix(limitFromQuery) {
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
                                    mediaType: "photo",
                                    creationDate: dateStr,
                                    duration: nil,
                                    location: asset.location?.coordinate,
                                    isFavorite: asset.isFavorite
                                ),
                                confidence: "person-match"
                            )
                        }
                    }
                    
                    var results: [PhotoSearchResult] = []
                    for await result in group {
                        if let r = result { results.append(r) }
                    }
                    return results
                }
                
                print("[PhotoSearch] Returning \(results.count) person-matched photos")
                return .photoResults(results, nil)
            }
        }

        // For videos, try the index first (instant search!)
        if mediaType == "videos" || mediaType == "all" {
            let indexService = await VideoIndexService.shared
            let indexMatches = await indexService.search(query: query)
            
            if !indexMatches.isEmpty {
                print("[PhotoSearch] Found \(indexMatches.count) matches in index!")
                
                // Convert index matches to PhotoSearchResult
                let results = await withTaskGroup(of: PhotoSearchResult?.self) { group in
                    for match in indexMatches.prefix(10) {
                        group.addTask {
                            // Get the PHAsset from the index entry
                            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [match.entry.videoId], options: nil)
                            guard let asset = fetchResult.firstObject else { return nil }
                            
                            return PhotoSearchResult(
                                asset: asset,
                                thumbnail: nil,
                                info: PhotoAssetInfo(
                                    id: match.entry.videoId,
                                    mediaType: "video",
                                    creationDate: nil,
                                    duration: self.formatDuration(match.entry.source.duration),
                                    location: nil,
                                    isFavorite: false
                                ),
                                confidence: "indexed"
                            )
                        }
                    }
                    
                    var results: [PhotoSearchResult] = []
                    for await result in group {
                        if let r = result { results.append(r) }
                    }
                    return results
                }
                
                if !results.isEmpty {
                    return .photoResults(results, nil)
                }
            }
        }

        var assets: [PHAsset] = []
        
        // Regular path - fetch assets for vision search
        switch mediaType {
        case "videos":
            assets = await photosProvider.fetchVideos(limit: 200, daysBack: daysBack)
        case "photos":
            assets = await photosProvider.fetchPhotos(limit: 200, daysBack: daysBack)
        default: // "all"
            async let videos = photosProvider.fetchVideos(limit: 100, daysBack: daysBack)
            async let photos = photosProvider.fetchPhotos(limit: 100, daysBack: daysBack)
            assets = await videos + photos
        }

        guard !assets.isEmpty else {
            return .text("No \(mediaType == "all" ? "photos or videos" : mediaType) found in your library.")
        }
        
        // Legacy check - remove the duplicate early return block
        if false {
            // Direct return for simple "show my photos" queries
            let results = await withTaskGroup(of: PhotoSearchResult?.self) { group in
                for asset in assets.prefix(limitFromQuery) {
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
                            confidence: "person-match"
                        )
                    }
                }
                
                var results: [PhotoSearchResult] = []
                for await result in group {
                    if let r = result { results.append(r) }
                }
                return results
            }
            
            if !results.isEmpty {
                return .photoResults(results, nil)
            }
        }

        let isVideoSearch = mediaType == "videos" || (mediaType == "all" && assets.first?.mediaType == .video)

        if isVideoSearch {
            // Use BATCH approach - send 5 thumbnails per API call in PARALLEL
            return await searchVideosInBatches(query: query, assets: assets, apiKey: apiKey)
        } else {
            // Use contact sheet for photos (they work better in grids)
            return await searchPhotosWithContactSheet(query: query, assets: assets, apiKey: apiKey)
        }
    }

    // MARK: - Batch Video Search (mini contact sheets in parallel)

    private func searchVideosInBatches(query: String, assets: [PHAsset], apiKey: String) async -> ToolExecutionResult {
        let videoAssets = assets.filter { $0.mediaType == .video }
        let videosToSearch = Array(videoAssets.prefix(60))  // Search first 60 videos

        print("[PhotoSearch] Creating mini contact sheets for \(videosToSearch.count) videos...")

        // Split into 10 batches of 6 videos each (3x2 grid with larger thumbnails)
        let batchSize = 6
        var batches: [(videos: [PHAsset], startIndex: Int)] = []

        for i in stride(from: 0, to: videosToSearch.count, by: batchSize) {
            let end = min(i + batchSize, videosToSearch.count)
            let batch = Array(videosToSearch[i..<end])
            batches.append((videos: batch, startIndex: i))
        }

        print("[PhotoSearch] Sending \(batches.count) mini contact sheets in parallel...")

        // Send all batches in PARALLEL
        var allMatches: [(index: Int, asset: PHAsset)] = []

        await withTaskGroup(of: [(Int, PHAsset)].self) { group in
            for (batchIndex, batch) in batches.enumerated() {
                group.addTask {
                    await self.searchMiniContactSheet(
                        videos: batch.videos,
                        startIndex: batch.startIndex,
                        batchIndex: batchIndex,
                        query: query,
                        apiKey: apiKey
                    )
                }
            }

            for await matches in group {
                allMatches.append(contentsOf: matches)
            }
        }

        print("[PhotoSearch] Found \(allMatches.count) total matches")

        if allMatches.isEmpty {
            return .text("No videos found matching '\(query)'")
        }

        // Convert to PhotoSearchResult - sort by index first
        let sortedMatches = allMatches.sorted { $0.index < $1.index }

        let results = sortedMatches.map { match -> PhotoSearchResult in
            PhotoSearchResult(
                asset: match.asset,
                thumbnail: nil,
                info: PhotoAssetInfo(
                    id: match.asset.localIdentifier,
                    mediaType: "video",
                    creationDate: nil,
                    duration: formatDuration(match.asset.duration),
                    location: match.asset.location?.coordinate,
                    isFavorite: match.asset.isFavorite
                ),
                confidence: "high"
            )
        }

        // Create a simple preview image
        let previewImage = NSImage(size: NSSize(width: 200, height: 150))

        return .photoResults(results, previewImage)
    }
    
    /// Interprets user search query to extract intent and context
    private func interpretSearchQuery(_ query: String) -> String {
        let lowercased = query.lowercased()
        var interpretations: [String] = []
        
        // Detect first-person references (user is the subject)
        let firstPersonIndicators = ["i ", "i'm ", "me ", "my ", "myself"]
        let isFirstPerson = firstPersonIndicators.contains { lowercased.contains($0) } ||
                           lowercased.hasPrefix("i ")
        
        if isFirstPerson {
            interpretations.append("• User is asking about THEMSELVES (adult) doing this activity")
            interpretations.append("• EXCLUDE: children, other people doing the activity")
        }
        
        // Detect specific activities that need exact matching
        let specificActivities = [
            "jump rope": "person actively using a jump rope, rope visible, jumping motion",
            "jumping rope": "person actively using a jump rope, rope visible, jumping motion",
            "skipping rope": "person actively using a jump rope/skip rope",
            "workout": "exercise activity, fitness setting or athletic movement",
            "exercise": "intentional physical training, not casual movement",
            "running": "jogging/running motion, athletic activity",
            "cooking": "food preparation, kitchen setting, cooking utensils",
            "swimming": "in water, swimming motion",
            "dancing": "rhythmic body movement to music or choreography",
            "playing guitar": "hands on guitar, instrument visible",
            "playing piano": "hands on piano keys, instrument visible"
        ]
        
        for (activity, description) in specificActivities {
            if lowercased.contains(activity) {
                interpretations.append("• SPECIFIC MATCH REQUIRED: \(description)")
                interpretations.append("• EXCLUDE: similar but different activities")
                break
            }
        }
        
        // Detect exclusion hints
        if lowercased.contains("not ") || lowercased.contains("without ") || lowercased.contains("exclude ") {
            interpretations.append("• User specified exclusions - respect them strictly")
        }
        
        // Detect location/setting requirements
        let locations = ["beach", "gym", "home", "outside", "indoor", "outdoor", "park", "kitchen", "office"]
        for location in locations {
            if lowercased.contains(location) {
                interpretations.append("• Setting must include: \(location)")
            }
        }
        
        if interpretations.isEmpty {
            return "• General search - match videos showing: \(query)"
        }
        
        return interpretations.joined(separator: "\n")
    }

    private func searchMiniContactSheet(
        videos: [PHAsset],
        startIndex: Int,
        batchIndex: Int,
        query: String,
        apiKey: String
    ) async -> [(Int, PHAsset)] {

        // Create mini contact sheet (6 videos in 3x2 grid at 400x300 = 1200x600)
        guard let result = await photosProvider.createVideoGrid(
            videos: videos,
            thumbnailSize: CGSize(width: 400, height: 300),
            columns: 3
        ) else {
            print("[Batch \(batchIndex)] Failed to create contact sheet")
            return []
        }

        // Convert to JPEG base64
        guard let tiffData = result.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return []
        }

        let base64Image = jpegData.base64EncodedString()
        print("[Batch \(batchIndex)] Contact sheet: \(jpegData.count / 1024) KB, \(videos.count) videos")

        // Parse user intent from query
        let interpretedQuery = interpretSearchQuery(query)
        
        let prompt = """
        This is a grid of \(videos.count) video thumbnails (3 columns x 2 rows).
        Videos numbered \(startIndex + 1) to \(startIndex + videos.count), left-to-right, top-to-bottom.
        Row 1: \(startIndex + 1), \(startIndex + 2), \(startIndex + 3)
        Row 2: \(startIndex + 4), \(startIndex + 5), \(startIndex + 6)

        USER QUERY: "\(query)"
        
        INTERPRETATION:
        \(interpretedQuery)

        TASK: Find videos that SPECIFICALLY match the interpreted query above.
        
        BE STRICT:
        - If query mentions "I" or "me" → look for an ADULT doing the activity, NOT children
        - If query is about a specific activity → the person must be DOING that activity, not just present
        - Exclude videos that only partially match (e.g., "jump rope" ≠ just "jumping" or "rope")
        
        Look carefully at EACH thumbnail: people (age, what they're doing), objects, activities, setting.

        Reply with ONLY JSON:
        {"matches": [\(startIndex + 1)], "reason": "brief description of why each matches"}

        If none match the SPECIFIC query: {"matches": [], "reason": "none match - explain why"}
        """

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 200,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64Image]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]

        var request = URLRequest(url: URL(string: AIConfig.apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let contentArray = json["content"] as? [[String: Any]],
               let firstContent = contentArray.first,
               let text = firstContent["text"] as? String {

                print("[Batch \(batchIndex)] Response: \(text)")

                // Parse matches from response
                if let jsonStart = text.firstIndex(of: "{"),
                   let jsonEnd = text.lastIndex(of: "}") {
                    let jsonStr = String(text[jsonStart...jsonEnd])
                    if let jsonData = jsonStr.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let matches = parsed["matches"] as? [Int] {

                        // Convert video numbers to (index, asset) pairs
                        return matches.compactMap { videoNum -> (Int, PHAsset)? in
                            let localIndex = videoNum - startIndex - 1  // Convert to 0-based local index
                            guard localIndex >= 0 && localIndex < videos.count else { return nil }
                            let globalIndex = startIndex + localIndex
                            return (globalIndex, videos[localIndex])
                        }
                    }
                }
            }
        } catch {
            print("[Batch \(batchIndex)] Error: \(error)")
        }

        return []
    }

    // MARK: - Photo Contact Sheet Search (original approach for photos)

    private func searchPhotosWithContactSheet(query: String, assets: [PHAsset], apiKey: String) async -> ToolExecutionResult {
        let photoAssets = assets.filter { $0.mediaType == .image }

        guard let result = await photosProvider.createPhotoContactSheet(
            photos: Array(photoAssets.prefix(40)),
            thumbnailSize: CGSize(width: 120, height: 120),
            columns: 8,
            maxPhotos: 40
        ) else {
            return .error("Failed to create contact sheet")
        }

        let contactSheetImage = result.image
        let assetMap = result.assetMap

        guard let tiffData = contactSheetImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return .error("Failed to encode contact sheet")
        }

        let base64Image = jpegData.base64EncodedString()

        let visionPrompt = """
        Analyze this contact sheet of photos. Each photo is numbered (top-left corner).

        TASK: Find photos showing "\(query)"

        Reply with ONLY JSON:
        {"matches": [1, 5], "confidence": "high", "description": "Photo 1 shows X"}

        If nothing matches: {"matches": [], "confidence": "high", "description": "No photos match"}
        """

        do {
            let visionResponse = try await sendVisionRequest(
                prompt: visionPrompt,
                imageBase64: base64Image,
                apiKey: apiKey
            )

            let matchingResults = parseVisionResponse(visionResponse, assetMap: assetMap, isVideo: false)

            if matchingResults.isEmpty {
                return .text("No photos found matching '\(query)'")
            }

            return .photoResults(matchingResults, nil)  // Don't show contact sheet in results
        } catch {
            return .error("Vision search failed: \(error.localizedDescription)")
        }
    }

    private func sendVisionRequest(prompt: String, imageBase64: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: AIConfig.apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",  // Better vision than Haiku
            "max_tokens": 500,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": imageBase64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0, errorBody)
        }

        // Parse response to get text content
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? [[String: Any]],
           let firstBlock = content.first,
           let text = firstBlock["text"] as? String {
            return text
        }

        throw AIError.invalidResponse
    }

    private func parseVisionResponse(_ response: String, assetMap: [Int: PHAsset], isVideo: Bool) -> [PhotoSearchResult] {
        var results: [PhotoSearchResult] = []

        // Try to parse JSON response
        guard let jsonStart = response.firstIndex(of: "{"),
              let jsonEnd = response.lastIndex(of: "}") else {
            return results
        }

        let jsonString = String(response[jsonStart...jsonEnd])

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let matches = json["matches"] as? [Int] else {
            return results
        }

        let confidence = json["confidence"] as? String

        for matchIndex in matches {
            // Contact sheet uses 1-based indexing for display, but assetMap uses 0-based for videos, 0-based for photos
            let assetIndex = isVideo ? (matchIndex - 1) : (matchIndex - 1)

            guard let asset = assetMap[assetIndex] else { continue }

            let info = Task { await photosProvider.getAssetInfo(asset) }

            results.append(PhotoSearchResult(
                asset: asset,
                thumbnail: nil, // Will be loaded lazily in UI
                info: PhotoAssetInfo(
                    id: asset.localIdentifier,
                    mediaType: asset.mediaType == .video ? "video" : "photo",
                    creationDate: nil,
                    duration: asset.mediaType == .video ? formatDuration(asset.duration) : nil,
                    location: asset.location?.coordinate,
                    isFavorite: asset.isFavorite
                ),
                confidence: confidence
            ))
        }

        return results
    }

    private nonisolated func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
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
    case movies([MovieInfo])
    case movieDetail(MovieDisplayItem, String)
    case carResults([CarInfo])
    case calendarEvents([CalendarEventInfo])
    case reminders([ReminderInfo])
    case contacts([ContactInfo])
    case systemInfo(SystemInfo)
    case places([PlaceInfo], NSImage?)
    case photoResults([PhotoSearchResult], NSImage?) // Results with contact sheet preview
    case text(String)
    case error(String)
    case battery(BatteryInfo)
    case weather(WeatherInfo)
    case trip(TripInfo)
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

// MARK: - Info Models

struct MovieInfo: Identifiable {
    let id: Int
    let title: String
    let overview: String
    let posterURL: URL?
    let trailerURL: URL?
    let releaseDate: String
    let rating: Double
}

struct CarInfo: Identifiable {
    let id = UUID()
    let make: String
    let model: String
    let year: Int
    let imageURL: URL?
    var specs: [String: String] = [:]
}

struct CalendarEventInfo: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let isAllDay: Bool
}
