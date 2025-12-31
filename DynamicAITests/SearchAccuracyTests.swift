import XCTest
import Photos
import CoreLocation
@testable import DynamicAI

/// Integration tests that verify actual search accuracy against ground truth
/// These tests require the photo index to be populated with real data
final class SearchAccuracyTests: XCTestCase {
    
    // MARK: - Ground Truth Data
    
    /// GPS coordinates for Miraggio Thermal Spa Resort, Halkidiki, Greece
    /// lat: ~39.926, lon: ~23.706
    static let miraggioLatRange = 39.9...40.3
    static let miraggioLonRange = 23.0...24.0
    
    /// Minimum acceptable accuracy for search results
    static let requiredAccuracy = 0.9  // 90%
    
    // MARK: - Helper Methods
    
    /// Check if a coordinate is in the Miraggio area
    func isInMiraggioArea(_ lat: Double, _ lon: Double) -> Bool {
        return Self.miraggioLatRange.contains(lat) && Self.miraggioLonRange.contains(lon)
    }
    
    /// Load ground truth photo IDs from the index
    func loadMiraggioPhotoIds() async -> Set<String> {
        var miraggioIds = Set<String>()
        
        let indexService = PhotoIndexService.shared
        let allPhotos = indexService.getAllIndexedPhotos()
        
        for entry in allPhotos {
            guard let lat = entry.source.latitude,
                  let lon = entry.source.longitude else { continue }
            if isInMiraggioArea(lat, lon) {
                miraggioIds.insert(entry.photoId)
            }
        }
        
        return miraggioIds
    }
    
    /// Load ground truth photo IDs that have faces (for "my photos" queries)
    func loadMiraggioPhotosWithFaces() async -> Set<String> {
        var miraggioWithFaces = Set<String>()
        
        let indexService = PhotoIndexService.shared
        let allPhotos = indexService.getAllIndexedPhotos()
        
        for entry in allPhotos {
            guard let lat = entry.source.latitude,
                  let lon = entry.source.longitude else { continue }
            if isInMiraggioArea(lat, lon) {
                // Check if photo has faces
                if entry.visionAnalysis?.faceCount ?? 0 > 0 {
                    miraggioWithFaces.insert(entry.photoId)
                }
            }
        }
        
        return miraggioWithFaces
    }
    
    // MARK: - Search Accuracy Tests
    
    /// Test: "photos from Miraggio hotel" should return photos from that GPS area
    func testLocationSearchAccuracy_MiraggioHotel() async throws {
        let groundTruth = await loadMiraggioPhotoIds()
        
        // Skip if no ground truth data
        guard groundTruth.count > 0 else {
            throw XCTSkip("No Miraggio photos in index - run indexer first")
        }
        
        print("Ground truth: \(groundTruth.count) photos from Miraggio area")
        
        // Perform semantic search
        let indexService = PhotoIndexService.shared
        let searchResults = await indexService.semanticSearch(query: "Miraggio hotel resort Greece", limit: 50)
        
        // Calculate precision: how many results are actually from Miraggio?
        var truePositives = 0
        var falsePositives = 0
        
        for result in searchResults {
            guard let lat = result.entry.source.latitude,
                  let lon = result.entry.source.longitude else {
                falsePositives += 1
                continue
            }
            
            if isInMiraggioArea(lat, lon) {
                truePositives += 1
            } else {
                falsePositives += 1
                print("False positive: \(result.entry.photoId) at (\(lat), \(lon))")
            }
        }
        
        let precision = searchResults.isEmpty ? 0 : Double(truePositives) / Double(searchResults.count)
        let recall = groundTruth.isEmpty ? 0 : Double(truePositives) / Double(min(groundTruth.count, searchResults.count))
        
        print("Search results: \(searchResults.count)")
        print("True positives: \(truePositives)")
        print("False positives: \(falsePositives)")
        print("Precision: \(String(format: "%.1f%%", precision * 100))")
        print("Recall (capped): \(String(format: "%.1f%%", recall * 100))")
        
        XCTAssertGreaterThanOrEqual(precision, Self.requiredAccuracy, 
            "Location search precision (\(String(format: "%.1f%%", precision * 100))) should be >= \(Self.requiredAccuracy * 100)%")
    }
    
    /// Test: Fuzzy location matching - "Miraggion" should still find Miraggio photos
    func testLocationSearchAccuracy_FuzzyTypo() async throws {
        let groundTruth = await loadMiraggioPhotoIds()
        
        guard groundTruth.count > 0 else {
            throw XCTSkip("No Miraggio photos in index - run indexer first")
        }
        
        // Search with typo
        let indexService = PhotoIndexService.shared
        let searchResults = await indexService.semanticSearch(query: "Miraggion hotel", limit: 30)
        
        var truePositives = 0
        for result in searchResults {
            guard let lat = result.entry.source.latitude,
                  let lon = result.entry.source.longitude else { continue }
            if isInMiraggioArea(lat, lon) {
                truePositives += 1
            }
        }
        
        let precision = searchResults.isEmpty ? 0 : Double(truePositives) / Double(searchResults.count)
        
        print("Fuzzy search 'Miraggion' precision: \(String(format: "%.1f%%", precision * 100))")
        
        // Typo search may have lower accuracy but should still work
        XCTAssertGreaterThan(precision, 0.5, 
            "Fuzzy location search should find at least 50% correct results")
    }
    
    /// Test: "photos of my vacation" should NOT trigger person filtering  
    func testQueryParsing_PhotosOfMyVacation() {
        // This is a parsing test, not a search accuracy test
        let parsed = PhotoQueryParser.parse("show me photos of my vacation in Miraggio hotel")
        
        XCTAssertFalse(parsed.isMyPhotosRequest, 
            "'photos of my vacation' should NOT be interpreted as 'my photos'")
        XCTAssertNotNil(parsed.location, 
            "Should extract location from query")
    }
    
    /// Test: "my photos from Miraggio" SHOULD trigger person filtering
    func testQueryParsing_MyPhotosFrom() {
        let parsed = PhotoQueryParser.parse("show me my photos from Miraggio hotel")
        
        XCTAssertTrue(parsed.isMyPhotosRequest, 
            "'my photos from' SHOULD be interpreted as 'my photos'")
        XCTAssertNotNil(parsed.location, 
            "Should extract location from query")
    }
    
    // MARK: - End-to-End Query Tests
    
    /// Test the full query flow: "photos of my vacation in Miraggio hotel"
    func testEndToEnd_PhotosOfMyVacation() async throws {
        let query = "show me photos of my vacation in Miraggio hotel"
        let parsed = PhotoQueryParser.parse(query)
        
        // 1. Query should NOT trigger "my photos" filter
        XCTAssertFalse(parsed.isMyPhotosRequest)
        
        // 2. Location should be extracted
        XCTAssertNotNil(parsed.location)
        
        // 3. Search should return photos from that location (not filtered by person)
        let indexService = PhotoIndexService.shared
        let searchResults = await indexService.semanticSearch(query: "vacation Miraggio hotel", limit: 30)
        
        guard !searchResults.isEmpty else {
            throw XCTSkip("No search results - index may be empty")
        }
        
        // Verify results are from Miraggio area
        var correctResults = 0
        for result in searchResults {
            guard let lat = result.entry.source.latitude,
                  let lon = result.entry.source.longitude else { continue }
            if isInMiraggioArea(lat, lon) {
                correctResults += 1
            }
        }
        
        let accuracy = Double(correctResults) / Double(searchResults.count)
        print("'photos of my vacation in Miraggio' accuracy: \(String(format: "%.1f%%", accuracy * 100))")
        
        XCTAssertGreaterThanOrEqual(accuracy, Self.requiredAccuracy,
            "Should return photos from Miraggio with >= 90% accuracy")
    }
    
    /// Test the full query flow: "my photos from Miraggio hotel"  
    func testEndToEnd_MyPhotosFromMiraggio() async throws {
        let query = "show me my photos from Miraggio hotel"
        let parsed = PhotoQueryParser.parse(query)
        
        // 1. Query SHOULD trigger "my photos" filter
        XCTAssertTrue(parsed.isMyPhotosRequest)
        
        // 2. Location should be extracted
        XCTAssertNotNil(parsed.location)
        
        // When forceMyPhotosFilter is true, the search will use PhotosProvider.fetchMyPhotos()
        // which filters for photos with the main person present
        // This is harder to test without full integration, so we verify the parsing is correct
    }
    
    // MARK: - Statistics Test
    
    /// Report overall search accuracy statistics
    func testSearchAccuracyStatistics() async throws {
        let groundTruthTotal = await loadMiraggioPhotoIds()
        let groundTruthWithFaces = await loadMiraggioPhotosWithFaces()
        
        guard groundTruthTotal.count > 0 else {
            throw XCTSkip("No Miraggio photos in index")
        }
        
        print("=" * 50)
        print("📊 Search Accuracy Statistics")
        print("=" * 50)
        print("Ground truth - Miraggio photos: \(groundTruthTotal.count)")
        print("Ground truth - Miraggio with faces: \(groundTruthWithFaces.count)")
        print("")
        
        // Test various queries
        let queries = [
            "Miraggio hotel",
            "Miraggio resort Greece",
            "hotel in Greece",
            "vacation resort"
        ]
        
        let indexService = PhotoIndexService.shared
        
        for query in queries {
            let results = await indexService.semanticSearch(query: query, limit: 30)
            var correct = 0
            for r in results {
                guard let lat = r.entry.source.latitude,
                      let lon = r.entry.source.longitude else { continue }
                if isInMiraggioArea(lat, lon) {
                    correct += 1
                }
            }
            let precision = results.isEmpty ? 0 : Double(correct) / Double(results.count)
            print("Query '\(query)': \(correct)/\(results.count) = \(String(format: "%.1f%%", precision * 100))")
        }
        
        print("=" * 50)
    }
}

// MARK: - String Repeat Extension
extension String {
    static func * (string: String, count: Int) -> String {
        return String(repeating: string, count: count)
    }
}
