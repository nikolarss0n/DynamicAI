import Foundation
import Accelerate

// MARK: - Vector Store
/// High-performance local vector database for semantic search
/// Uses SIMD-accelerated similarity computation via Accelerate framework

actor VectorStore {
    static let shared = VectorStore()
    
    // MARK: - Storage
    
    private var vectors: [String: VectorEntry] = [:]
    private let storageURL: URL
    private let embeddingService = EmbeddingService.shared
    
    // MARK: - Index Structures (for faster search)
    
    /// Inverted index: keyword -> [assetId]
    private var keywordIndex: [String: Set<String>] = [:]
    
    /// Cluster centroids for approximate nearest neighbor
    private var clusterCentroids: [[Float]] = []
    private var clusterAssignments: [String: Int] = [:]
    
    // MARK: - Configuration
    
    private let dimension = 512
    private let numClusters = 16  // For ANN search
    
    // MARK: - Initialization
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("DynamicAI", isDirectory: true)
        storageURL = appDir.appendingPathComponent("vector_store.json")
        
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        
        Task {
            await loadFromDisk()
        }
    }
    
    // MARK: - CRUD Operations
    
    /// Insert or update a vector entry
    func upsert(
        id: String,
        vector: [Float],
        metadata: VectorMetadata
    ) {
        let entry = VectorEntry(
            id: id,
            vector: vector,
            metadata: metadata,
            updatedAt: Date()
        )
        vectors[id] = entry
        
        // Update keyword index
        updateKeywordIndex(for: entry)
        
        // Invalidate cluster assignment
        clusterAssignments.removeValue(forKey: id)
    }
    
    /// Get vector entry by ID
    func get(id: String) -> VectorEntry? {
        vectors[id]
    }
    
    /// Delete vector entry
    func delete(id: String) {
        if let entry = vectors.removeValue(forKey: id) {
            // Clean up keyword index
            for keyword in entry.metadata.keywords {
                keywordIndex[keyword.lowercased()]?.remove(id)
            }
            clusterAssignments.removeValue(forKey: id)
        }
    }
    
    /// Get total count
    var count: Int {
        vectors.count
    }
    
    // MARK: - Search Operations
    
    /// Semantic search using cosine similarity
    /// Uses SIMD acceleration for fast vector operations
    func search(
        query: String,
        topK: Int = 10,
        threshold: Float = 0.25,
        filters: SearchFilters? = nil
    ) async -> [SearchResult] {
        // Generate query embedding
        guard let queryVector = await embeddingService.embed(text: query) else {
            print("[VectorStore] Failed to embed query")
            return []
        }
        
        return searchByVector(
            queryVector: queryVector,
            topK: topK,
            threshold: threshold,
            filters: filters
        )
    }
    
    /// Search by pre-computed vector
    func searchByVector(
        queryVector: [Float],
        topK: Int = 10,
        threshold: Float = 0.25,
        filters: SearchFilters? = nil
    ) -> [SearchResult] {
        var candidates = Array(vectors.values)
        
        // Apply filters
        if let filters = filters {
            candidates = applyFilters(candidates: candidates, filters: filters)
        }
        
        // Compute similarities using SIMD
        var results: [(entry: VectorEntry, score: Float)] = []
        
        for entry in candidates {
            let score = simdCosineSimilarity(queryVector, entry.vector)
            if score >= threshold {
                results.append((entry, score))
            }
        }
        
        // Sort by score descending
        results.sort { $0.score > $1.score }
        
        // Return top-k
        return results.prefix(topK).map { result in
            SearchResult(
                id: result.entry.id,
                score: result.score,
                metadata: result.entry.metadata
            )
        }
    }
    
    /// Hybrid search: combines keyword + semantic
    func hybridSearch(
        query: String,
        topK: Int = 10,
        keywordWeight: Float = 0.3,
        semanticWeight: Float = 0.7,
        filters: SearchFilters? = nil
    ) async -> [SearchResult] {
        // 1. Keyword search (fast pre-filter)
        let keywords = extractKeywords(from: query)
        var keywordScores: [String: Float] = [:]
        
        for keyword in keywords {
            if let matchingIds = keywordIndex[keyword] {
                for id in matchingIds {
                    keywordScores[id, default: 0] += 1.0 / Float(keywords.count)
                }
            }
        }
        
        // 2. Semantic search
        guard let queryVector = await embeddingService.embed(text: query) else {
            // Fall back to keyword-only
            return keywordScores.sorted { $0.value > $1.value }
                .prefix(topK)
                .compactMap { id, score in
                    guard let entry = vectors[id] else { return nil }
                    return SearchResult(id: id, score: score, metadata: entry.metadata)
                }
        }
        
        // 3. Combine scores
        var combinedScores: [String: Float] = [:]
        
        // Add semantic scores
        for entry in vectors.values {
            let semanticScore = simdCosineSimilarity(queryVector, entry.vector)
            let keywordScore = keywordScores[entry.id] ?? 0
            
            let combined = semanticWeight * semanticScore + keywordWeight * keywordScore
            if combined > 0.1 { // Minimum threshold
                combinedScores[entry.id] = combined
            }
        }
        
        // Sort and return
        return combinedScores.sorted { $0.value > $1.value }
            .prefix(topK)
            .compactMap { id, score in
                guard let entry = vectors[id] else { return nil }
                return SearchResult(id: id, score: score, metadata: entry.metadata)
            }
    }
    
    // MARK: - Batch Operations
    
    /// Upsert multiple vectors efficiently
    func upsertBatch(_ entries: [(id: String, vector: [Float], metadata: VectorMetadata)]) {
        for entry in entries {
            upsert(id: entry.id, vector: entry.vector, metadata: entry.metadata)
        }
    }
    
    /// Generate embeddings for all entries that don't have them
    func rebuildEmbeddings() async {
        print("[VectorStore] Rebuilding embeddings for \(vectors.count) entries...")
        
        var updated = 0
        for (id, entry) in vectors {
            // Generate new embedding from metadata
            if let newVector = await embeddingService.embedMediaMetadata(
                description: entry.metadata.description,
                keywords: entry.metadata.keywords,
                transcript: entry.metadata.transcript,
                people: entry.metadata.people
            ) {
                vectors[id]?.vector = newVector
                vectors[id]?.updatedAt = Date()
                updated += 1
            }
        }
        
        print("[VectorStore] Updated \(updated) embeddings")
        await saveToDisk()
    }
    
    // MARK: - Persistence
    
    func saveToDisk() async {
        do {
            let data = try JSONEncoder().encode(Array(vectors.values))
            try data.write(to: storageURL)
            print("[VectorStore] Saved \(vectors.count) vectors to disk")
        } catch {
            print("[VectorStore] Save failed: \(error)")
        }
    }
    
    private func loadFromDisk() async {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            print("[VectorStore] No existing store found")
            return
        }
        
        do {
            let data = try Data(contentsOf: storageURL)
            let entries = try JSONDecoder().decode([VectorEntry].self, from: data)
            
            for entry in entries {
                vectors[entry.id] = entry
                updateKeywordIndex(for: entry)
            }
            
            print("[VectorStore] Loaded \(vectors.count) vectors from disk")
        } catch {
            print("[VectorStore] Load failed: \(error)")
        }
    }
    
    func clear() async {
        vectors.removeAll()
        keywordIndex.removeAll()
        clusterCentroids.removeAll()
        clusterAssignments.removeAll()
        
        try? FileManager.default.removeItem(at: storageURL)
        print("[VectorStore] Cleared all vectors")
    }
    
    // MARK: - Private Helpers
    
    /// SIMD-accelerated cosine similarity using Accelerate framework
    private func simdCosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        // Use vDSP for SIMD operations
        a.withUnsafeBufferPointer { aPtr in
            b.withUnsafeBufferPointer { bPtr in
                vDSP_dotpr(aPtr.baseAddress!, 1, bPtr.baseAddress!, 1, &dotProduct, vDSP_Length(a.count))
                vDSP_svesq(aPtr.baseAddress!, 1, &normA, vDSP_Length(a.count))
                vDSP_svesq(bPtr.baseAddress!, 1, &normB, vDSP_Length(b.count))
            }
        }
        
        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }
    
    private func updateKeywordIndex(for entry: VectorEntry) {
        for keyword in entry.metadata.keywords {
            let lowered = keyword.lowercased()
            if keywordIndex[lowered] == nil {
                keywordIndex[lowered] = []
            }
            keywordIndex[lowered]?.insert(entry.id)
        }
    }
    
    private func extractKeywords(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 2 }
    }
    
    private func applyFilters(candidates: [VectorEntry], filters: SearchFilters) -> [VectorEntry] {
        candidates.filter { entry in
            // Date range filter
            if let startDate = filters.startDate {
                guard let entryDate = entry.metadata.createdAt, entryDate >= startDate else {
                    return false
                }
            }
            if let endDate = filters.endDate {
                guard let entryDate = entry.metadata.createdAt, entryDate <= endDate else {
                    return false
                }
            }
            
            // Media type filter
            if let mediaType = filters.mediaType {
                guard entry.metadata.mediaType == mediaType else {
                    return false
                }
            }
            
            // Person filter
            if let person = filters.person {
                let lowered = person.lowercased()
                guard entry.metadata.people?.contains(where: { $0.lowercased().contains(lowered) }) ?? false else {
                    return false
                }
            }
            
            return true
        }
    }
}

// MARK: - Data Models

struct VectorEntry: Codable {
    let id: String
    var vector: [Float]
    let metadata: VectorMetadata
    var updatedAt: Date
}

struct VectorMetadata: Codable {
    let description: String
    let keywords: [String]
    let transcript: String?
    let people: [String]?
    let mediaType: String  // "photo" or "video"
    let duration: Double?
    let createdAt: Date?
    let location: LocationInfo?
}

struct LocationInfo: Codable {
    let latitude: Double
    let longitude: Double
    let placeName: String?
}

struct SearchFilters {
    let startDate: Date?
    let endDate: Date?
    let mediaType: String?
    let person: String?
    let hasAudio: Bool?
    
    init(
        startDate: Date? = nil,
        endDate: Date? = nil,
        mediaType: String? = nil,
        person: String? = nil,
        hasAudio: Bool? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.mediaType = mediaType
        self.person = person
        self.hasAudio = hasAudio
    }
}

struct SearchResult {
    let id: String
    let score: Float
    let metadata: VectorMetadata
}
