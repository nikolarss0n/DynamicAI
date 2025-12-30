import Foundation
import Photos
import AppKit
import Combine
import CoreLocation

// MARK: - Video Index Service

@MainActor
class VideoIndexService: ObservableObject {
    static let shared = VideoIndexService()
    
    // MARK: - Published State
    
    @Published var isIndexing = false
    @Published var indexingProgress: IndexingProgress?
    @Published var indexedCount: Int = 0
    
    // MARK: - Services
    
    private let photosProvider = PhotosProvider()
    private let groqService = GroqService.shared
    
    // NEW: Embedding & Vector services
    private let embeddingService = EmbeddingService.shared
    private let vectorStore = VectorStore.shared
    private let visionClassifier = VisionClassifier.shared
    
    // MARK: - Storage
    
    private let indexDirectory: URL
    private let thumbnailDirectory: URL
    private var indexCache: [String: VideoIndexEntry] = [:]
    
    // MARK: - Indexing Control

    private var shouldCancelIndexing = false

    private func log(_ message: String) {
        Log.shared.print("VideoIndex", message)
    }

    private init() {
        // Setup directories
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("DynamicAI", isDirectory: true)
        indexDirectory = appDir.appendingPathComponent("video_index", isDirectory: true)
        thumbnailDirectory = indexDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        
        // Create directories
        try? FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        
        // Load existing index
        loadIndexCache()
    }
    
    // MARK: - Index Loading
    
    private func loadIndexCache() {
        indexCache.removeAll()

        log("📂 Loading index from: \(indexDirectory.path)")

        guard let files = try? FileManager.default.contentsOfDirectory(at: indexDirectory, includingPropertiesForKeys: nil) else {
            log("❌ Could not read index directory")
            return
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
        log("   found \(jsonFiles.count) JSON files")

        for file in jsonFiles {
            do {
                let data = try Data(contentsOf: file)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let entry = try decoder.decode(VideoIndexEntry.self, from: data)
                indexCache[entry.videoId] = entry
            } catch {
                log("❌ Failed to load \(file.lastPathComponent): \(error)")
            }
        }

        indexedCount = indexCache.count
        log("✅ Loaded \(indexedCount) indexed videos")
    }
    
    // MARK: - Check if Indexed
    
    func isIndexed(asset: PHAsset) -> Bool {
        indexCache[asset.localIdentifier] != nil
    }
    
    func getIndexEntry(for asset: PHAsset) -> VideoIndexEntry? {
        indexCache[asset.localIdentifier]
    }
    
    // MARK: - Search Index
    
    func search(query: String) -> [VideoSearchMatch] {
        let lowercaseQuery = query.lowercased()
        
        // Extract meaningful search terms (remove filler words)
        let fillerWords = Set(["i", "me", "my", "the", "a", "an", "to", "of", "in", "on", "at", "for", "is", "am", "are", "was", "were", "where", "when", "what", "show", "find", "videos", "video", "with"])
        let queryWords = lowercaseQuery.split(separator: " ")
            .map(String.init)
            .filter { !fillerWords.contains($0) }
        
        // Detect compound phrases (e.g., "jump rope" should match as phrase, not separate words)
        let compoundPhrases = extractCompoundPhrases(from: lowercaseQuery)
        
        // Detect if user is asking about themselves
        let isFirstPerson = lowercaseQuery.contains("i ") || lowercaseQuery.hasPrefix("i ") ||
                           lowercaseQuery.contains(" me ") || lowercaseQuery.contains(" my ")
        
        var matches: [VideoSearchMatch] = []
        
        for (_, entry) in indexCache {
            var score: Double = 0
            var matchReasons: [String] = []
            let visualLower = entry.visual.description.lowercased()
            let keywordsLower = entry.visual.keywords.map { $0.lowercased() }
            
            // Check compound phrases first (highest priority)
            for phrase in compoundPhrases {
                if visualLower.contains(phrase) {
                    score += 5.0
                    matchReasons.append("phrase: \(phrase)")
                }
                if keywordsLower.contains(where: { $0.contains(phrase) }) {
                    score += 6.0
                    matchReasons.append("keyword phrase: \(phrase)")
                }
            }
            
            // Check individual words in visual description
            for word in queryWords {
                if visualLower.contains(word) {
                    score += 1.0
                    matchReasons.append("visual: \(word)")
                }
            }
            
            // Check keywords (higher weight)
            for keyword in entry.visual.keywords {
                let keywordLower = keyword.lowercased()
                for word in queryWords {
                    if keywordLower.contains(word) || word.contains(keywordLower) {
                        score += 2.0
                        matchReasons.append("keyword: \(keyword)")
                    }
                }
            }
            
            // Check audio transcript
            if let transcript = entry.audio?.transcript {
                let transcriptLower = transcript.lowercased()
                for phrase in compoundPhrases {
                    if transcriptLower.contains(phrase) {
                        score += 4.0
                        matchReasons.append("audio phrase: \(phrase)")
                    }
                }
                for word in queryWords {
                    if transcriptLower.contains(word) {
                        score += 1.5
                        matchReasons.append("audio: \(word)")
                    }
                }
            }

            // Check people tags (highest weight - exact person search)
            // But penalize if first-person query and video shows children
            if let people = entry.people {
                for person in people {
                    let personLower = person.lowercased()
                    for word in queryWords {
                        if personLower.contains(word) || word.contains(personLower) {
                            score += 3.0
                            matchReasons.append("person: \(person)")
                        }
                    }
                }
            }
            
            // Exclude/heavily penalize children videos if user is asking about themselves
            if isFirstPerson {
                let childTerms = ["child", "kid", "baby", "toddler", "infant", "boy", "girl", 
                                  "son", "daughter", "young", "little one", "children", "kids"]
                let hasChildContent = childTerms.contains { visualLower.contains($0) } ||
                                     keywordsLower.contains { kw in childTerms.contains { kw.contains($0) } }
                if hasChildContent {
                    score = 0 // Exclude entirely - user asked about themselves
                    matchReasons.append("excluded: children in video but user asked about self")
                }
            }

            if score > 0 {
                matches.append(VideoSearchMatch(
                    entry: entry,
                    score: score,
                    matchReasons: matchReasons
                ))
            }
        }
        
        // Sort by score descending
        return matches.sorted { $0.score > $1.score }
    }
    
    // MARK: - Semantic Search (NEW)
    
    /// Search using embeddings for semantic similarity
    /// Combines keyword matching with vector similarity for best results
    func semanticSearch(query: String, topK: Int = 10) async -> [VideoSearchMatch] {
        // Use hybrid search from vector store
        let results = await vectorStore.hybridSearch(
            query: query,
            topK: topK,
            keywordWeight: 0.3,
            semanticWeight: 0.7
        )
        
        // Convert to VideoSearchMatch format
        return results.compactMap { result in
            guard let entry = indexCache[result.id] else { return nil }
            return VideoSearchMatch(
                entry: entry,
                score: Double(result.score),
                matchReasons: ["semantic: \(String(format: "%.2f", result.score))"]
            )
        }
    }
    
    /// Smart search that auto-selects best strategy
    func smartSearch(query: String, topK: Int = 10) async -> [VideoSearchMatch] {
        // Run both searches in parallel
        async let keywordResults = search(query: query)
        async let semanticResults = semanticSearch(query: query, topK: topK)
        
        let (keyword, semantic) = await (keywordResults, semanticResults)
        
        // Merge and deduplicate results
        var scoreById: [String: (entry: VideoIndexEntry, score: Double, reasons: [String])] = [:]
        
        // Add keyword results
        for match in keyword {
            let existing = scoreById[match.entry.videoId]
            let newScore = (existing?.score ?? 0) + match.score * 0.4
            let reasons = (existing?.reasons ?? []) + match.matchReasons.map { "keyword: \($0)" }
            scoreById[match.entry.videoId] = (match.entry, newScore, reasons)
        }
        
        // Add semantic results
        for match in semantic {
            let existing = scoreById[match.entry.videoId]
            let newScore = (existing?.score ?? 0) + match.score * 0.6
            let reasons = (existing?.reasons ?? []) + match.matchReasons
            scoreById[match.entry.videoId] = (match.entry, newScore, reasons)
        }
        
        // Sort and return
        return scoreById.values
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { VideoSearchMatch(entry: $0.entry, score: $0.score, matchReasons: $0.reasons) }
    }

    
    /// Extracts compound phrases from query (e.g., "jump rope" from "videos where I jump rope")
    private func extractCompoundPhrases(from query: String) -> [String] {
        let lowercased = query.lowercased()
        var phrases: [String] = []
        
        // Known compound activities/objects
        let knownPhrases = [
            "jump rope", "jumping rope", "skipping rope", "skip rope",
            "push up", "push ups", "pushup", "pushups",
            "pull up", "pull ups", "pullup", "pullups", 
            "sit up", "sit ups", "situp", "situps",
            "weight lifting", "weightlifting",
            "rock climbing", "ice skating", "roller skating",
            "mountain biking", "road cycling",
            "scuba diving", "sky diving", "skydiving",
            "base jumping", "bungee jumping",
            "martial arts", "kick boxing", "kickboxing",
            "home workout", "gym workout",
            "birthday party", "christmas tree",
            "living room", "dining room", "bed room", "bedroom",
            "back yard", "backyard", "front yard",
            "swimming pool", "hot tub",
            "dog walking", "cat playing",
            "video game", "board game"
        ]
        
        for phrase in knownPhrases {
            if lowercased.contains(phrase) {
                phrases.append(phrase)
            }
        }
        
        return phrases
    }
    
    // MARK: - Index Videos
    
    func startIndexing(videos: [PHAsset]? = nil, limit: Int? = nil, onProgress: ((IndexingProgress) -> Void)? = nil) async {
        guard !isIndexing else {
            log("⚠️ Already indexing, ignoring start request")
            return
        }

        shouldCancelIndexing = false
        await performIndexing(videos: videos, limit: limit, onProgress: onProgress)
    }

    func cancelIndexing() {
        log("🛑 Cancel requested")
        shouldCancelIndexing = true
        isIndexing = false
        indexingProgress = nil
        log("🛑 Indexing cancelled")
    }

    func clearIndex() {
        log("🗑️ Clearing index...")

        // Cancel any ongoing indexing
        cancelIndexing()

        // Clear cache
        indexCache.removeAll()
        indexedCount = 0

        // Delete all files in index directory
        if let files = try? FileManager.default.contentsOfDirectory(at: indexDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        // Recreate thumbnail directory
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)

        log("✅ Index cleared")
    }
    
    private func performIndexing(videos: [PHAsset]?, limit: Int? = nil, onProgress: ((IndexingProgress) -> Void)?) async {
        isIndexing = true
        defer {
            isIndexing = false
            indexingProgress = nil
        }

        // Get videos to index
        var videosToIndex: [PHAsset]
        if let provided = videos {
            videosToIndex = provided.filter { !isIndexed(asset: $0) }
        } else {
            // Fetch recent videos not yet indexed
            let allVideos = await photosProvider.fetchVideos(limit: 200)
            log("📊 Found \(allVideos.count) total videos, \(indexCache.count) already indexed")
            videosToIndex = allVideos.filter { !isIndexed(asset: $0) }
        }
        
        // Apply limit if specified
        if let limit = limit, limit > 0 && videosToIndex.count > limit {
            log("📊 Limiting to \(limit) videos (from \(videosToIndex.count) available)")
            videosToIndex = Array(videosToIndex.prefix(limit))
        }

        guard !videosToIndex.isEmpty else {
            log("✅ No new videos to index")
            return
        }

        log("🚀 Starting indexing of \(videosToIndex.count) videos (parallel mode)...")

        // Check cancellation early
        if shouldCancelIndexing || Task.isCancelled {
            log("🛑 Cancelled before starting")
            return
        }

        // Fetch people/faces mapping once for all videos
        log("👥 Fetching people tags...")
        let peopleMapping = await photosProvider.fetchPeopleMapping()
        log("👥 Found people tags for \(peopleMapping.count) assets")

        // Process videos in parallel batches (3 concurrent)
        let concurrencyLimit = 3
        let totalCount = videosToIndex.count
        var completedCount = 0

        // Process in chunks to limit concurrency
        for chunkStart in stride(from: 0, to: videosToIndex.count, by: concurrencyLimit) {
            if shouldCancelIndexing || Task.isCancelled {
                log("🛑 Cancelled between batches")
                return
            }

            let chunkEnd = min(chunkStart + concurrencyLimit, videosToIndex.count)
            let chunk = Array(videosToIndex[chunkStart..<chunkEnd])

            // Process chunk in parallel
            await withTaskGroup(of: (PHAsset, VideoIndexEntry?, Error?).self) { group in
                for asset in chunk {
                    group.addTask {
                        do {
                            let entry = try await self.indexVideo(
                                asset: asset,
                                peopleMapping: peopleMapping,
                                progressUpdate: { _ in } // Simplified for parallel
                            )
                            return (asset, entry, nil)
                        } catch {
                            return (asset, nil, error)
                        }
                    }
                }

                // Collect results
                for await (asset, entry, error) in group {
                    completedCount += 1
                    let filename = getAssetFilename(asset)

                    if let entry = entry {
                        // Save to cache and disk
                        indexCache[entry.videoId] = entry
                        do {
                            try saveEntry(entry)
                            indexedCount = indexCache.count
                            log("✓ \(completedCount)/\(totalCount): \(filename)")
                        } catch {
                            log("❌ Save failed \(completedCount)/\(totalCount): \(error.localizedDescription)")
                        }
                    } else if let error = error {
                        if shouldCancelIndexing || Task.isCancelled {
                            log("🛑 Cancelled during processing")
                            return
                        }
                        log("❌ Failed \(completedCount)/\(totalCount): \(error.localizedDescription)")
                    }

                    // Update progress
                    let progress = IndexingProgress(
                        current: completedCount,
                        total: totalCount,
                        currentVideoName: filename,
                        currentThumbnail: nil,
                        phase: .analyzingVisual
                    )
                    indexingProgress = progress
                    onProgress?(progress)
                }
            }
        }

        log("✅ Indexing complete. Total indexed: \(indexedCount)")
        
        // Save vector store to disk
        await vectorStore.saveToDisk()
        log("💾 Vector store saved")
    }
    
    // MARK: - Rebuild Embeddings
    
    /// Regenerate embeddings for all indexed videos
    /// Use this after upgrading embedding model
    func rebuildAllEmbeddings() async {
        log("🔄 Rebuilding embeddings for \(indexCache.count) videos...")
        
        var updated = 0
        for (id, entry) in indexCache {
            // Generate new embedding
            if let embedding = await embeddingService.embedMediaMetadata(
                description: entry.visual.description,
                keywords: entry.visual.keywords,
                transcript: entry.audio?.transcript,
                people: entry.people
            ) {
                // Update cache
                var updatedEntry = entry
                updatedEntry.embedding = embedding
                indexCache[id] = updatedEntry
                
                // Update vector store
                await vectorStore.upsert(
                    id: id,
                    vector: embedding,
                    metadata: VectorMetadata(
                        description: entry.visual.description,
                        keywords: entry.visual.keywords,
                        transcript: entry.audio?.transcript,
                        people: entry.people,
                        mediaType: "video",
                        duration: entry.source.duration,
                        createdAt: entry.source.createdAt,
                        location: nil
                    )
                )
                
                // Save to disk
                do {
                    try saveEntry(updatedEntry)
                    updated += 1
                } catch {
                    log("❌ Failed to save updated entry: \(error)")
                }
            }
        }
        
        await vectorStore.saveToDisk()
        log("✅ Rebuilt embeddings for \(updated) videos")
    }
    
    // MARK: - Index Single Video
    
    private func indexVideo(asset: PHAsset, peopleMapping: [String: [String]], progressUpdate: @escaping (IndexingPhase) -> Void) async throws -> VideoIndexEntry {
        let videoId = asset.localIdentifier
        let filename = getAssetFilename(asset)

        // Check cancellation
        if shouldCancelIndexing { throw CancellationError() }

        // Extract 3 high-res thumbnails
        progressUpdate(.extracting)
        let thumbnails = await extractThumbnails(asset: asset)

        // Check cancellation after thumbnails
        if shouldCancelIndexing { throw CancellationError() }

        // Save thumbnails to disk
        let thumbnailFilenames = try saveThumbnails(thumbnails, videoId: videoId)

        // Get people tags for this video
        let people = peopleMapping[videoId] ?? []

        // Check cancellation before expensive AI operations
        if shouldCancelIndexing { throw CancellationError() }

        // NEW: Run on-device vision analysis FIRST (free, fast ~50ms)
        progressUpdate(.analyzingVisual)
        var onDeviceAnalysis: VisionAnalysisResult? = nil
        if let firstThumb = thumbnails.first {
            onDeviceAnalysis = await visionClassifier.analyze(image: firstThumb)
            log("   On-device analysis: \(onDeviceAnalysis?.sceneLabels.prefix(3).map { $0.identifier } ?? [])")
        }
        
        // Skip screen recordings and screenshots (detected by on-device analysis)
        if let analysis = onDeviceAnalysis {
            let isScreenContent = analysis.sceneLabels.contains { 
                ["computer_screen", "monitor", "screenshot", "display"].contains($0.identifier)
            }
            if isScreenContent && analysis.faceCount == 0 {
                log("   ⏭️ Skipping screen recording/screenshot")
                throw IndexingError.skipped("Screen recording detected")
            }
        }
        
        // Run Claude vision and audio analysis in parallel
        async let visionResult = analyzeVisuals(thumbnails: thumbnails)
        async let audioResult = transcribeAudio(asset: asset, progressUpdate: progressUpdate)

        let (visual, audio) = await (visionResult, audioResult)

        // Check cancellation after AI operations
        if shouldCancelIndexing { throw CancellationError() }
        
        // Merge on-device keywords with Claude analysis
        var finalVisual = visual ?? VideoVisualInfo(
            description: "Could not analyze",
            keywords: [],
            thumbnails: thumbnailFilenames,
            analyzedAt: Date(),
            model: "unknown"
        )
        
        // Add on-device scene labels as additional keywords
        if let analysis = onDeviceAnalysis {
            let onDeviceKeywords = analysis.keywords
            let mergedKeywords = Array(Set(finalVisual.keywords + onDeviceKeywords))
            finalVisual = VideoVisualInfo(
                description: finalVisual.description,
                keywords: mergedKeywords,
                thumbnails: thumbnailFilenames,
                analyzedAt: finalVisual.analyzedAt,
                model: finalVisual.model
            )
        }

        // NEW: Generate embedding for semantic search
        let embedding = await embeddingService.embedMediaMetadata(
            description: finalVisual.description,
            keywords: finalVisual.keywords,
            transcript: audio?.transcript,
            people: people.isEmpty ? nil : people
        )
        
        // Build entry
        var entry = VideoIndexEntry(
            version: "1.1",  // Bumped version for new fields
            videoId: videoId,
            userId: nil, // Will be set when syncing to AWS
            source: VideoSourceInfo(
                filename: filename,
                duration: asset.duration,
                createdAt: asset.creationDate ?? Date(),
                localPath: nil
            ),
            visual: finalVisual,
            audio: audio,
            people: people.isEmpty ? nil : people,
            indexed: IndexedInfo(
                at: Date(),
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            ),
            embedding: embedding,
            visionAnalysis: onDeviceAnalysis
        )
        
        // NEW: Store in vector store for semantic search
        if let emb = embedding {
            await vectorStore.upsert(
                id: videoId,
                vector: emb,
                metadata: VectorMetadata(
                    description: finalVisual.description,
                    keywords: finalVisual.keywords,
                    transcript: audio?.transcript,
                    people: people.isEmpty ? nil : people,
                    mediaType: "video",
                    duration: asset.duration,
                    createdAt: asset.creationDate,
                    location: asset.location.map { loc in
                        LocationInfo(
                            latitude: loc.coordinate.latitude,
                            longitude: loc.coordinate.longitude,
                            placeName: nil
                        )
                    }
                )
            )
        }
        
        return entry
    }
    
    // MARK: - Thumbnail Extraction
    
    private func extractThumbnails(asset: PHAsset) async -> [NSImage] {
        // Extract 3 frames at 40%, 50%, 60% of video
        let positions: [Double] = [0.4, 0.5, 0.6]
        var thumbnails: [NSImage] = []
        
        for position in positions {
            if let thumb = await photosProvider.getVideoThumbnail(
                for: asset,
                size: CGSize(width: 800, height: 600),
                position: position
            ) {
                thumbnails.append(thumb)
            }
        }
        
        return thumbnails
    }
    
    private func saveThumbnails(_ thumbnails: [NSImage], videoId: String) throws -> [String] {
        var filenames: [String] = []
        let safeId = videoId.replacingOccurrences(of: "/", with: "_")
        
        for (index, thumbnail) in thumbnails.enumerated() {
            let filename = "\(safeId)_\(index + 1).jpg"
            let url = thumbnailDirectory.appendingPathComponent(filename)
            
            guard let tiffData = thumbnail.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                continue
            }
            
            try jpegData.write(to: url)
            filenames.append(filename)
        }
        
        return filenames
    }
    
    // MARK: - Visual Analysis (Claude Haiku 4.5)
    
    private func analyzeVisuals(thumbnails: [NSImage]) async -> VideoVisualInfo? {
        guard let apiKey = KeychainService.shared.getAPIKey(for: .anthropic) else {
            print("[VideoIndex] No Anthropic API key")
            return nil
        }
        
        // Convert thumbnails to base64
        var imageContents: [[String: Any]] = []
        for thumbnail in thumbnails {
            guard let tiffData = thumbnail.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }
            
            imageContents.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": jpegData.base64EncodedString()
                ]
            ])
        }
        
        guard !imageContents.isEmpty else { return nil }
        
        // Add prompt
        imageContents.append([
            "type": "text",
            "text": """
            Analyze these 3 video frames and describe what's happening in this video.
            
            Provide:
            1. A detailed description (2-3 sentences) of the scene, people, actions, objects, and setting
            2. 5-10 searchable keywords for finding this video later
            
            Reply ONLY with JSON:
            {"description": "...", "keywords": ["...", "..."]}
            """
        ])
        
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 300,
            "messages": [[
                "role": "user",
                "content": imageContents
            ]]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("[VideoIndex] Vision API error")
                return nil
            }
            
            // Parse response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                
                // Extract JSON from response
                if let jsonStart = text.firstIndex(of: "{"),
                   let jsonEnd = text.lastIndex(of: "}") {
                    let jsonStr = String(text[jsonStart...jsonEnd])
                    if let jsonData = jsonStr.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        
                        let description = parsed["description"] as? String ?? ""
                        let keywords = parsed["keywords"] as? [String] ?? []
                        
                        return VideoVisualInfo(
                            description: description,
                            keywords: keywords,
                            thumbnails: [],
                            analyzedAt: Date(),
                            model: "claude-haiku-4-5-20251001"
                        )
                    }
                }
            }
        } catch {
            print("[VideoIndex] Vision analysis error: \(error)")
        }
        
        return nil
    }
    
    // MARK: - Batch Visual Analysis (Claude)
    
    /// Analyze multiple videos in a single API call for efficiency
    /// Groups up to 5 videos per request to reduce API overhead
    private func batchAnalyzeVisuals(videoThumbnails: [(id: String, thumbnails: [NSImage])]) async -> [String: VideoVisualInfo] {
        guard let apiKey = KeychainService.shared.getAPIKey(for: .anthropic) else {
            log("No Anthropic API key for batch analysis")
            return [:]
        }
        
        var results: [String: VideoVisualInfo] = [:]
        
        // Process in batches of 5 videos
        let batchSize = 5
        for batchStart in stride(from: 0, to: videoThumbnails.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, videoThumbnails.count)
            let batch = Array(videoThumbnails[batchStart..<batchEnd])
            
            // Build multi-video prompt
            var imageContents: [[String: Any]] = []
            var videoIds: [String] = []
            
            for (index, (id, thumbnails)) in batch.enumerated() {
                videoIds.append(id)
                
                // Add header for this video
                imageContents.append([
                    "type": "text",
                    "text": "=== VIDEO \(index + 1) (ID: \(id.prefix(8))) ==="
                ])
                
                // Add 1-2 thumbnails per video in batch (save tokens)
                for thumbnail in thumbnails.prefix(2) {
                    guard let tiffData = thumbnail.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiffData),
                          let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                        continue
                    }
                    
                    imageContents.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": jpegData.base64EncodedString()
                        ]
                    ])
                }
            }
            
            // Add batch analysis prompt
            imageContents.append([
                "type": "text",
                "text": """
                Analyze the \(batch.count) videos shown above. For EACH video, provide:
                1. A brief description (1-2 sentences)
                2. 5-8 searchable keywords
                
                Reply with a JSON array in order:
                [
                  {"description": "...", "keywords": ["...", "..."]},
                  {"description": "...", "keywords": ["...", "..."]}
                ]
                """
            ])
            
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            
            let body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 800,
                "messages": [[
                    "role": "user",
                    "content": imageContents
                ]]
            ]
            
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    log("Batch vision API error")
                    continue
                }
                
                // Parse response
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]],
                   let text = content.first?["text"] as? String {
                    
                    // Extract JSON array
                    if let jsonStart = text.firstIndex(of: "["),
                       let jsonEnd = text.lastIndex(of: "]") {
                        let jsonStr = String(text[jsonStart...jsonEnd])
                        if let jsonData = jsonStr.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                            
                            // Map results back to video IDs
                            for (index, item) in parsed.enumerated() {
                                guard index < videoIds.count else { break }
                                
                                let description = item["description"] as? String ?? ""
                                let keywords = item["keywords"] as? [String] ?? []
                                
                                results[videoIds[index]] = VideoVisualInfo(
                                    description: description,
                                    keywords: keywords,
                                    thumbnails: [],
                                    analyzedAt: Date(),
                                    model: "claude-haiku-4-5-batch"
                                )
                            }
                            
                            log("Batch analyzed \(parsed.count) videos successfully")
                        }
                    }
                }
            } catch {
                log("Batch vision analysis error: \(error)")
            }
        }
        
        return results
    }
    
    // MARK: - Audio Transcription (Groq Whisper)
    
    private func transcribeAudio(asset: PHAsset, progressUpdate: @escaping (IndexingPhase) -> Void) async -> VideoAudioInfo? {
        progressUpdate(.transcribingAudio)
        
        // Skip if video has no audio track (saves ~5-15s per silent video)
        guard await hasAudioTrack(asset: asset) else {
            log("⏭️ Skipping audio - no audio track")
            return nil
        }
        
        do {
            // Reduced from 60s to 30s for faster processing
            let result = try await groqService.transcribeVideoAudio(asset: asset, segmentDuration: 30)
            
            guard !result.isEmpty else {
                return nil
            }
            
            return VideoAudioInfo(
                transcript: result.text,
                language: result.language,
                duration: result.duration ?? 30,
                segmentStart: nil, // Middle segment
                transcribedAt: Date(),
                model: "whisper-large-v3-turbo"
            )
        } catch {
            print("[VideoIndex] Transcription error: \(error)")
            return nil
        }
    }

    
    /// Check if video asset has an audio track (avoid transcription for silent videos)
    private func hasAudioTrack(asset: PHAsset) async -> Bool {
        guard asset.mediaType == .video else { return false }
        
        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .fastFormat // Fast check, don't need full quality
            options.isNetworkAccessAllowed = false // Don't download from iCloud for this check
            
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let avAsset = avAsset else {
                    continuation.resume(returning: true) // Assume has audio if can't check
                    return
                }
                
                let audioTracks = avAsset.tracks(withMediaType: .audio)
                continuation.resume(returning: !audioTracks.isEmpty)
            }
        }
    }
    
    // MARK: - Persistence
    
    private func saveEntry(_ entry: VideoIndexEntry) throws {
        let safeId = entry.videoId.replacingOccurrences(of: "/", with: "_")
        let url = indexDirectory.appendingPathComponent("\(safeId).json")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(entry)
        try data.write(to: url)
    }
    
    // MARK: - Helpers
    
    private func getAssetFilename(_ asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first?.originalFilename ?? "Unknown"
    }
    
    // MARK: - Get Thumbnail Image
    
    func getThumbnailImage(filename: String) -> NSImage? {
        let url = thumbnailDirectory.appendingPathComponent(filename)
        return NSImage(contentsOf: url)
    }
}

// MARK: - Index Models (JSON-serializable for AWS)

struct VideoIndexEntry: Codable {
    let version: String
    let videoId: String
    let userId: String?
    let source: VideoSourceInfo
    var visual: VideoVisualInfo
    let audio: VideoAudioInfo?
    let people: [String]? // People/faces tags from Photos app
    let indexed: IndexedInfo
    
    // NEW: Embedding for semantic search
    var embedding: [Float]?
    
    // NEW: On-device vision analysis (free, fast)
    var visionAnalysis: VisionAnalysisResult?
}

struct VideoSourceInfo: Codable {
    let filename: String
    let duration: TimeInterval
    let createdAt: Date
    let localPath: String?
}

struct VideoVisualInfo: Codable {
    let description: String
    let keywords: [String]
    var thumbnails: [String]
    let analyzedAt: Date
    let model: String
}

struct VideoAudioInfo: Codable {
    let transcript: String
    let language: String?
    let duration: TimeInterval
    let segmentStart: TimeInterval?
    let transcribedAt: Date
    let model: String
}

struct IndexedInfo: Codable {
    let at: Date
    let appVersion: String
}

// MARK: - Search Result

struct VideoSearchMatch {
    let entry: VideoIndexEntry
    let score: Double
    let matchReasons: [String]
}

// MARK: - Indexing Progress

struct IndexingProgress {
    let current: Int
    let total: Int
    let currentVideoName: String
    let currentThumbnail: NSImage?
    let phase: IndexingPhase
    
    var progressPercent: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

enum IndexingPhase: String {
    case extracting = "Extracting frames..."
    case analyzingVisual = "Analyzing visuals..."
    case transcribingAudio = "Transcribing audio..."
    case generatingEmbedding = "Generating embedding..."
}

// MARK: - Indexing Error

enum IndexingError: Error {
    case skipped(String)
    case analysisFailure(String)
    case cancelled
    
    var localizedDescription: String {
        switch self {
        case .skipped(let reason): return "Skipped: \(reason)"
        case .analysisFailure(let reason): return "Analysis failed: \(reason)"
        case .cancelled: return "Indexing cancelled"
        }
    }
}
