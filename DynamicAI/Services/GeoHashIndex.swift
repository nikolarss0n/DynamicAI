// MARK: - GeoHash Index
// Ultra-lightweight spatial index for photo location search
// Build: ~3 seconds for 10K photos (no network calls)
// Search: O(1) dictionary lookup

import Foundation
import Photos
import CoreLocation

/// Geohash-based spatial index for instant location search
actor GeoHashIndex {
    
    // MARK: - Storage
    
    /// geohash prefix → [assetLocalIdentifier]
    private var index: [String: Set<String>] = [:]
    
    /// assetId → full geohash (for reverse lookup)
    private var assetGeohash: [String: String] = [:]
    
    /// Track indexed asset modification dates for incremental updates
    private var indexedAssets: Set<String> = []
    
    // MARK: - Configuration
    
    private let precision: Int
    private let storageURL: URL
    private let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")
    
    // MARK: - Singleton
    
    static let shared = GeoHashIndex()
    
    // MARK: - Initialization
    
    init(precision: Int = 6) {  // ~1km precision by default
        self.precision = precision
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DynamicAI", isDirectory: true)
        self.storageURL = dir.appendingPathComponent("geohash_index.json")
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        // Load existing index from disk on startup
        loadFromDisk()
    }
    
    // MARK: - Build Index
    
    /// Build geohash index from Photos library
    /// ~3 seconds for 10,000 photos, no network calls
    func buildIndex(onProgress: ((Int, Int) -> Void)? = nil) async -> IndexStats {
        let start = CFAbsoluteTimeGetCurrent()
        
        // Load existing index first
        loadFromDisk()
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        let allAssets = PHAsset.fetchAssets(with: fetchOptions)
        let total = allAssets.count
        var indexed = 0
        var skipped = 0
        var withLocation = 0
        
        allAssets.enumerateObjects { [self] asset, idx, _ in
            let assetId = asset.localIdentifier
            
            // Skip if already indexed
            if indexedAssets.contains(assetId) {
                skipped += 1
                return
            }
            
            guard let location = asset.location else { return }
            
            let hash = encodeGeohash(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                precision: precision
            )
            
            // Store full hash for this asset
            assetGeohash[assetId] = hash
            
            // Index by all prefix lengths (4 to precision) for flexible radius search
            for length in 4...precision {
                let prefix = String(hash.prefix(length))
                if index[prefix] == nil {
                    index[prefix] = []
                }
                index[prefix]?.insert(assetId)
            }
            
            indexedAssets.insert(assetId)
            indexed += 1
            withLocation += 1
            
            // Progress callback every 100 photos
            if idx % 100 == 0 {
                onProgress?(idx, total)
            }
        }
        
        // Save to disk
        saveToDisk()
        
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        return IndexStats(
            totalPhotos: total,
            photosWithLocation: withLocation,
            newlyIndexed: indexed,
            skipped: skipped,
            uniqueGeohashes: index.count,
            buildTimeSeconds: elapsed
        )
    }
    
    /// Incremental update - only index new photos
    func updateIndex() async -> IndexStats {
        return await buildIndex()  // buildIndex already skips existing
    }
    
    // MARK: - Search
    
    /// Search by place name - geocodes first, then O(1) lookup
    func search(placeName: String, radiusKm: Double = 1.0) async throws -> [String] {
        let geocoder = CLGeocoder()
        
        // 1. Try direct geocoding first
        if let location = try? await geocoder.geocodeAddressString(placeName).first?.location {
            print("[GeoSearch] Direct geocode success: '\(placeName)'")
            return searchByCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                radiusKm: radiusKm
            )
        }
        
        print("[GeoSearch] Direct geocode failed for '\(placeName)', trying LLM resolution...")
        
        // 2. Ask LLM to resolve the location (e.g., "Miraggio hotel" → "Paliouri, Halkidiki, Greece")
        if let resolvedLocation = await resolveLocationWithLLM(placeName) {
            print("[GeoSearch] LLM resolved '\(placeName)' → '\(resolvedLocation)'")
            
            // Try the full resolved location
            if let location = try? await geocoder.geocodeAddressString(resolvedLocation).first?.location {
                print("[GeoSearch] Resolved geocode success")
                return searchByCoordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    radiusKm: max(radiusKm, 20.0)  // 20km radius - LLM might give nearby town
                )
            }
            
            // Fallback: try just the region (e.g., "Halkidiki, Greece" from "Paliouri, Halkidiki, Greece")
            let parts = resolvedLocation.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                let regionSearch = parts.dropFirst().joined(separator: ", ")
                print("[GeoSearch] Trying region fallback: '\(regionSearch)'")
                if let location = try? await geocoder.geocodeAddressString(regionSearch).first?.location {
                    print("[GeoSearch] Region geocode success")
                    return searchByCoordinate(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        radiusKm: max(radiusKm, 50.0)  // 50km radius for region-level search
                    )
                }
            }
        }
        
        // 3. Last resort: Ask LLM for GPS coordinates directly
        if let coords = await getCoordinatesFromLLM(placeName) {
            print("[GeoSearch] LLM provided coordinates: \(coords.latitude), \(coords.longitude)")
            return searchByCoordinate(
                latitude: coords.latitude,
                longitude: coords.longitude,
                radiusKm: max(radiusKm, 25.0)  // 25km radius for LLM-estimated coords
            )
        }
        
        throw GeoHashError.locationNotFound(placeName)
    }
    
    /// Search by coordinates - O(1) geohash lookup
    func searchByCoordinate(latitude: Double, longitude: Double, radiusKm: Double = 1.0) -> [String] {
        // Determine precision based on radius
        let searchPrecision = precisionForRadius(radiusKm)
        
        let targetHash = encodeGeohash(latitude: latitude, longitude: longitude, precision: searchPrecision)
        let prefix = String(targetHash.prefix(searchPrecision))
        
        // Get all assets in this geohash cell + neighbors
        var results = Set<String>()
        
        // Add exact cell
        if let assets = index[prefix] {
            results.formUnion(assets)
        }
        
        // Add 8 neighboring cells for edge cases
        for neighbor in geohashNeighbors(prefix) {
            if let assets = index[neighbor] {
                results.formUnion(assets)
            }
        }
        
        return Array(results)
    }

    
    // MARK: - LLM Location Resolution
    
    /// Ask LLM to resolve an ambiguous location name to a geocodable address
    /// e.g., "Miraggio hotel" → "Halkidiki, Greece"
    private func resolveLocationWithLLM(_ placeName: String) async -> String? {
        let prompt = """
        Where exactly is "\(placeName)" located?
        
        If it's a hotel, resort, or venue, tell me the EXACT nearest town/village AND region.
        
        Format your answer as: "Town, Region, Country"
        Examples:
        - "Paliouri, Halkidiki, Greece" (for Miraggio hotel)
        - "Oia, Santorini, Greece"
        - "Courchevel, Savoie, France"
        
        IMPORTANT: Only answer if you are 100% certain. If you're not sure or don't know, say exactly: UNKNOWN
        
        Answer:
        """
        
        do {
            let response = try await GroqService.shared.chat(
                message: prompt,
                systemPrompt: "You are a travel expert with precise knowledge of hotel and resort locations. Only give answers you are certain about."
            )
            
            let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "Answer:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if cleaned != "UNKNOWN" && !cleaned.contains("UNKNOWN") && 
               !cleaned.contains("not sure") && !cleaned.contains("don't know") &&
               cleaned.count > 3 && cleaned.count < 100 {
                return cleaned
            }
        } catch {
            print("[GeoSearch] LLM resolution failed: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    /// Ask LLM for GPS coordinates when all else fails
    /// Returns approximate coordinates for the location
    private func getCoordinatesFromLLM(_ placeName: String) async -> CLLocationCoordinate2D? {
        let prompt = """
        What are the approximate GPS coordinates (latitude, longitude) of "\(placeName)"?
        
        Reply with ONLY two decimal numbers separated by a comma, like: 39.926, 23.706
        
        If you don't know or it's not a real place, reply with exactly: UNKNOWN
        """
        
        do {
            let response = try await GroqService.shared.chat(
                message: prompt,
                systemPrompt: "You are a geography expert. Provide GPS coordinates accurately."
            )
            
            let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if text != "UNKNOWN" && !text.contains("UNKNOWN") {
                let parts = text.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                
                if parts.count >= 2,
                   let lat = Double(parts[0].filter { $0.isNumber || $0 == "." || $0 == "-" }),
                   let lon = Double(parts[1].filter { $0.isNumber || $0 == "." || $0 == "-" }),
                   lat >= -90 && lat <= 90,
                   lon >= -180 && lon <= 180 {
                    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
            }
        } catch {
            print("[GeoSearch] LLM coordinates failed: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    /// Get all unique locations (for debugging/stats)
    func getAllLocations() -> [(geohash: String, count: Int)] {
        // Return only the highest precision level to avoid duplicates
        return index
            .filter { $0.key.count == precision }
            .map { (geohash: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }
    
    // MARK: - Geohash Encoding
    
    /// Encode latitude/longitude to geohash string
    func encodeGeohash(latitude: Double, longitude: Double, precision: Int) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bit = 0
        var ch = 0
        var isLon = true
        
        while hash.count < precision {
            if isLon {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid {
                    ch = ch | (1 << (4 - bit))
                    lonRange.0 = mid
                } else {
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid {
                    ch = ch | (1 << (4 - bit))
                    latRange.0 = mid
                } else {
                    latRange.1 = mid
                }
            }
            
            isLon.toggle()
            bit += 1
            
            if bit == 5 {
                hash.append(base32[ch])
                bit = 0
                ch = 0
            }
        }
        
        return hash
    }
    
    /// Decode geohash to approximate center coordinates
    func decodeGeohash(_ hash: String) -> (latitude: Double, longitude: Double)? {
        guard !hash.isEmpty else { return nil }
        
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var isLon = true
        
        for char in hash {
            guard let idx = base32.firstIndex(of: char) else { return nil }
            let bits = idx
            
            for i in (0..<5).reversed() {
                let bit = (bits >> i) & 1
                if isLon {
                    let mid = (lonRange.0 + lonRange.1) / 2
                    if bit == 1 {
                        lonRange.0 = mid
                    } else {
                        lonRange.1 = mid
                    }
                } else {
                    let mid = (latRange.0 + latRange.1) / 2
                    if bit == 1 {
                        latRange.0 = mid
                    } else {
                        latRange.1 = mid
                    }
                }
                isLon.toggle()
            }
        }
        
        return (
            latitude: (latRange.0 + latRange.1) / 2,
            longitude: (lonRange.0 + lonRange.1) / 2
        )
    }
    
    // MARK: - Helpers
    
    /// Determine geohash precision based on search radius
    private func precisionForRadius(_ km: Double) -> Int {
        switch km {
        case ..<0.1: return 7   // ~150m
        case ..<1.0: return 6   // ~1km
        case ..<5.0: return 5   // ~5km
        case ..<40.0: return 4  // ~40km
        default: return 3       // ~150km
        }
    }
    
    /// Get neighboring geohash cells (for edge case handling)
    private func geohashNeighbors(_ hash: String) -> [String] {
        guard !hash.isEmpty else { return [] }
        
        // Decode center, then encode 8 surrounding points
        guard let center = decodeGeohash(hash) else { return [] }
        
        // Approximate cell size based on hash length
        let latDelta: Double
        let lonDelta: Double
        switch hash.count {
        case 1: latDelta = 23.0; lonDelta = 45.0
        case 2: latDelta = 2.8; lonDelta = 5.6
        case 3: latDelta = 0.7; lonDelta = 0.7
        case 4: latDelta = 0.087; lonDelta = 0.175
        case 5: latDelta = 0.022; lonDelta = 0.022
        case 6: latDelta = 0.0027; lonDelta = 0.0055
        case 7: latDelta = 0.00068; lonDelta = 0.00068
        default: latDelta = 0.0001; lonDelta = 0.0001
        }
        
        var neighbors: [String] = []
        let precision = hash.count
        
        for latOffset in [-1, 0, 1] {
            for lonOffset in [-1, 0, 1] {
                if latOffset == 0 && lonOffset == 0 { continue }
                
                let lat = center.latitude + Double(latOffset) * latDelta
                let lon = center.longitude + Double(lonOffset) * lonDelta
                
                // Clamp to valid ranges
                let clampedLat = max(-90, min(90, lat))
                let clampedLon = max(-180, min(180, lon))
                
                let neighborHash = encodeGeohash(latitude: clampedLat, longitude: clampedLon, precision: precision)
                if neighborHash != hash {
                    neighbors.append(neighborHash)
                }
            }
        }
        
        return Array(Set(neighbors))  // Remove duplicates
    }
    
    // MARK: - Persistence
    
    private func saveToDisk() {
        let data = GeoHashData(
            index: index.mapValues { Array($0) },
            assetGeohash: assetGeohash,
            indexedAssets: Array(indexedAssets)
        )
        
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: storageURL)
        } catch {
            print("GeoHashIndex: Failed to save - \(error)")
        }
    }
    
    func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(GeoHashData.self, from: data) else {
            return
        }
        
        index = decoded.index.mapValues { Set($0) }
        assetGeohash = decoded.assetGeohash
        indexedAssets = Set(decoded.indexedAssets)
    }
    
    /// Clear all index data
    func clear() {
        index = [:]
        assetGeohash = [:]
        indexedAssets = []
        try? FileManager.default.removeItem(at: storageURL)
    }
    
    // MARK: - Stats
    
    var stats: (photosIndexed: Int, uniqueCells: Int, isLoaded: Bool) {
        (indexedAssets.count, index.filter { $0.key.count == precision }.count, !index.isEmpty)
    }
}

// MARK: - Data Models

struct GeoHashData: Codable {
    let index: [String: [String]]
    let assetGeohash: [String: String]
    let indexedAssets: [String]
}

struct IndexStats {
    let totalPhotos: Int
    let photosWithLocation: Int
    let newlyIndexed: Int
    let skipped: Int
    let uniqueGeohashes: Int
    let buildTimeSeconds: Double
    
    var summary: String {
        String(format: "Indexed %d/%d photos with location (%d new, %d skipped) in %.2fs",
               photosWithLocation, totalPhotos, newlyIndexed, skipped, buildTimeSeconds)
    }
}

enum GeoHashError: Error, LocalizedError {
    case locationNotFound(String)
    case notAuthorized
    
    var errorDescription: String? {
        switch self {
        case .locationNotFound(let place):
            return "Could not find location: \(place)"
        case .notAuthorized:
            return "Photos access not authorized"
        }
    }
}
