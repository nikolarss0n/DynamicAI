#!/usr/bin/env swift

// Simple test runner for PhotoQueryParser
// Run: swift run_tests.swift

import Foundation

// MARK: - Test Infrastructure

var passed = 0
var failed = 0
var failedTests: [(String, String)] = []

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String, file: String = #file, line: Int = #line) {
    if actual == expected {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        failedTests.append((name, "Expected \(expected), got \(actual)"))
        print("  ❌ \(name): Expected \(expected), got \(actual)")
    }
}

func assertTrue(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        failedTests.append((name, "Expected true, got false"))
        print("  ❌ \(name): Expected true, got false")
    }
}

func assertFalse(_ condition: Bool, _ name: String) {
    if !condition {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        failedTests.append((name, "Expected false, got true"))
        print("  ❌ \(name): Expected false, got true")
    }
}

func assertNotNil<T>(_ value: T?, _ name: String) {
    if value != nil {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        failedTests.append((name, "Expected non-nil, got nil"))
        print("  ❌ \(name): Expected non-nil, got nil")
    }
}

func assertNil<T>(_ value: T?, _ name: String) {
    if value == nil {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        failedTests.append((name, "Expected nil, got \(value!)"))
        print("  ❌ \(name): Expected nil, got \(value!)")
    }
}

// MARK: - PhotoQueryParser Implementation (copied for standalone testing)

struct PhotoQueryResult {
    let searchTerms: String
    let isMyPhotosRequest: Bool
    let location: String?
    let mediaType: MediaTypeFilter
    let limit: Int?
    let timePeriod: String?

    enum MediaTypeFilter: String, Equatable {
        case all = "all"
        case photo = "photo"
        case video = "video"
    }
}

struct PhotoQueryParser {

    static func detectMyPhotosIntent(_ query: String) -> Bool {
        let lowered = query.lowercased()

        // Direct patterns that clearly mean "photos/videos of me"
        let directPatterns = [
            "my photos",
            "my photo",
            "my pictures",
            "my picture",
            "my videos",
            "my video",
            "photos of me",
            "pictures of me",
            "images of me",
            "videos of me",
            "video of me",
            "photos with me",
            "pictures with me",
            "videos with me",
            "where i am",
            "where i'm",
            "i'm in",
            "i am in"
        ]

        for pattern in directPatterns {
            if lowered.contains(pattern) {
                // For "my photos/pictures/videos", ensure it's not "photos of my X"
                if pattern.hasPrefix("my photo") || pattern.hasPrefix("my picture") || pattern.hasPrefix("my video") {
                    let regex = try? NSRegularExpression(
                        pattern: "\\bmy\\s+(photos?|pictures?|images?|videos?)\\b",
                        options: .caseInsensitive
                    )
                    if let match = regex?.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) {
                        return match.range.location != NSNotFound
                    }
                    return false
                }
                return true
            }
        }

        // Pattern: "my photos/videos from/at/in"
        let myPhotoPattern = try? NSRegularExpression(
            pattern: "\\bmy\\s+(photos?|pictures?|images?|videos?)\\s+(from|at|in|of)\\b",
            options: .caseInsensitive
        )
        if let regex = myPhotoPattern,
           regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil {
            return true
        }

        return false
    }

    static func extractLocation(_ query: String) -> String? {
        let prepositions = ["from", "at", "in", "near"]
        for prep in prepositions {
            if let range = query.lowercased().range(of: "\(prep) ") {
                let afterPrep = query[range.upperBound...]
                let words = afterPrep.split(separator: " ")
                var location = [String]()
                // Skip initial "the" but don't break on it
                var skipInitialThe = true
                for word in words {
                    let w = String(word).trimmingCharacters(in: .punctuationCharacters)
                    // Skip initial "the" but continue
                    if skipInitialThe && w.lowercased() == "the" {
                        skipInitialThe = false
                        continue
                    }
                    skipInitialThe = false
                    // Stop at other common non-location words
                    if ["and", "or", "with", "where", "when", "that", "this", "a", "show", "find", "get"].contains(w.lowercased()) {
                        break
                    }
                    location.append(w)
                    if ["hotel", "resort", "beach", "restaurant"].contains(w.lowercased()) {
                        break
                    }
                    if location.count >= 4 { break }
                }
                if !location.isEmpty {
                    let result = location.joined(separator: " ")
                    // Fuzzy match for known locations
                    let corrected = fuzzyCorrect(result)
                    return corrected ?? result
                }
            }
        }
        return nil
    }

    static func fuzzyCorrect(_ input: String) -> String? {
        let knownLocations = ["Miraggio", "Greece", "Paris", "London", "New York", "Tokyo"]
        for known in knownLocations {
            let distance = levenshteinDistance(input.lowercased(), known.lowercased())
            let maxLen = max(input.count, known.count)
            let similarity = 1.0 - (Double(distance) / Double(maxLen))
            if similarity >= 0.75 && similarity < 1.0 {
                return known
            }
        }
        return nil
    }

    static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Chars = Array(s1)
        let s2Chars = Array(s2)
        let m = s1Chars.count
        let n = s2Chars.count

        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                if s1Chars[i-1] == s2Chars[j-1] {
                    dp[i][j] = dp[i-1][j-1]
                } else {
                    dp[i][j] = 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
                }
            }
        }

        return dp[m][n]
    }

    static func extractLimit(_ query: String) -> Int? {
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

    static func detectMediaType(_ query: String) -> PhotoQueryResult.MediaTypeFilter {
        let lowered = query.lowercased()

        let hasVideo = lowered.contains("video")
        let hasPhoto = lowered.contains("photo") || lowered.contains("picture") || lowered.contains("image")

        if hasVideo && !hasPhoto {
            return .video
        } else if hasPhoto && !hasVideo {
            return .photo
        }
        return .all
    }

    static func extractTimePeriod(_ query: String) -> String? {
        let lowered = query.lowercased()

        let patterns = [
            "last\\s+(week|month|year)",
            "this\\s+(week|month|year)",
            "(yesterday|today)",
            "(\\d+)\\s+days?\\s+ago",
            "(summer|winter|spring|fall|autumn)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
               let range = Range(match.range, in: lowered) {
                return String(lowered[range])
            }
        }

        return nil
    }

    static func parse(_ query: String) -> PhotoQueryResult {
        return PhotoQueryResult(
            searchTerms: query,
            isMyPhotosRequest: detectMyPhotosIntent(query),
            location: extractLocation(query),
            mediaType: detectMediaType(query),
            limit: extractLimit(query),
            timePeriod: extractTimePeriod(query)
        )
    }
}

// MARK: - Tests

print("\n" + String(repeating: "=", count: 60))
print("📸 Photo Query Parser Tests")
print(String(repeating: "=", count: 60) + "\n")

// Test 1: My Photos Detection - Direct patterns
print("🔍 Test: My Photos Intent - Direct Patterns")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("show me my photos"), "direct: show me my photos")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("show my photos from Miraggio"), "direct: show my photos from Miraggio")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("my photos from vacation"), "direct: my photos from vacation")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("find my pictures"), "direct: find my pictures")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("get my photos"), "direct: get my photos")

// Test 2: Photos of me patterns
print("\n🔍 Test: Photos of Me Patterns")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("photos of me at the beach"), "of me: at the beach")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("pictures of me in Greece"), "of me: in Greece")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("images of me"), "of me: images of me")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("photos with me"), "with me: photos with me")

// Test 3: Where I am patterns
print("\n🔍 Test: Where I Am Patterns")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("photos where I am present"), "where I am: present")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("pictures where I'm visible"), "where I'm: visible")

// Test 4: CRITICAL - Photos of my vacation (should be FALSE)
print("\n🔍 Test: Photos of My X (Should be FALSE)")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("photos of my vacation"), "NOT my photos: photos of my vacation")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("show me photos of my vacation in Miraggio"), "NOT my photos: photos of my vacation in Miraggio")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("pictures of my trip"), "NOT my photos: pictures of my trip")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("photos of my dog"), "NOT my photos: photos of my dog")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("pictures of my car"), "NOT my photos: pictures of my car")

// Test 5: General queries (no my photos intent)
print("\n🔍 Test: General Queries (Should be FALSE)")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("show me photos from Miraggio"), "general: photos from Miraggio")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("photos from Greece"), "general: photos from Greece")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("beach photos"), "general: beach photos")
assertFalse(PhotoQueryParser.detectMyPhotosIntent("vacation photos"), "general: vacation photos")

// Test 6: THE CRITICAL TEST CASES FROM THE TASK
print("\n⭐ Test: CRITICAL SCENARIOS (Main Task)")
assertFalse(
    PhotoQueryParser.detectMyPhotosIntent("show me photos of my vacation in Miraggio hotel"),
    "CRITICAL: 'photos of my vacation in Miraggio hotel' → FALSE"
)
assertTrue(
    PhotoQueryParser.detectMyPhotosIntent("show me my photos from Miraggio hotel"),
    "CRITICAL: 'my photos from Miraggio hotel' → TRUE"
)
assertTrue(
    PhotoQueryParser.detectMyPhotosIntent("show me MY photos from Miraggion hotel"),
    "CRITICAL: 'MY photos from Miraggion hotel' → TRUE"
)

// Test 7: Location Extraction
print("\n🔍 Test: Location Extraction")
assertEqual(PhotoQueryParser.extractLocation("photos from Miraggio hotel"), "Miraggio hotel", "location: from Miraggio hotel")
assertNotNil(PhotoQueryParser.extractLocation("photos at the beach"), "location: at the beach")
assertNotNil(PhotoQueryParser.extractLocation("pictures in Greece"), "location: in Greece")

// Test 8: Fuzzy location matching
print("\n🔍 Test: Fuzzy Location Matching")
assertEqual(PhotoQueryParser.extractLocation("photos from Miraggion"), "Miraggio", "fuzzy: Miraggion → Miraggio")

// Test 9: Limit Extraction
print("\n🔍 Test: Limit Extraction")
assertEqual(PhotoQueryParser.extractLimit("show me 10 photos"), 10, "limit: 10 photos")
assertEqual(PhotoQueryParser.extractLimit("5 pictures from Greece"), 5, "limit: 5 pictures")
assertEqual(PhotoQueryParser.extractLimit("last 20 videos"), 20, "limit: last 20 videos")
assertNil(PhotoQueryParser.extractLimit("show me photos"), "limit: no limit specified")

// Test 10: Media Type Detection
print("\n🔍 Test: Media Type Detection")
assertEqual(PhotoQueryParser.detectMediaType("show me videos"), .video, "media: videos")
assertEqual(PhotoQueryParser.detectMediaType("show me photos"), .photo, "media: photos")
assertEqual(PhotoQueryParser.detectMediaType("find pictures"), .photo, "media: pictures")
assertEqual(PhotoQueryParser.detectMediaType("photos and videos"), .all, "media: both")

// Test 11: Time Period Extraction
print("\n🔍 Test: Time Period Extraction")
assertNotNil(PhotoQueryParser.extractTimePeriod("photos from last week"), "time: last week")
assertNotNil(PhotoQueryParser.extractTimePeriod("pictures from last month"), "time: last month")
assertNotNil(PhotoQueryParser.extractTimePeriod("summer vacation photos"), "time: summer")
assertNil(PhotoQueryParser.extractTimePeriod("photos from Greece"), "time: no time specified")

// Test 12: Case Sensitivity
print("\n🔍 Test: Case Sensitivity")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("MY PHOTOS"), "case: MY PHOTOS")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("My Photos"), "case: My Photos")
assertTrue(PhotoQueryParser.detectMyPhotosIntent("my photos"), "case: my photos")

// Test 13: Full Parse - Complex Query 1
print("\n🔍 Test: Full Parse - Complex Queries")
let result1 = PhotoQueryParser.parse("show me photos of my vacation in Miraggio hotel")
assertFalse(result1.isMyPhotosRequest, "parse1: NOT asking for photos of user")
assertNotNil(result1.location, "parse1: has location")
assertEqual(result1.mediaType, .photo, "parse1: photo media type")

// Test 14: Full Parse - Complex Query 2
let result2 = PhotoQueryParser.parse("show me my photos from Miraggio hotel")
assertTrue(result2.isMyPhotosRequest, "parse2: IS asking for photos of user")
assertNotNil(result2.location, "parse2: has location")
assertEqual(result2.mediaType, .photo, "parse2: photo media type")

// Test 15: Full Parse - Complex Query 3
let result3 = PhotoQueryParser.parse("find 10 videos of me at the beach last summer")
assertTrue(result3.isMyPhotosRequest, "parse3: asking for videos of user")
assertEqual(result3.limit, 10, "parse3: limit is 10")
assertEqual(result3.mediaType, .video, "parse3: video media type")
assertNotNil(result3.timePeriod, "parse3: has time period")

// MARK: - Results

print("\n" + String(repeating: "=", count: 60))
let total = passed + failed
let successRate = Double(passed) / Double(total) * 100
print("📊 Test Results: \(passed)/\(total) passed (\(String(format: "%.1f", successRate))%)")
print(String(repeating: "=", count: 60))

if failed > 0 {
    print("\n❌ Failed Tests:")
    for (name, reason) in failedTests {
        print("   - \(name): \(reason)")
    }
}

if successRate >= 90.0 {
    print("\n🎉 SUCCESS! Achieved >\(90)% pass rate!")
    exit(0)
} else {
    print("\n⚠️  Need to fix \(failed) failing tests to reach 90% pass rate")
    exit(1)
}
