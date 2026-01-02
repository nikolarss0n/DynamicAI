// MARK: - Video Index
// Activity-based video search using Groq Vision + Whisper
// Extracts frames at 25%, 45%, 75% + audio transcription
// Search: "jump rope", "cooking", "playing guitar"

import Foundation
import Photos
import AVFoundation
import AppKit
import Vision

/// Video activity index using Groq Vision + Whisper
actor VideoIndex {

    // MARK: - Storage

    /// assetId → VideoActivityInfo
    private var index: [String: VideoActivityInfo] = [:]

    /// activity keyword → [assetLocalIdentifier]
    private var activityIndex: [String: Set<String>] = [:]

    /// visual label → [assetLocalIdentifier] (same as LabelIndex for photos)
    private var labelIndex: [String: Set<String>] = [:]

    /// Track indexed assets
    private var indexedAssets: Set<String> = []

    // MARK: - Configuration

    private let framePositions: [Double] = [0.25, 0.50, 0.75]  // 3 frames for better activity coverage
    private let storageURL: URL

    // Vision classification settings (same as LabelIndex)
    private let minConfidence: Float = 0.4
    private let maxLabelsPerFrame: Int = 10

    // MARK: - State

    private(set) var isIndexing = false
    private var shouldCancel = false

    // MARK: - Singleton

    static let shared = VideoIndex()

    // MARK: - Initialization

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DynamicAI", isDirectory: true)
        self.storageURL = dir.appendingPathComponent("video_index.json")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Load existing index on startup
        loadFromDisk()
    }

    // MARK: - Build Index

    /// Build video activity index using Groq Vision + Whisper
    /// Analyzes frames and audio to describe video activities
    func buildIndex(
        limit: Int? = nil,
        onProgress: @escaping (Int, Int, String) -> Void
    ) async -> VideoIndexStats {
        guard !isIndexing else {
            return VideoIndexStats(total: 0, indexed: 0, skipped: 0, failed: 0, timeSeconds: 0, cancelled: true)
        }

        isIndexing = true
        shouldCancel = false

        let start = CFAbsoluteTimeGetCurrent()

        // Load existing index
        loadFromDisk()

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let allAssets = PHAsset.fetchAssets(with: .video, options: fetchOptions)
        let total = limit ?? allAssets.count
        var indexed = 0
        var skipped = 0
        var failed = 0

        for i in 0..<min(total, allAssets.count) {
            if shouldCancel { break }

            let asset = allAssets.object(at: i)
            let assetId = asset.localIdentifier

            // Skip if already indexed
            if indexedAssets.contains(assetId) {
                skipped += 1
                continue
            }

            onProgress(i, total, "Analyzing video...")

            do {
                // Analyze video
                let info = try await analyzeVideo(asset: asset)

                // Store in index
                index[assetId] = info
                indexedAssets.insert(assetId)

                // Index by activity keywords
                for keyword in info.keywords {
                    let normalized = keyword.lowercased()
                    if activityIndex[normalized] == nil {
                        activityIndex[normalized] = []
                    }
                    activityIndex[normalized]?.insert(assetId)
                }

                // Index by visual labels (like LabelIndex does for photos)
                for label in info.visualLabels {
                    let normalized = normalizeLabel(label)
                    if labelIndex[normalized] == nil {
                        labelIndex[normalized] = []
                    }
                    labelIndex[normalized]?.insert(assetId)
                }

                // Index transcript words for audio-based search
                if let transcript = info.audioTranscript {
                    let transcriptWords = extractSearchableWords(from: transcript)
                    for word in transcriptWords {
                        if activityIndex[word] == nil {
                            activityIndex[word] = []
                        }
                        activityIndex[word]?.insert(assetId)
                    }
                }

                indexed += 1
                onProgress(i, total, info.activitySummary)

            } catch {
                log.error(.video, "Failed to analyze video", details: ["error": error.localizedDescription])
                failed += 1
            }

            // Save periodically
            if indexed % 10 == 0 {
                saveToDisk()
            }
        }

        saveToDisk()
        isIndexing = false

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        return VideoIndexStats(
            total: total,
            indexed: indexed,
            skipped: skipped,
            failed: failed,
            timeSeconds: elapsed,
            cancelled: shouldCancel
        )
    }

    /// Cancel ongoing indexing
    func cancelIndexing() {
        shouldCancel = true
    }

    // MARK: - Video Analysis

    /// Analyze a single video: extract frames + transcribe audio (no Groq Vision - local only + Whisper)
    private func analyzeVideo(asset: PHAsset) async throws -> VideoActivityInfo {
        guard asset.mediaType == .video else {
            throw VideoIndexError.notAVideo
        }

        // Get AVAsset
        guard let avAsset = await getAVAsset(for: asset) else {
            throw VideoIndexError.couldNotLoadVideo
        }

        let duration = CMTimeGetSeconds(avAsset.duration)

        log.info(.video, "Analyzing video", details: [
            "duration": String(format: "%.1fs", duration),
            "id": String(asset.localIdentifier.prefix(20))
        ])

        // Extract frames at key positions
        let frames = try await extractFrames(from: avAsset, duration: duration)

        // Classify frames with Apple Vision (on-device, like photos)
        let visualLabels = classifyFrames(frames)

        log.debug(.video, "Vision classified frames", details: [
            "labels": visualLabels.prefix(5).joined(separator: ", ")
        ])

        // Transcribe audio (get middle 30s segment)
        var audioTranscript: String? = nil
        do {
            let transcription = try await GroqService.shared.transcribeVideoAudio(asset: asset, segmentDuration: 30)
            if !transcription.isEmpty {
                audioTranscript = transcription.text
            }
        } catch {
            log.warning(.video, "Audio transcription failed", details: ["error": error.localizedDescription])
            // Continue without audio - labels only
        }

        // Use Groq Vision to describe activity (re-enabled, using single frame for speed)
        var summary: String
        do {
            let prompt = """
            This image shows 3 frames from a video, arranged left to right in time order.
            Describe the main activity happening in 1-2 sentences.
            Focus on: What actions are being performed? What is the person doing?
            Examples: "Person jumping rope outdoors", "Cooking pasta in kitchen", "Playing guitar"
            Be specific about the activity, not just the scene.
            """
            summary = try await GroqService.shared.analyzeVideo(
                frames: frames,
                prompt: prompt,
                audioContext: audioTranscript
            )
            log.debug(.video, "Groq Vision activity", details: ["summary": String(summary.prefix(80))])
        } catch {
            // Fallback to label-based summary if Groq Vision fails
            log.warning(.video, "Groq Vision failed, using labels", details: ["error": error.localizedDescription])
            summary = buildActivitySummary(labels: visualLabels, transcript: audioTranscript)
        }

        // Extract keywords from Groq Vision summary, transcript, and labels
        var keywords = extractKeywords(from: summary)
        keywords.append(contentsOf: extractKeywords(from: audioTranscript ?? ""))
        keywords.append(contentsOf: visualLabels.map { $0.lowercased() })
        keywords = Array(Set(keywords))  // Dedupe

        return VideoActivityInfo(
            assetId: asset.localIdentifier,
            activitySummary: summary,
            audioTranscript: audioTranscript,
            keywords: keywords,
            visualLabels: visualLabels,
            duration: duration,
            indexedAt: Date()
        )
    }

    /// Build activity summary from labels and transcript (replaces Groq Vision)
    private func buildActivitySummary(labels: [String], transcript: String?) -> String {
        var parts: [String] = []

        // Summarize visual content from labels
        let significantLabels = labels.prefix(5).map { $0.replacingOccurrences(of: "_", with: " ") }
        if !significantLabels.isEmpty {
            parts.append("Visual: \(significantLabels.joined(separator: ", "))")
        }

        // Include transcript snippet
        if let transcript = transcript, !transcript.isEmpty {
            let snippet = String(transcript.prefix(100))
            parts.append("Audio: \"\(snippet)\"")
        }

        return parts.isEmpty ? "No description available" : parts.joined(separator: " | ")
    }

    /// Extract searchable words from text (for transcript indexing)
    private func extractSearchableWords(from text: String) -> [String] {
        // Common stop words to skip
        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "is", "it", "this", "that", "was", "were",
            "be", "been", "being", "have", "has", "had", "do", "does", "did",
            "will", "would", "could", "should", "may", "might", "must", "can",
            "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them",
            "my", "your", "his", "its", "our", "their", "what", "which", "who",
            "not", "no", "yes", "just", "so", "very", "really", "like", "get", "got"
        ]

        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    /// Extract frames at configured positions (25%, 50%, 75%)
    private func extractFrames(from asset: AVAsset, duration: Double) async throws -> [NSImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)  // Smaller for faster API transfer
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [NSImage] = []

        for position in framePositions {
            let time = CMTime(seconds: duration * position, preferredTimescale: 600)

            do {
                let (cgImage, _) = try await generator.image(at: time)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                frames.append(nsImage)

                log.debug(.video, "Extracted frame", details: [
                    "position": String(format: "%.0f%%", position * 100),
                    "time": String(format: "%.1fs", duration * position)
                ])
            } catch {
                log.warning(.video, "Frame extraction failed", details: [
                    "position": position,
                    "error": error.localizedDescription
                ])
            }
        }

        guard !frames.isEmpty else {
            throw VideoIndexError.frameExtractionFailed
        }

        return frames
    }

    /// Classify frames using Apple Vision (on-device, same as LabelIndex)
    private func classifyFrames(_ frames: [NSImage]) -> [String] {
        var allLabels = Set<String>()

        for frame in frames {
            guard let cgImage = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }

            var frameLabels: [String] = []

            let request = VNClassifyImageRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNClassificationObservation] else {
                    return
                }

                frameLabels = results
                    .filter { $0.confidence >= self.minConfidence }
                    .prefix(self.maxLabelsPerFrame)
                    .map { $0.identifier }
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])

            allLabels.formUnion(frameLabels)
        }

        return Array(allLabels)
    }

    /// Normalize label for consistent indexing (same logic as LabelIndex)
    private func normalizeLabel(_ label: String) -> String {
        let lowered = label.lowercased().trimmingCharacters(in: .whitespaces)

        // Same synonyms as LabelIndex for consistency
        let synonyms: [String: String] = [
            "seashore": "beach",
            "coast": "beach",
            "seaside": "beach",
            "ocean": "beach",
            "sea": "beach",
            "sundown": "sunset",
            "sunrise": "sunset",
            "dusk": "sunset",
            "dawn": "sunset",
            "meal": "food",
            "dish": "food",
            "restaurant": "food",
            "dinner": "food",
            "lunch": "food",
            "canine": "dog",
            "feline": "cat",
            "kitty": "cat",
            "puppy": "dog",
            "automobile": "car",
            "vehicle": "car",
            "building": "architecture",
            "structure": "architecture",
            "city": "architecture",
            "urban": "architecture",
        ]

        return synonyms[lowered] ?? lowered
    }

    /// Extract searchable keywords from activity description
    private func extractKeywords(from description: String) -> [String] {
        // Common activity-related words to look for
        let activityPatterns = [
            // Sports/Exercise
            "jumping", "running", "walking", "swimming", "cycling", "yoga", "stretching",
            "exercising", "workout", "training", "lifting", "pushup", "squat", "plank",
            "jump rope", "jumping rope", "skipping rope",

            // Music
            "playing", "guitar", "piano", "drums", "singing", "music", "instrument",

            // Cooking
            "cooking", "baking", "preparing", "cutting", "chopping", "stirring",
            "grilling", "frying", "boiling",

            // Activities
            "dancing", "reading", "writing", "typing", "drawing", "painting",
            "cleaning", "washing", "ironing", "gardening",

            // Social
            "talking", "laughing", "eating", "drinking", "meeting", "party",

            // Outdoor
            "hiking", "climbing", "camping", "fishing", "skiing", "snowboarding",
            "surfing", "skating", "biking"
        ]

        var keywords: [String] = []
        let lowercased = description.lowercased()

        for pattern in activityPatterns {
            if lowercased.contains(pattern) {
                keywords.append(pattern)
            }
        }

        // Also add individual significant words from the description
        let words = lowercased.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
            .filter { !["this", "that", "with", "from", "have", "been", "being", "person", "video", "shows", "appears", "seems"].contains($0) }

        for word in words {
            if !keywords.contains(word) {
                keywords.append(word)
            }
        }

        return keywords
    }

    // MARK: - Search

    /// Activity synonyms for better matching
    private let activitySynonyms: [String: [String]] = [
        // Jump rope variations
        "jumping rope": ["jump rope", "skipping rope", "skip rope", "rope jumping", "rope skipping"],
        "jump rope": ["jumping rope", "skipping rope", "skip rope", "rope jumping", "rope skipping"],
        "skipping rope": ["jump rope", "jumping rope", "skip rope", "rope jumping", "rope skipping"],

        // Exercise
        "running": ["jogging", "run", "jog"],
        "jogging": ["running", "run", "jog"],
        "exercising": ["workout", "working out", "exercise", "training"],
        "workout": ["exercising", "working out", "exercise", "training"],

        // Music
        "playing guitar": ["guitar playing", "guitar", "strumming"],
        "playing piano": ["piano playing", "piano", "keyboard"],

        // Cooking
        "cooking": ["cook", "preparing food", "making food", "kitchen"],

        // Dance
        "dancing": ["dance", "moves"],
    ]

    /// Expand search terms with synonyms
    private func expandActivityTerms(_ activity: String) -> Set<String> {
        var expanded = Set<String>()
        let lowered = activity.lowercased()

        // Add original
        expanded.insert(lowered)

        // Add individual words
        let words = lowered.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 }
        expanded.formUnion(words)

        // Check for synonym matches
        for (key, synonyms) in activitySynonyms {
            if lowered.contains(key) || synonyms.contains(where: { lowered.contains($0) }) {
                expanded.insert(key)
                expanded.formUnion(synonyms)
                // Also add individual words from synonyms
                for syn in synonyms {
                    expanded.formUnion(syn.components(separatedBy: .whitespaces))
                }
            }
        }

        return expanded
    }

    /// Search videos by activity description
    /// Returns asset IDs of matching videos
    func search(activity: String) async -> [String] {
        // Expand search terms with synonyms
        let searchTerms = expandActivityTerms(activity)

        log.debug(.video, "Activity search", details: [
            "query": activity,
            "expanded": searchTerms.prefix(10).joined(separator: ", "),
            "indexSize": activityIndex.count
        ])

        var matches = Set<String>()

        // Check activity index for direct matches
        for term in searchTerms {
            if let assetIds = activityIndex[term] {
                matches.formUnion(assetIds)
            }

            // Also check for partial matches in keywords
            for (keyword, assetIds) in activityIndex {
                if keyword.contains(term) || term.contains(keyword) {
                    matches.formUnion(assetIds)
                }
            }
        }

        // If no index matches, search activity summaries directly
        if matches.isEmpty {
            for (assetId, info) in index {
                let summary = info.activitySummary.lowercased()
                let transcript = info.audioTranscript?.lowercased() ?? ""

                for term in searchTerms {
                    if summary.contains(term) || transcript.contains(term) {
                        matches.insert(assetId)
                        break
                    }
                }
            }
        }

        log.debug(.video, "Activity search results (before LLM filter)", details: ["matches": matches.count])

        // If we have multiple matches, use LLM to filter for semantic relevance
        if matches.count > 1 {
            let refinedMatches = await refineWithLLM(activity: activity, candidates: Array(matches))
            if !refinedMatches.isEmpty {
                log.info(.video, "LLM refined \(matches.count) → \(refinedMatches.count) matches")
                return refinedMatches
            }
            // If LLM filtering failed or returned empty, fall back to original matches
        }

        return Array(matches)
    }

    /// Use LLM to filter candidates for semantic relevance
    private func refineWithLLM(activity: String, candidates: [String]) async -> [String] {
        // Build numbered list of descriptions
        var descriptions: [(index: Int, assetId: String, summary: String)] = []
        for (idx, assetId) in candidates.enumerated() {
            if let info = index[assetId] {
                descriptions.append((idx + 1, assetId, info.activitySummary))
            }
        }
        
        guard !descriptions.isEmpty else { return [] }
        
        let listText = descriptions.map { "[\($0.index)] \($0.summary)" }.joined(separator: "\n")
        
        let prompt = """
        I'm searching for videos of: "\(activity)"
        
        Here are video descriptions:
        \(listText)
        
        Return ONLY the numbers (in brackets) of videos that actually show "\(activity)".
        Exclude videos that merely contain similar words but show different activities.
        For example, "baby in jumper" is NOT "jumping rope".
        
        Reply with just the numbers separated by commas, like: 1, 4, 7
        If none match, reply: none
        """
        
        do {
            let response = try await GroqService.shared.chat(message: prompt)
            print("[VideoIndex] LLM filter response: \(response)")
            
            // Parse response for numbers
            if response.lowercased().contains("none") {
                return []
            }
            
            // Extract numbers from response
            let numbers = response.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }
                .filter { $0 >= 1 && $0 <= descriptions.count }
            
            // Map back to asset IDs
            var refined: [String] = []
            for num in numbers {
                if let match = descriptions.first(where: { $0.index == num }) {
                    refined.append(match.assetId)
                }
            }
            
            return refined
            
        } catch {
            log.error(.video, "LLM refinement failed", details: ["error": error.localizedDescription])
            return []  // Fall back to original matches
        }
    }


    /// LLM-first video search - no keyword matching, just semantic understanding
    /// Send raw user query + video descriptions to LLM, let it pick matches
    func searchWithLLM(query: String) async -> [String] {
        // Get all indexed videos
        guard !index.isEmpty else {
            log.info(.video, "No indexed videos for LLM search")
            return []
        }
        
        // Build numbered list of video descriptions
        var descriptions: [(index: Int, assetId: String, summary: String)] = []
        for (idx, (assetId, info)) in index.enumerated() {
            descriptions.append((idx + 1, assetId, info.activitySummary))
        }
        
        let listText = descriptions.map { "[\($0.index)] \($0.summary)" }.joined(separator: "\n")
        
        let prompt = """
        User is searching their video library with: "\(query)"
        
        Here are all indexed videos with their descriptions:
        \(listText)
        
        Which videos match what the user is looking for?
        
        IMPORTANT:
        - Consider semantic meaning, not just keyword matches
        - "baby in jumper seat" is NOT "jumping rope"
        - "playing golf" is about golf, not other activities
        - Match the actual activity/content the user wants
        
        Reply with ONLY the numbers (in brackets) that match, separated by commas.
        Example: 1, 4, 7
        If none match, reply: none
        """
        
        do {
            let response = try await GroqService.shared.chat(message: prompt)
            log.info(.video, "LLM search response: \(response)")
            
            // Parse response
            if response.lowercased().contains("none") {
                return []
            }
            
            // Extract numbers from response
            let numbers = response.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }
                .filter { $0 >= 1 && $0 <= descriptions.count }
            
            // Map back to asset IDs
            var results: [String] = []
            for num in numbers {
                if let match = descriptions.first(where: { $0.index == num }) {
                    results.append(match.assetId)
                }
            }
            
            log.info(.video, "LLM search found \(results.count) matches for '\(query)'")
            return results
            
        } catch {
            log.error(.video, "LLM search failed", details: ["error": error.localizedDescription])
            // Fall back to keyword-based search
            return await search(activity: query)
        }
    }

    /// Search videos by visual labels (like LabelIndex.search for photos)
    /// Returns asset IDs of videos with ANY of the specified labels
    func searchByLabels(_ labels: [String]) -> [String] {
        var matches = Set<String>()

        for label in labels {
            let normalized = normalizeLabel(label)
            if let assetIds = labelIndex[normalized] {
                matches.formUnion(assetIds)
            }
        }

        return Array(matches)
    }

    /// Search videos by ALL labels (intersection)
    func searchByAllLabels(_ labels: [String]) -> [String] {
        guard !labels.isEmpty else { return [] }

        var result: Set<String>? = nil

        for label in labels {
            let normalized = normalizeLabel(label)
            guard let assetIds = labelIndex[normalized] else {
                return []  // Label not found
            }

            if result == nil {
                result = assetIds
            } else {
                result = result?.intersection(assetIds)
            }
        }

        return Array(result ?? [])
    }

    /// Get all visual labels for a video
    func getVisualLabels(for assetId: String) -> [String] {
        return index[assetId]?.visualLabels ?? []
    }

    /// Get all available visual labels with counts
    func getAllVisualLabels() -> [(label: String, count: Int)] {
        return labelIndex
            .map { (label: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    /// Get activity info for a specific video
    func getActivityInfo(for assetId: String) -> VideoActivityInfo? {
        return index[assetId]
    }

    /// Get all indexed activities for debugging/display
    func getAllActivities() -> [(assetId: String, summary: String)] {
        return index.map { ($0.key, $0.value.activitySummary) }
    }

    // MARK: - AVAsset Loading

    private func getAVAsset(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let data = VideoIndexData(
            index: index,
            activityIndex: activityIndex.mapValues { Array($0) },
            labelIndex: labelIndex.mapValues { Array($0) },
            indexedAssets: Array(indexedAssets)
        )

        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: storageURL)
            log.debug(.video, "Video index saved", details: [
                "videos": indexedAssets.count,
                "labels": labelIndex.count
            ])
        } catch {
            log.error(.video, "Failed to save video index", details: ["error": error.localizedDescription])
        }
    }

    func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(VideoIndexData.self, from: data) else {
            return
        }

        index = decoded.index
        activityIndex = decoded.activityIndex.mapValues { Set($0) }
        labelIndex = decoded.labelIndex.mapValues { Set($0) }
        indexedAssets = Set(decoded.indexedAssets)

        log.info(.video, "Video index loaded", details: [
            "videos": indexedAssets.count,
            "labels": labelIndex.count
        ])
    }

    /// Clear all index data
    func clear() {
        index = [:]
        activityIndex = [:]
        labelIndex = [:]
        indexedAssets = []
        try? FileManager.default.removeItem(at: storageURL)
    }

    // MARK: - Stats

    var stats: (videosIndexed: Int, uniqueActivities: Int, uniqueLabels: Int, isLoaded: Bool) {
        (indexedAssets.count, activityIndex.count, labelIndex.count, !index.isEmpty)
    }

    /// Debug: print all indexed activities
    func debugPrintIndex() {
        log.info(.video, "=== Video Index Debug ===")
        log.info(.video, "Indexed videos: \(indexedAssets.count)")
        log.info(.video, "Activity keywords: \(activityIndex.count)")
        log.info(.video, "Visual labels: \(labelIndex.count)")

        for (assetId, info) in index {
            log.info(.video, "Video: \(String(assetId.prefix(20)))", details: [
                "summary": String(info.activitySummary.prefix(80)),
                "keywords": info.keywords.prefix(5).joined(separator: ", "),
                "labels": info.visualLabels.prefix(5).joined(separator: ", ")
            ])
        }
    }

    /// Test Groq Vision on a video - extracts frames and sends to Groq
    /// Returns what Groq Vision sees in the video
    func testGroqVision(videoIndex: Int = 0) async -> String {
        log.section("Testing Groq Vision")

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let allAssets = PHAsset.fetchAssets(with: .video, options: fetchOptions)

        guard videoIndex < allAssets.count else {
            return "No video at index \(videoIndex)"
        }

        let asset = allAssets.object(at: videoIndex)

        guard let avAsset = await getAVAsset(for: asset) else {
            return "Could not load video"
        }

        let duration = CMTimeGetSeconds(avAsset.duration)

        log.info(.video, "Testing video", details: [
            "index": videoIndex,
            "duration": String(format: "%.1fs", duration),
            "id": String(asset.localIdentifier.prefix(20))
        ])

        // Extract frames
        do {
            let frames = try await extractFrames(from: avAsset, duration: duration)
            log.info(.video, "Extracted \(frames.count) frames for test")

            // Test with Groq Vision
            let prompt = """
            This image shows 3 frames from a video, arranged left to right in time order.
            Describe the main activity happening in 1-2 sentences.
            Focus on: What actions are being performed? What is the person doing?
            Examples: "Person jumping rope outdoors", "Cooking pasta in kitchen", "Playing guitar"
            Be specific about the activity, not just the scene.
            """

            let result = try await GroqService.shared.analyzeVideo(
                frames: frames,
                prompt: prompt,
                audioContext: nil
            )

            log.success(.video, "🧪 Groq Vision test result", details: ["result": result])
            return result

        } catch {
            log.error(.video, "Test failed", details: ["error": error.localizedDescription])
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Test body pose + text LLM approach (cheaper/faster than vision)
    /// Extracts skeleton data locally, sends coordinates to text model
    func testPoseAnalysis(videoIndex: Int = 0) async -> String {
        log.section("Testing Pose Analysis")

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let allAssets = PHAsset.fetchAssets(with: .video, options: fetchOptions)

        guard videoIndex < allAssets.count else {
            return "No video at index \(videoIndex)"
        }

        let asset = allAssets.object(at: videoIndex)

        guard let avAsset = await getAVAsset(for: asset) else {
            return "Could not load video"
        }

        let duration = CMTimeGetSeconds(avAsset.duration)

        log.info(.video, "Testing pose analysis", details: [
            "index": videoIndex,
            "duration": String(format: "%.1fs", duration)
        ])

        do {
            // Extract more frames for pose analysis (need temporal pattern)
            let frames = try await extractFramesForPose(from: avAsset, duration: duration, count: 8)
            log.info(.video, "Extracted \(frames.count) frames for pose analysis")

            // Extract poses from each frame
            var poseDescriptions: [String] = []
            for (i, frame) in frames.enumerated() {
                let time = duration * Double(i) / Double(frames.count)
                if let poseDesc = extractPoseDescription(from: frame, frameIndex: i, time: time) {
                    poseDescriptions.append(poseDesc)
                    log.debug(.video, "Frame \(i) pose extracted")
                } else {
                    poseDescriptions.append("Frame \(i) (t=\(String(format: "%.1fs", time))): No person detected")
                }
            }

            let poseData = poseDescriptions.joined(separator: "\n")
            log.info(.video, "Pose data", details: ["size": "\(poseData.count) chars"])

            // Send to text LLM
            let prompt = """
            I have body pose data from a video showing joint positions over time.
            Each frame shows: head, shoulders, elbows, wrists, hips, knees, ankles positions.
            Y values: 0 = bottom, 1 = top of frame.

            \(poseData)

            Based on the body positions and movement pattern across frames:
            1. What physical activity is the person doing?
            2. Be specific (e.g., "jumping rope", "doing jumping jacks", "running", "dancing")

            Answer in one sentence.
            """

            let result = try await GroqService.shared.chat(message: prompt)

            log.success(.video, "🧪 Pose analysis result", details: ["result": result])
            return "POSE→LLM: \(result)"

        } catch {
            log.error(.video, "Pose test failed", details: ["error": error.localizedDescription])
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Extract more frames for pose analysis
    private func extractFramesForPose(from asset: AVAsset, duration: Double, count: Int) async throws -> [NSImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)  // Smaller for pose
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [NSImage] = []

        for i in 0..<count {
            let position = Double(i + 1) / Double(count + 1)  // Evenly spaced
            let time = CMTime(seconds: duration * position, preferredTimescale: 600)

            do {
                let (cgImage, _) = try await generator.image(at: time)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                frames.append(nsImage)
            } catch {
                // Skip failed frames
            }
        }

        guard !frames.isEmpty else {
            throw VideoIndexError.frameExtractionFailed
        }

        return frames
    }

    /// Extract human body pose from frame and format as text
    private func extractPoseDescription(from image: NSImage, frameIndex: Int, time: Double) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        var result: String? = nil

        let request = VNDetectHumanBodyPoseRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNHumanBodyPoseObservation],
                  let pose = observations.first else {
                return
            }

            // Extract key joint positions
            var joints: [String] = []

            let keyJoints: [(VNHumanBodyPoseObservation.JointName, String)] = [
                (.nose, "head"),
                (.leftShoulder, "L_shoulder"),
                (.rightShoulder, "R_shoulder"),
                (.leftElbow, "L_elbow"),
                (.rightElbow, "R_elbow"),
                (.leftWrist, "L_wrist"),
                (.rightWrist, "R_wrist"),
                (.leftHip, "L_hip"),
                (.rightHip, "R_hip"),
                (.leftKnee, "L_knee"),
                (.rightKnee, "R_knee"),
                (.leftAnkle, "L_ankle"),
                (.rightAnkle, "R_ankle")
            ]

            for (jointName, label) in keyJoints {
                if let point = try? pose.recognizedPoint(jointName), point.confidence > 0.3 {
                    joints.append("\(label):(x=\(String(format: "%.2f", point.location.x)),y=\(String(format: "%.2f", point.location.y)))")
                }
            }

            if !joints.isEmpty {
                result = "Frame \(frameIndex) (t=\(String(format: "%.1fs", time))): \(joints.joined(separator: " "))"
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        return result
    }
}

// MARK: - Data Models

struct VideoActivityInfo: Codable {
    let assetId: String
    let activitySummary: String
    let audioTranscript: String?
    let keywords: [String]
    let visualLabels: [String]  // Apple Vision labels from frames (beach, outdoor, person, etc.)
    let duration: Double
    let indexedAt: Date

    // Backward compatible decoding for old index data without visualLabels
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try container.decode(String.self, forKey: .assetId)
        activitySummary = try container.decode(String.self, forKey: .activitySummary)
        audioTranscript = try container.decodeIfPresent(String.self, forKey: .audioTranscript)
        keywords = try container.decode([String].self, forKey: .keywords)
        visualLabels = try container.decodeIfPresent([String].self, forKey: .visualLabels) ?? []
        duration = try container.decode(Double.self, forKey: .duration)
        indexedAt = try container.decode(Date.self, forKey: .indexedAt)
    }

    init(assetId: String, activitySummary: String, audioTranscript: String?, keywords: [String], visualLabels: [String], duration: Double, indexedAt: Date) {
        self.assetId = assetId
        self.activitySummary = activitySummary
        self.audioTranscript = audioTranscript
        self.keywords = keywords
        self.visualLabels = visualLabels
        self.duration = duration
        self.indexedAt = indexedAt
    }
}

struct VideoIndexData: Codable {
    let index: [String: VideoActivityInfo]
    let activityIndex: [String: [String]]
    let labelIndex: [String: [String]]  // Visual labels like LabelIndex
    let indexedAssets: [String]

    // Backward compatible decoding for old index data without labelIndex
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode([String: VideoActivityInfo].self, forKey: .index)
        activityIndex = try container.decode([String: [String]].self, forKey: .activityIndex)
        labelIndex = try container.decodeIfPresent([String: [String]].self, forKey: .labelIndex) ?? [:]
        indexedAssets = try container.decode([String].self, forKey: .indexedAssets)
    }

    init(index: [String: VideoActivityInfo], activityIndex: [String: [String]], labelIndex: [String: [String]], indexedAssets: [String]) {
        self.index = index
        self.activityIndex = activityIndex
        self.labelIndex = labelIndex
        self.indexedAssets = indexedAssets
    }
}

struct VideoIndexStats {
    let total: Int
    let indexed: Int
    let skipped: Int
    let failed: Int
    let timeSeconds: Double
    let cancelled: Bool

    var summary: String {
        if cancelled {
            return "Cancelled after indexing \(indexed) videos"
        }
        return String(format: "Indexed %d videos (%d skipped, %d failed) in %.1fs",
                      indexed, skipped, failed, timeSeconds)
    }
}

// MARK: - Errors

enum VideoIndexError: LocalizedError {
    case notAVideo
    case couldNotLoadVideo
    case frameExtractionFailed

    var errorDescription: String? {
        switch self {
        case .notAVideo:
            return "Asset is not a video"
        case .couldNotLoadVideo:
            return "Could not load video"
        case .frameExtractionFailed:
            return "Failed to extract frames from video"
        }
    }
}
