// MARK: - Label Index
// On-device photo classification using Apple Vision
// No network calls, no API costs - runs entirely on device
// Build: ~50ms per photo (background), Search: O(1) lookup

import Foundation
import Photos
import Vision
import AppKit

/// On-device label index using Apple Vision classification
actor LabelIndex {
    
    // MARK: - Storage
    
    /// label → [assetLocalIdentifier]
    private var index: [String: Set<String>] = [:]
    
    /// assetId → [labels]
    private var assetLabels: [String: [String]] = [:]
    
    /// Track indexed assets
    private var indexedAssets: Set<String> = []
    
    // MARK: - Configuration
    
    private let minConfidence: Float = 0.4  // Minimum confidence for label
    private let maxLabelsPerPhoto: Int = 10 // Max labels to store per photo
    private let storageURL: URL
    
    // MARK: - State
    
    private(set) var isIndexing = false
    private var shouldCancel = false
    
    // MARK: - Singleton
    
    static let shared = LabelIndex()
    
    // MARK: - Initialization
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DynamicAI", isDirectory: true)
        self.storageURL = dir.appendingPathComponent("label_index.json")
        
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        // Load existing index from disk on startup
        loadFromDisk()
    }
    
    // MARK: - Build Index
    
    /// Build label index using Apple Vision (on-device)
    /// ~50ms per photo, runs in background
    func buildIndex(
        limit: Int? = nil,
        onProgress: @escaping (Int, Int, String) -> Void
    ) async -> LabelIndexStats {
        guard !isIndexing else {
            return LabelIndexStats(total: 0, indexed: 0, skipped: 0, timeSeconds: 0, cancelled: true)
        }
        
        isIndexing = true
        shouldCancel = false
        
        let start = CFAbsoluteTimeGetCurrent()
        
        // Load existing index
        loadFromDisk()
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let total = limit ?? allAssets.count
        var indexed = 0
        var skipped = 0
        
        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .fastFormat
        requestOptions.resizeMode = .fast
        
        for i in 0..<min(total, allAssets.count) {
            if shouldCancel { break }
            
            let asset = allAssets.object(at: i)
            let assetId = asset.localIdentifier
            
            // Skip if already indexed
            if indexedAssets.contains(assetId) {
                skipped += 1
                continue
            }
            
            // Load thumbnail
            var thumbnail: NSImage?
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 299, height: 299),  // Vision optimal size
                contentMode: .aspectFill,
                options: requestOptions
            ) { image, _ in
                thumbnail = image
            }
            
            guard let image = thumbnail,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }
            
            // Classify with Vision (on-device)
            let labels = classifyImage(cgImage)
            
            if !labels.isEmpty {
                // Store labels for this asset
                assetLabels[assetId] = labels
                
                // Index by each label
                for label in labels {
                    let normalizedLabel = normalizeLabel(label)
                    if index[normalizedLabel] == nil {
                        index[normalizedLabel] = []
                    }
                    index[normalizedLabel]?.insert(assetId)
                }
                
                indexedAssets.insert(assetId)
                indexed += 1
            }
            
            // Progress callback
            if i % 10 == 0 {
                let currentLabels = labels.prefix(3).joined(separator: ", ")
                onProgress(i, total, currentLabels)
            }
            
            // Save periodically
            if indexed % 100 == 0 {
                saveToDisk()
            }
        }
        
        saveToDisk()
        isIndexing = false
        
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        return LabelIndexStats(
            total: total,
            indexed: indexed,
            skipped: skipped,
            timeSeconds: elapsed,
            cancelled: shouldCancel
        )
    }
    
    /// Cancel ongoing indexing
    func cancelIndexing() {
        shouldCancel = true
    }
    
    // MARK: - Search
    
    /// Search by label - O(1) lookup
    func search(label: String) -> [String] {
        let normalized = normalizeLabel(label)
        return Array(index[normalized] ?? [])
    }
    
    /// Search by multiple labels (intersection - must have ALL labels)
    func search(labels: [String]) -> [String] {
        guard !labels.isEmpty else { return [] }
        
        var result: Set<String>? = nil
        
        for label in labels {
            let normalized = normalizeLabel(label)
            guard let matches = index[normalized] else {
                return []  // Label not found, no results
            }
            
            if result == nil {
                result = matches
            } else {
                result = result?.intersection(matches)
            }
        }
        
        return Array(result ?? [])
    }
    
    /// Search by any of the labels (union - has ANY label)
    func searchAny(labels: [String]) -> [String] {
        var result = Set<String>()
        
        for label in labels {
            let normalized = normalizeLabel(label)
            if let matches = index[normalized] {
                result.formUnion(matches)
            }
        }
        
        return Array(result)
    }
    
    /// Get labels for a specific asset
    func getLabels(for assetId: String) -> [String] {
        return assetLabels[assetId] ?? []
    }
    
    /// Get all available labels
    func getAllLabels() -> [(label: String, count: Int)] {
        return index
            .map { (label: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }
    
    // MARK: - Vision Classification
    
    /// Classify image using Apple Vision (on-device)
    private func classifyImage(_ cgImage: CGImage) -> [String] {
        var labels: [String] = []
        
        let request = VNClassifyImageRequest { request, error in
            guard error == nil,
                  let results = request.results as? [VNClassificationObservation] else {
                return
            }
            
            labels = results
                .filter { $0.confidence >= self.minConfidence }
                .prefix(self.maxLabelsPerPhoto)
                .map { $0.identifier }
        }
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        
        return labels
    }
    
    /// Normalize label for consistent indexing
    private func normalizeLabel(_ label: String) -> String {
        // Vision labels are like "beach", "sunset", "outdoor"
        // Normalize to lowercase, handle synonyms
        let lowered = label.lowercased().trimmingCharacters(in: .whitespaces)
        
        // Common synonyms mapping (search term → Vision label)
        let synonyms: [String: String] = [
            "seashore": "beach",
            "coast": "beach",
            "seaside": "beach",
            "ocean": "beach",
            "sea": "beach",
            "sundown": "sunset",
            "sunrise": "sunset",  // Group together for "golden hour"
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
    
    /// Expand search terms to Vision labels (for search queries)
    func expandSearchTerms(_ terms: [String]) -> [String] {
        var expanded = Set<String>()
        
        // Map high-level concepts to Vision labels
        let conceptMappings: [String: [String]] = [
            "outdoor": ["sky", "nature", "landscape", "mountain", "beach", "forest", "grass", "water"],
            "travel": ["sky", "landscape", "mountain", "beach", "architecture", "landmark"],
            "trip": ["sky", "landscape", "mountain", "beach", "architecture", "landmark"],
            "vacation": ["beach", "pool", "resort", "landscape", "mountain", "water"],
            "nature": ["forest", "tree", "flower", "grass", "mountain", "water", "sky", "landscape"],
            "party": ["person", "crowd", "celebration"],
            "wedding": ["person", "dress", "flower", "celebration"],
            "night": ["dark", "light", "illumination"],
            "indoor": ["room", "interior", "furniture"],
            "portrait": ["person", "face"],
            "selfie": ["person", "face"],
        ]
        
        for term in terms {
            let normalized = normalizeLabel(term)
            
            // Check if it's a high-level concept that needs expansion
            if let mappedLabels = conceptMappings[normalized] {
                expanded.formUnion(mappedLabels)
            } else {
                // Direct label
                expanded.insert(normalized)
            }
        }
        
        return Array(expanded)
    }
    
    // MARK: - Persistence
    
    private func saveToDisk() {
        let data = LabelIndexData(
            index: index.mapValues { Array($0) },
            assetLabels: assetLabels,
            indexedAssets: Array(indexedAssets)
        )
        
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: storageURL)
        } catch {
            print("LabelIndex: Failed to save - \(error)")
        }
    }
    
    func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(LabelIndexData.self, from: data) else {
            return
        }
        
        index = decoded.index.mapValues { Set($0) }
        assetLabels = decoded.assetLabels
        indexedAssets = Set(decoded.indexedAssets)
    }
    
    /// Clear all index data
    func clear() {
        index = [:]
        assetLabels = [:]
        indexedAssets = []
        try? FileManager.default.removeItem(at: storageURL)
    }
    
    // MARK: - Stats
    
    var stats: (photosIndexed: Int, uniqueLabels: Int, isLoaded: Bool) {
        (indexedAssets.count, index.count, !index.isEmpty)
    }
}

// MARK: - Data Models

struct LabelIndexData: Codable {
    let index: [String: [String]]
    let assetLabels: [String: [String]]
    let indexedAssets: [String]
}

struct LabelIndexStats {
    let total: Int
    let indexed: Int
    let skipped: Int
    let timeSeconds: Double
    let cancelled: Bool
    
    var summary: String {
        if cancelled {
            return "Cancelled after indexing \(indexed) photos"
        }
        return String(format: "Indexed %d photos (%d skipped) in %.1fs (%.0fms/photo)",
                      indexed, skipped, timeSeconds,
                      indexed > 0 ? (timeSeconds / Double(indexed)) * 1000 : 0)
    }
}

// MARK: - Common Labels Reference
// Apple Vision can detect these categories (and many more):
// 
// Scenes: beach, mountain, forest, city, indoor, outdoor, sunset, night
// Objects: car, dog, cat, person, food, flower, building
// Activities: sport, party, wedding, concert
// Nature: sky, water, grass, snow, clouds
// 
// Full list: ~1000+ categories from ImageNet
