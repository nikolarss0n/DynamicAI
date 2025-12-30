import Foundation
import NaturalLanguage

// MARK: - Embedding Service
/// Local-first embedding generation using Apple's NaturalLanguage framework
/// Falls back to simple TF-IDF for unsupported languages

actor EmbeddingService {
    static let shared = EmbeddingService()
    
    // MARK: - Configuration
    
    private let embeddingDimension = 512  // NLEmbedding dimension
    private var sentenceEmbedding: NLEmbedding?
    private var wordEmbedding: NLEmbedding?
    
    // MARK: - Initialization
    
    private init() {
        // Load embeddings lazily on first use
    }
    
    private func loadEmbeddings() {
        if sentenceEmbedding == nil {
            // Try to load sentence embedding (best for semantic search)
            sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
            print("[EmbeddingService] Sentence embedding loaded: \(sentenceEmbedding != nil)")
        }
        
        if wordEmbedding == nil {
            // Fallback to word embedding if sentence not available
            wordEmbedding = NLEmbedding.wordEmbedding(for: .english)
            print("[EmbeddingService] Word embedding loaded: \(wordEmbedding != nil)")
        }
    }
    
    // MARK: - Generate Embedding
    
    /// Generate embedding vector for text using Apple's NaturalLanguage framework
    /// Returns normalized 512-dimensional vector
    func embed(text: String) -> [Float]? {
        loadEmbeddings()
        
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return nil }
        
        // Try sentence embedding first (better for semantic similarity)
        if let embedding = sentenceEmbedding,
           let vector = embedding.vector(for: cleanedText) {
            return normalizeVector(vector.map { Float($0) })
        }
        
        // Fallback: Average word embeddings
        if let embedding = wordEmbedding {
            return averageWordEmbeddings(text: cleanedText, embedding: embedding)
        }
        
        // Final fallback: TF-IDF based embedding
        return tfidfEmbedding(text: cleanedText)
    }
    
    /// Generate embeddings for multiple texts in batch
    func embedBatch(texts: [String]) -> [[Float]?] {
        loadEmbeddings()
        return texts.map { embed(text: $0) }
    }
    
    // MARK: - Combined Embedding
    
    /// Generate a rich embedding combining description, keywords, and transcript
    func embedMediaMetadata(
        description: String,
        keywords: [String],
        transcript: String?,
        people: [String]?
    ) -> [Float]? {
        // Weight different components
        var weightedTexts: [(text: String, weight: Float)] = []
        
        // Description is most important
        if !description.isEmpty {
            weightedTexts.append((description, 1.0))
        }
        
        // Keywords are highly relevant
        if !keywords.isEmpty {
            let keywordText = keywords.joined(separator: " ")
            weightedTexts.append((keywordText, 0.8))
        }
        
        // Transcript provides context
        if let transcript = transcript, !transcript.isEmpty {
            // Truncate long transcripts
            let truncated = String(transcript.prefix(500))
            weightedTexts.append((truncated, 0.5))
        }
        
        // People names for person-based search
        if let people = people, !people.isEmpty {
            let peopleText = people.joined(separator: " ")
            weightedTexts.append((peopleText, 0.7))
        }
        
        guard !weightedTexts.isEmpty else { return nil }
        
        // Generate weighted average embedding
        var sumVector = [Float](repeating: 0, count: embeddingDimension)
        var totalWeight: Float = 0
        
        for (text, weight) in weightedTexts {
            if let vector = embed(text: text) {
                for i in 0..<min(vector.count, embeddingDimension) {
                    sumVector[i] += vector[i] * weight
                }
                totalWeight += weight
            }
        }
        
        guard totalWeight > 0 else { return nil }
        
        // Normalize by total weight
        return normalizeVector(sumVector.map { $0 / totalWeight })
    }
    
    // MARK: - Similarity
    
    /// Compute cosine similarity between two vectors
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }
    
    /// Find top-k most similar items
    func findSimilar(
        queryVector: [Float],
        candidates: [(id: String, vector: [Float])],
        topK: Int = 10,
        threshold: Float = 0.3
    ) -> [(id: String, score: Float)] {
        var results: [(id: String, score: Float)] = []
        
        for candidate in candidates {
            let score = cosineSimilarity(queryVector, candidate.vector)
            if score >= threshold {
                results.append((candidate.id, score))
            }
        }
        
        // Sort by score descending and take top-k
        return results.sorted { $0.score > $1.score }.prefix(topK).map { $0 }
    }
    
    // MARK: - Private Helpers
    
    private func averageWordEmbeddings(text: String, embedding: NLEmbedding) -> [Float]? {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        
        var vectors: [[Double]] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            if let vector = embedding.vector(for: word) {
                vectors.append(vector)
            }
            return true
        }
        
        guard !vectors.isEmpty else { return nil }
        
        // Average all word vectors
        let dimension = vectors[0].count
        var avgVector = [Float](repeating: 0, count: dimension)
        
        for vector in vectors {
            for i in 0..<dimension {
                avgVector[i] += Float(vector[i])
            }
        }
        
        let count = Float(vectors.count)
        return normalizeVector(avgVector.map { $0 / count })
    }
    
    private func tfidfEmbedding(text: String) -> [Float] {
        // Simple bag-of-words fallback with hashing trick
        let words = text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 2 }
        
        var vector = [Float](repeating: 0, count: embeddingDimension)
        
        for word in words {
            let hash = abs(word.hashValue) % embeddingDimension
            vector[hash] += 1
        }
        
        return normalizeVector(vector)
    }
    
    private func normalizeVector(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

// MARK: - Embedding Result

struct EmbeddingResult: Codable {
    let vector: [Float]
    let model: String
    let generatedAt: Date
    
    init(vector: [Float], model: String = "apple-nl-sentence") {
        self.vector = vector
        self.model = model
        self.generatedAt = Date()
    }
}
