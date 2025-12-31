// MARK: - Smart Photo Search
// Orchestrates all lightweight indexes for fast photo search
// No embeddings, no vectors - just smart filtering
//
// Flow:
// 1. LLM parses query → structured filters
// 2. Geohash index → location filter (O(1))
// 3. Label index → visual filter (O(1))
// 4. PHAsset → date/people filter (native)
// 5. Return matching photos

import Foundation
import Photos
import AppKit

/// Smart photo search combining all lightweight indexes
actor SmartPhotoSearch {
    
    // MARK: - Dependencies
    
    private let queryParser = SmartQueryParser()
    private let geoIndex: GeoHashIndex
    private let labelIndex: LabelIndex
    private let photosProvider: PhotosProvider
    
    // MARK: - Singleton
    
    static let shared = SmartPhotoSearch()
    
    // MARK: - Initialization
    
    init() {
        self.geoIndex = GeoHashIndex.shared
        self.labelIndex = LabelIndex.shared
        self.photosProvider = PhotosProvider()
    }
    
    // MARK: - Search
    
    /// Search photos with natural language query
    /// Returns asset IDs matching the query
    func search(_ query: String) async throws -> PhotoSearchResponse {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // 1. Parse query with LLM (~100ms)
        let parsed = await queryParser.parse(query)
        
        var candidateIds: Set<String>? = nil
        var appliedFilters: [String] = []
        var hasRequestedContentFilter = false  // Track if user REQUESTED a content filter (location/labels/date)
        
        // 2. Location filter via Geohash
        if parsed.hasLocation, let location = parsed.location {
            hasRequestedContentFilter = true  // User wanted location-based search
            
            // Build search location, avoiding duplicate hints (e.g., "Miraggio hotel hotel")
            var searchLocation = location
            if let hint = parsed.locationHint, 
               !location.lowercased().contains(hint.lowercased()) {
                searchLocation = "\(location) \(hint)"
            }
            
            do {
                let locationIds = try await geoIndex.search(placeName: searchLocation, radiusKm: 2.0)
                print("[SmartPhotoSearch] Location search found \(locationIds.count) photos")
                
                // Cluster into trips and return most recent (unless user specified a date)
                if !parsed.hasTimePeriod && locationIds.count > 10 {
                    let (tripIds, tripCount, tripDates) = clusterIntoTrips(assetIds: Set(locationIds), maxGapDays: 5)
                    candidateIds = tripIds
                    if tripCount > 1 {
                        appliedFilters.append("location: \(location) → \(tripIds.count) photos from \(tripDates) (1 of \(tripCount) trips)")
                    } else {
                        appliedFilters.append("location: \(location) (\(tripIds.count) matches)")
                    }
                } else {
                    candidateIds = Set(locationIds)
                    appliedFilters.append("location: \(location) (\(locationIds.count) matches)")
                }
            } catch {
                // Location not found - set empty candidates (not nil) to indicate filter was attempted
                candidateIds = []
                appliedFilters.append("location: \(location) (not found)")
            }
        }
        
        // 3. Label filter via Vision index
        // Skip if location already found good results (labels are often inferred, not explicit)
        let locationFoundResults = candidateIds != nil && !candidateIds!.isEmpty
        if parsed.hasLabels, let labels = parsed.labels, !locationFoundResults {
            hasRequestedContentFilter = true  // User wanted label-based search
            
            // Expand high-level concepts (outdoor, travel) to actual Vision labels
            let expandedLabels = await labelIndex.expandSearchTerms(labels)
            print("[SmartPhotoSearch] Labels: \(labels) → Expanded: \(expandedLabels)")
            
            let labelIds = await labelIndex.searchAny(labels: expandedLabels)
            let indexStats = await labelIndex.stats
            print("[SmartPhotoSearch] Label index has \(indexStats.photosIndexed) photos, \(indexStats.uniqueLabels) labels")
            print("[SmartPhotoSearch] Label search found \(labelIds.count) photos")
            
            if candidateIds == nil {
                candidateIds = Set(labelIds)
            } else if !labelIds.isEmpty {
                candidateIds = candidateIds?.intersection(Set(labelIds))
            }
            // If candidateIds was empty (from failed location) and labelIds is also empty, stay empty
            appliedFilters.append("labels: \(labels.joined(separator: ", ")) → [\(expandedLabels.prefix(5).joined(separator: ", "))] (\(labelIds.count) matches)")
        }
        
        // 4. Date filter using PHFetchOptions (fast, native)
        if parsed.hasTimePeriod, let dateInterval = parsed.timePeriod?.toDateInterval() {
            hasRequestedContentFilter = true  // User wanted date-based search
            let dateFiltered = filterByDate(candidates: candidateIds, interval: dateInterval)
            candidateIds = dateFiltered
            appliedFilters.append("date: \(parsed.timePeriod?.description ?? "") (\(dateFiltered.count) matches)")
        }
        
        // 5. People filter using Photos.app face recognition
        if parsed.hasPeople, let people = parsed.people {
            let peopleFiltered = await filterByPeople(candidates: candidateIds, names: people)
            candidateIds = peopleFiltered
            appliedFilters.append("people: \(people.joined(separator: ", ")) (\(peopleFiltered.count) matches)")
        }
        
        // 6. "My photos" filter - photos where user appears
        // ONLY apply if:
        //   - It's explicitly requested AND
        //   - Either we have non-empty candidates, OR no content filters were requested (pure selfie request)
        if parsed.isMyPhotos {
            let hasCandidates = candidateIds != nil && !candidateIds!.isEmpty
            if hasCandidates || !hasRequestedContentFilter {
                let myPhotoIds = await filterMyPhotos(candidates: candidateIds)
                candidateIds = myPhotoIds
                appliedFilters.append("my photos (\(myPhotoIds.count) matches)")
            } else {
                // Content filter was requested but found no results - don't fall back to all selfies
                appliedFilters.append("my photos (skipped - content filters found no matches)")
            }
        }
        
        // 7. Media type filter
        if parsed.mediaType != "all" {
            let typeFiltered = filterByMediaType(
                candidates: candidateIds,
                type: parsed.mediaType == "video" ? .video : .image
            )
            candidateIds = typeFiltered
            appliedFilters.append("type: \(parsed.mediaType)")
        }
        
        // 8. Apply limit
        var finalIds = Array(candidateIds ?? [])
        if let limit = parsed.limit, finalIds.count > limit {
            finalIds = Array(finalIds.prefix(limit))
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        return PhotoSearchResponse(
            assetIds: finalIds,
            query: query,
            parsedQuery: parsed,
            appliedFilters: appliedFilters,
            searchTimeMs: elapsed * 1000
        )
    }
    
    /// Fetch PHAssets from search results
    func fetchAssets(from response: PhotoSearchResponse) -> [PHAsset] {
        guard !response.assetIds.isEmpty else { return [] }
        
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: response.assetIds,
            options: nil
        )
        
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        
        // Sort by creation date (newest first)
        return assets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }
    
    /// Combined search + fetch for convenience
    func searchAndFetch(_ query: String) async throws -> (assets: [PHAsset], response: PhotoSearchResponse) {
        let response = try await search(query)
        let assets = fetchAssets(from: response)
        return (assets, response)
    }
    
    // MARK: - Filters
    
    /// Filter by date using PHFetchOptions
    private func filterByDate(candidates: Set<String>?, interval: DateInterval) -> Set<String> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            interval.start as NSDate,
            interval.end as NSDate
        )
        
        // If candidates is nil, no previous filter was applied - get all in date range
        // If candidates is empty, a previous filter found nothing - return empty
        guard let candidateIds = candidates else {
            // No previous filter - get all in date range
            let result = PHAsset.fetchAssets(with: options)
            var filtered = Set<String>()
            result.enumerateObjects { asset, _, _ in
                filtered.insert(asset.localIdentifier)
            }
            return filtered
        }
        
        // Previous filter was applied - if empty, stay empty
        guard !candidateIds.isEmpty else {
            return []
        }
        
        // Filter only from candidates
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(candidateIds), options: nil)
        var filtered = Set<String>()
        
        result.enumerateObjects { asset, _, _ in
            if let date = asset.creationDate,
               date >= interval.start && date <= interval.end {
                filtered.insert(asset.localIdentifier)
            }
        }
        return filtered
    }
    
    /// Filter by people using Photos.app face recognition
    private func filterByPeople(candidates: Set<String>?, names: [String]) async -> Set<String> {
        var results = Set<String>()
        
        for name in names {
            let photos = await photosProvider.fetchPhotosOfPerson(name: name, limit: 10000, mediaType: nil)
            for asset in photos {
                if candidates == nil || candidates!.contains(asset.localIdentifier) {
                    results.insert(asset.localIdentifier)
                }
            }
        }
        
        return results
    }
    
    /// Filter for "my photos" - photos where main person appears
    private func filterMyPhotos(candidates: Set<String>?) async -> Set<String> {
        let myPhotos = await photosProvider.fetchMyPhotos(limit: 10000, mediaType: nil)
        let myPhotoIds = Set(myPhotos.map { $0.localIdentifier })
        
        if let candidates = candidates {
            return candidates.intersection(myPhotoIds)
        }
        return myPhotoIds
    }
    
    /// Filter by media type
    private func filterByMediaType(candidates: Set<String>?, type: PHAssetMediaType) -> Set<String> {
        // If candidates is nil, no previous filter was applied - get all of this type
        // If candidates is empty, a previous filter found nothing - return empty
        guard let candidateIds = candidates else {
            // No previous filter - get all of this type
            let options = PHFetchOptions()
            let result = PHAsset.fetchAssets(with: type, options: options)
            var filtered = Set<String>()
            result.enumerateObjects { asset, _, _ in
                filtered.insert(asset.localIdentifier)
            }
            return filtered
        }
        
        // Previous filter was applied - if empty, stay empty
        guard !candidateIds.isEmpty else {
            return []
        }
        
        // Filter candidates by type
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(candidateIds), options: nil)
        var filtered = Set<String>()
        result.enumerateObjects { asset, _, _ in
            if asset.mediaType == type {
                filtered.insert(asset.localIdentifier)
            }
        }
        return filtered
    }

    
    /// Cluster photos by time into "trips" and return the most recent trip
    /// A trip is a group of photos taken within maxGapDays of each other
    private func clusterIntoTrips(assetIds: Set<String>, maxGapDays: Int = 3) -> (tripIds: Set<String>, tripCount: Int, tripDates: String) {
        guard !assetIds.isEmpty else {
            return ([], 0, "")
        }
        
        // Fetch assets with creation dates
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(assetIds), options: nil)
        var assetsWithDates: [(id: String, date: Date)] = []
        
        fetchResult.enumerateObjects { asset, _, _ in
            if let date = asset.creationDate {
                assetsWithDates.append((asset.localIdentifier, date))
            }
        }
        
        guard !assetsWithDates.isEmpty else {
            return (assetIds, 1, "unknown dates")
        }
        
        // Sort by date (newest first)
        assetsWithDates.sort { $0.date > $1.date }
        
        // Cluster into trips: photos within maxGapDays of each other belong to same trip
        var trips: [[String]] = []
        var currentTrip: [String] = []
        var lastDate: Date?
        
        for (id, date) in assetsWithDates {
            if let last = lastDate {
                let daysBetween = abs(Calendar.current.dateComponents([.day], from: date, to: last).day ?? 0)
                if daysBetween > maxGapDays {
                    // Start new trip
                    if !currentTrip.isEmpty {
                        trips.append(currentTrip)
                    }
                    currentTrip = [id]
                } else {
                    currentTrip.append(id)
                }
            } else {
                currentTrip.append(id)
            }
            lastDate = date
        }
        
        // Don't forget the last trip
        if !currentTrip.isEmpty {
            trips.append(currentTrip)
        }
        
        // Return the most recent trip (first one since we sorted newest first)
        guard let mostRecentTrip = trips.first else {
            return (assetIds, 1, "unknown")
        }
        
        // Get date range for the trip
        let tripAssets = assetsWithDates.filter { mostRecentTrip.contains($0.id) }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        
        var tripDates = ""
        if let oldest = tripAssets.last?.date, let newest = tripAssets.first?.date {
            if Calendar.current.isDate(oldest, inSameDayAs: newest) {
                tripDates = formatter.string(from: newest)
            } else {
                tripDates = "\(formatter.string(from: oldest)) - \(formatter.string(from: newest))"
            }
        }
        
        print("[SmartPhotoSearch] Found \(trips.count) trips, returning most recent: \(mostRecentTrip.count) photos from \(tripDates)")
        
        return (Set(mostRecentTrip), trips.count, tripDates)
    }
    
    // MARK: - Index Management
    
    /// Build both indexes
    func buildIndexes(onProgress: @escaping (String, Int, Int) -> Void) async -> (geo: IndexStats, labels: LabelIndexStats) {
        // Build geohash index first (fast, ~3 seconds)
        onProgress("Building location index...", 0, 100)
        let geoStats = await geoIndex.buildIndex { current, total in
            onProgress("Indexing locations", current, total)
        }
        
        // Build label index (slower, background)
        onProgress("Building label index...", 0, 100)
        let labelStats = await labelIndex.buildIndex { current, total, label in
            onProgress("Classifying: \(label)", current, total)
        }
        
        return (geoStats, labelStats)
    }
    
    /// Get index statistics
    func getStats() async -> SearchStats {
        let geoStats = await geoIndex.stats
        let labelStats = await labelIndex.stats
        
        return SearchStats(
            geoIndex: SearchStats.IndexInfo(
                photosIndexed: geoStats.photosIndexed,
                uniqueKeys: geoStats.uniqueCells,
                isLoaded: geoStats.isLoaded
            ),
            labelIndex: SearchStats.IndexInfo(
                photosIndexed: labelStats.photosIndexed,
                uniqueKeys: labelStats.uniqueLabels,
                isLoaded: labelStats.isLoaded
            )
        )
    }
    
    /// Load indexes from disk
    func loadIndexes() async {
        await geoIndex.loadFromDisk()
        await labelIndex.loadFromDisk()
    }
}

// MARK: - Response Models

struct PhotoSearchResponse {
    let assetIds: [String]
    let query: String
    let parsedQuery: ParsedPhotoQuery
    let appliedFilters: [String]
    let searchTimeMs: Double
    
    var isEmpty: Bool { assetIds.isEmpty }
    var count: Int { assetIds.count }
    
    var summary: String {
        if isEmpty {
            return "No photos found for '\(query)'"
        }
        return "Found \(count) photos in \(String(format: "%.0f", searchTimeMs))ms"
    }
    
    var debugInfo: String {
        """
        Query: \(query)
        Parsed: location=\(parsedQuery.location ?? "none"), labels=\(parsedQuery.labels?.joined(separator: ",") ?? "none")
        Filters: \(appliedFilters.joined(separator: " → "))
        Results: \(count) photos in \(String(format: "%.1f", searchTimeMs))ms
        """
    }
}

struct SearchStats {
    struct IndexInfo {
        let photosIndexed: Int
        let uniqueKeys: Int
        let isLoaded: Bool
    }
    
    let geoIndex: IndexInfo
    let labelIndex: IndexInfo
    
    var summary: String {
        """
        GeoHash: \(geoIndex.photosIndexed) photos, \(geoIndex.uniqueKeys) locations
        Labels: \(labelIndex.photosIndexed) photos, \(labelIndex.uniqueKeys) labels
        """
    }
    
    var isReady: Bool {
        geoIndex.isLoaded || labelIndex.isLoaded
    }
}

// MARK: - Convenience Extensions

extension SmartPhotoSearch {
    
    /// Quick search returning just assets
    func quickSearch(_ query: String) async -> [PHAsset] {
        do {
            let (assets, _) = try await searchAndFetch(query)
            return assets
        } catch {
            print("SmartPhotoSearch: Error - \(error)")
            return []
        }
    }
    
    /// Search by location only (no LLM, direct geohash)
    func searchByLocation(_ place: String, radiusKm: Double = 2.0) async throws -> [PHAsset] {
        let ids = try await geoIndex.search(placeName: place, radiusKm: radiusKm)
        return fetchAssets(from: PhotoSearchResponse(
            assetIds: ids,
            query: place,
            parsedQuery: ParsedPhotoQuery(
                location: place, locationHint: nil, timePeriod: nil,
                labels: nil, people: nil, isMyPhotos: false,
                mediaType: "all", limit: nil, searchTerms: place
            ),
            appliedFilters: ["location: \(place)"],
            searchTimeMs: 0
        ))
    }
    
    /// Search by label only (no LLM, direct label index)
    func searchByLabel(_ label: String) async -> [PHAsset] {
        let ids = await labelIndex.search(label: label)
        return fetchAssets(from: PhotoSearchResponse(
            assetIds: ids,
            query: label,
            parsedQuery: ParsedPhotoQuery(
                location: nil, locationHint: nil, timePeriod: nil,
                labels: [label], people: nil, isMyPhotos: false,
                mediaType: "all", limit: nil, searchTerms: label
            ),
            appliedFilters: ["label: \(label)"],
            searchTimeMs: 0
        ))
    }
}
