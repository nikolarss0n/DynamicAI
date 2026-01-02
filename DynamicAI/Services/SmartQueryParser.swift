// MARK: - Smart Query Parser
// LLM-based natural language query parsing using Groq (fast!)
// Extracts: location, time, labels, people, intent from natural language

import Foundation

/// Parsed query with structured data
struct ParsedPhotoQuery: Codable {
    /// Location for geocoding (e.g., "Miraggio hotel, Greece")
    let location: String?

    /// Hint about location type for better geocoding
    let locationHint: String?  // "hotel", "beach", "city", "landmark"

    /// Time period
    let timePeriod: TimePeriod?

    /// Visual labels to search for (e.g., ["beach", "sunset"])
    let labels: [String]?

    /// People mentioned (e.g., ["Sarah", "John"])
    let people: [String]?

    /// Whether user wants photos OF themselves
    let isMyPhotos: Bool

    /// Media type filter
    let mediaType: String  // "photo", "video", "all"

    /// Activity for video search (e.g., "jumping rope", "cooking", "playing guitar")
    let activity: String?

    /// Result limit
    let limit: Int?

    /// Original search terms (cleaned)
    let searchTerms: String
    
    struct TimePeriod: Codable {
        let description: String   // "last summer", "2024"
        let startDate: String?    // "2024-06-01" (ISO format)
        let endDate: String?      // "2024-08-31"
    }
    
    /// Check if this query can use the geohash index
    var hasLocation: Bool { 
        guard let loc = location, !loc.isEmpty else { return false }
        // Handle LLM returning "null" as string
        return loc.lowercased() != "null"
    }
    
    /// Check if this query needs label search
    var hasLabels: Bool { labels != nil && !labels!.isEmpty }
    
    /// Check if this query has time filter
    var hasTimePeriod: Bool { 
        guard let start = timePeriod?.startDate, let end = timePeriod?.endDate else { return false }
        // Handle LLM returning "null" as string
        return start.lowercased() != "null" && end.lowercased() != "null"
    }
    
    /// Check if this query has people filter
    var hasPeople: Bool { people != nil && !people!.isEmpty }

    /// Check if this query has video activity filter
    var hasActivity: Bool {
        guard let act = activity, !act.isEmpty else { return false }
        return act.lowercased() != "null"
    }
}

/// Smart query parser using LLM
struct SmartQueryParser {

    private let groq = GroqService.shared
    
    // MARK: - Parse Query
    
    /// Parse natural language query using LLM
    /// Fast with Groq (~100-200ms)
    func parse(_ query: String) async -> ParsedPhotoQuery {
        do {
            return try await parseWithLLM(query)
        } catch {
            // Fallback to regex-based parsing
            print("SmartQueryParser: LLM failed, using fallback - \(error)")
            return fallbackParse(query)
        }
    }
    
    // MARK: - LLM Parsing
    
    private func parseWithLLM(_ query: String) async throws -> ParsedPhotoQuery {
        let currentDate = ISO8601DateFormatter().string(from: Date())
        let currentYear = Calendar.current.component(.year, from: Date())
        
        let systemPrompt = """
        You are a photo/video search query parser. Extract structured information from natural language.

        IMPORTANT: Output ONLY valid JSON. Use JSON null (not string "null") for missing values.

        Schema:
        {
          "location": "place name or null if no specific place",
          "locationHint": "hotel|beach|restaurant|city|landmark|park|museum|airport" or null,
          "timePeriod": {
            "description": "original time reference",
            "startDate": "YYYY-MM-DD" or null,
            "endDate": "YYYY-MM-DD" or null
          } or null,
          "labels": ["visual labels"] or [],
          "people": ["names"] or [],
          "isMyPhotos": false,
          "mediaType": "photo|video|all",
          "activity": "specific action being performed" or null,
          "limit": number or null,
          "searchTerms": "cleaned keywords"
        }

        CRITICAL Rules:
        - isMyPhotos: true ONLY for "photos of me", "selfies", "pictures of myself" - when user wants to see THEMSELVES
        - isMyPhotos: false for "my trip", "my vacation", "my beach photos" - user wants those SUBJECT photos, not selfies!
        - people: ONLY include actual person NAMES like "Sarah", "John", "Mom". NEVER include pronouns like "I", "me", "myself", "we" - those are NOT names!
        - location: Use JSON null if no specific place mentioned. "my last trip" has no location.
        - labels: ALWAYS include relevant visual labels. "trip/vacation" → ["outdoor", "travel"]
        - timePeriod: Calculate actual dates. Current date: \(currentDate). "last summer" → June-Aug \(currentYear - 1)
        - activity: Extract specific action for video searches. "video where I jump rope" → "jumping rope"

        Label mappings:
        - trip/vacation/holiday → ["outdoor", "travel"]
        - beach/sea/ocean → ["beach", "water"]
        - sunset/sunrise → ["sunset"]
        - food/dinner/meal → ["food"]
        - party/celebration → ["party"]
        - wedding → ["wedding"]
        - mountains/hiking → ["mountain", "nature"]
        - city/urban → ["city"]
        - snow/winter/skiing → ["snow"]

        Activity examples (for video searches):
        - "video where I jump rope" → activity: "jumping rope", mediaType: "video"
        - "video of me cooking" → activity: "cooking", mediaType: "video"
        - "show me videos where I play guitar" → activity: "playing guitar", mediaType: "video"
        - "video of swimming" → activity: "swimming", mediaType: "video"
        - "dancing videos" → activity: "dancing", mediaType: "video"

        Examples:
        "photos from my last trip" → location: null, labels: ["outdoor", "travel"], isMyPhotos: false, people: [], activity: null
        "beach photos from Greece" → location: "Greece", labels: ["beach", "outdoor"], isMyPhotos: false, people: [], activity: null
        "photos of me at the beach" → labels: ["beach"], isMyPhotos: true, people: [], activity: null
        "video where I jump rope" → mediaType: "video", activity: "jumping rope", labels: [], people: []
        "video where I play golf" → mediaType: "video", activity: "playing golf", labels: ["outdoor", "sports"], people: []
        "photos with Sarah" → labels: [], people: ["Sarah"], isMyPhotos: false
        "show me videos where I cook dinner" → mediaType: "video", activity: "cooking", labels: ["food"], people: []
        """
        
        let response = try await groq.chat(message: query, systemPrompt: systemPrompt)
        
        // Clean response (remove markdown code blocks if present)
        var jsonString = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Parse JSON
        guard let data = jsonString.data(using: .utf8) else {
            throw ParserError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(ParsedPhotoQuery.self, from: data)
    }
    
    // MARK: - Fallback Parser

    /// Fallback to regex-based parsing if LLM fails
    private func fallbackParse(_ query: String) -> ParsedPhotoQuery {
        let lowered = query.lowercased()

        // Extract labels from common words
        let labels = extractLabelsFromQuery(query)

        // Detect location (simple heuristic)
        var location: String? = nil
        let locationPatterns = ["from ", "in ", "at "]
        for pattern in locationPatterns {
            if let range = lowered.range(of: pattern) {
                let after = String(lowered[range.upperBound...])
                let words = after.components(separatedBy: .whitespaces).prefix(3)
                location = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
                break
            }
        }

        // Detect time period
        var timePeriod: ParsedPhotoQuery.TimePeriod? = nil
        let currentYear = Calendar.current.component(.year, from: Date())
        
        // Map patterns to actual date ranges
        let timePatterns: [(String, String?, String?)] = [
            ("last summer", "\(currentYear - 1)-06-01", "\(currentYear - 1)-08-31"),
            ("last winter", "\(currentYear - 1)-12-01", "\(currentYear)-02-28"),
            ("last year", "\(currentYear - 1)-01-01", "\(currentYear - 1)-12-31"),
            ("this year", "\(currentYear)-01-01", nil),  // nil end = now
            ("last month", nil, nil),  // Calculate dynamically
            ("last week", nil, nil),
            ("recent", nil, nil),
            ("last trip", nil, nil),  // Can't compute exact dates
            ("last vacation", nil, nil),
            ("2024", "2024-01-01", "2024-12-31"),
            ("2023", "2023-01-01", "2023-12-31"),
            ("2022", "2022-01-01", "2022-12-31"),
        ]
        
        for (pattern, startDate, endDate) in timePatterns {
            if lowered.contains(pattern) {
                var start = startDate
                var end = endDate
                
                // Handle dynamic patterns
                if pattern == "last month" {
                    let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-01"
                    start = formatter.string(from: lastMonth)
                    formatter.dateFormat = "yyyy-MM-dd"
                    end = formatter.string(from: Date())
                } else if pattern == "last week" || pattern == "recent" {
                    let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    start = formatter.string(from: weekAgo)
                    end = formatter.string(from: Date())
                }
                
                timePeriod = ParsedPhotoQuery.TimePeriod(
                    description: pattern,
                    startDate: start,
                    endDate: end
                )
                break
            }
        }

        // Detect media type
        var mediaType = "all"
        if lowered.contains("video") { mediaType = "video" }
        else if lowered.contains("photo") || lowered.contains("picture") { mediaType = "photo" }

        // Detect limit
        var limit: Int? = nil
        if let match = try? NSRegularExpression(pattern: "(\\d+)\\s*(?:photos?|videos?|pictures?)", options: .caseInsensitive)
            .firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            limit = Int(query[range])
        }

        // Detect "my photos" intent - ONLY for explicit "photos of me" requests
        // "my trip" or "my vacation" should NOT trigger this - user wants trip photos, not selfies
        let selfiePatterns = [
            "photo of me", "photos of me", "picture of me", "pictures of me",
            "selfie", "my face", "me in", "myself"
        ]
        let isMyPhotos = selfiePatterns.contains { lowered.contains($0) }

        // Extract activity for video searches
        var activity: String? = nil
        if mediaType == "video" {
            activity = extractActivityFromQuery(query)
        }

        return ParsedPhotoQuery(
            location: location,
            locationHint: nil,
            timePeriod: timePeriod,
            labels: labels.isEmpty ? nil : labels,
            people: nil,
            isMyPhotos: isMyPhotos,
            mediaType: mediaType,
            activity: activity,
            limit: limit,
            searchTerms: query
        )
    }

    /// Extract activity from video query (fallback)
    private func extractActivityFromQuery(_ query: String) -> String? {
        let lowered = query.lowercased()

        // Common activity patterns
        let activityPatterns: [(pattern: String, activity: String)] = [
            // Exercise
            ("jump rope", "jumping rope"),
            ("jumping rope", "jumping rope"),
            ("skip rope", "jumping rope"),
            ("skipping rope", "jumping rope"),
            ("running", "running"),
            ("jogging", "running"),
            ("walking", "walking"),
            ("swimming", "swimming"),
            ("cycling", "cycling"),
            ("biking", "cycling"),
            ("yoga", "yoga"),
            ("stretching", "stretching"),
            ("workout", "exercising"),
            ("exercise", "exercising"),
            ("pushup", "doing pushups"),
            ("push-up", "doing pushups"),
            ("squat", "doing squats"),

            // Music
            ("play guitar", "playing guitar"),
            ("playing guitar", "playing guitar"),
            ("play piano", "playing piano"),
            ("playing piano", "playing piano"),
            ("play drums", "playing drums"),
            ("playing drums", "playing drums"),
            ("singing", "singing"),
            ("sing", "singing"),

            // Cooking
            ("cooking", "cooking"),
            ("cook", "cooking"),
            ("baking", "baking"),
            ("bake", "baking"),

            // General activities
            ("dancing", "dancing"),
            ("dance", "dancing"),
            ("reading", "reading"),
            ("drawing", "drawing"),
            ("painting", "painting"),
            ("cleaning", "cleaning"),
            ("gardening", "gardening"),
            ("eating", "eating"),
            ("talking", "talking"),
            ("laughing", "laughing"),
        ]

        for (pattern, activity) in activityPatterns {
            if lowered.contains(pattern) {
                return activity
            }
        }

        // Try to extract activity from "where I [verb]" or "of me [verb]ing" patterns
        let verbPatterns = [
            "where i ", "where we ", "of me ", "of us "
        ]

        for prefix in verbPatterns {
            if let range = lowered.range(of: prefix) {
                let afterPrefix = String(lowered[range.upperBound...])
                let words = afterPrefix.components(separatedBy: .whitespaces).prefix(3)
                if let firstWord = words.first, !firstWord.isEmpty {
                    // Return as the activity (e.g., "jump", "cook", "dance")
                    return words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
                }
            }
        }

        return nil
    }
    
    /// Extract labels from query using keyword matching (fallback)
    private func extractLabelsFromQuery(_ query: String) -> [String] {
        let lowered = query.lowercased()
        var labels: [String] = []
        
        let labelKeywords: [String: [String]] = [
            "beach": ["beach", "sea", "ocean", "shore", "coast"],
            "sunset": ["sunset", "sunrise", "golden hour", "dusk", "dawn"],
            "food": ["food", "meal", "dinner", "lunch", "breakfast", "restaurant", "eating"],
            "party": ["party", "celebration", "birthday"],
            "wedding": ["wedding", "marriage", "bride", "groom"],
            "mountain": ["mountain", "hiking", "trail", "peak"],
            "snow": ["snow", "winter", "skiing", "snowboard"],
            "city": ["city", "urban", "downtown", "street"],
            "nature": ["nature", "forest", "tree", "garden", "park"],
            "water": ["water", "pool", "lake", "river", "swimming"],
            "night": ["night", "evening", "dark"],
            "outdoor": ["outdoor", "outside", "vacation", "trip", "travel"],
            "indoor": ["indoor", "inside", "home", "room"],
            "dog": ["dog", "puppy", "canine"],
            "cat": ["cat", "kitten", "kitty"],
            "person": ["portrait", "selfie", "face"],
        ]
        
        for (label, keywords) in labelKeywords {
            for keyword in keywords {
                if lowered.contains(keyword) {
                    labels.append(label)
                    break
                }
            }
        }
        
        return Array(Set(labels))  // Remove duplicates
    }
    
    // MARK: - Errors
    
    enum ParserError: Error {
        case invalidResponse
        case llmError(String)
    }
}

// MARK: - Date Helpers

extension ParsedPhotoQuery.TimePeriod {
    
    /// Convert to DateInterval for PHFetchOptions
    func toDateInterval() -> DateInterval? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        
        guard let startStr = startDate,
              let endStr = endDate,
              let start = formatter.date(from: startStr),
              let end = formatter.date(from: endStr) else {
            return nil
        }
        
        // Add one day to end to make it inclusive
        let inclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end
        
        return DateInterval(start: start, end: inclusiveEnd)
    }
}
