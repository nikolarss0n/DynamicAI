import XCTest
@testable import DynamicAI

final class PhotoQueryParserTests: XCTestCase {

    // MARK: - My Photos Detection Tests

    func testDetectMyPhotosIntent_DirectMyPhotos() {
        // Clear "my photos" patterns should return true
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("show me my photos"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("show my photos from Miraggio"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("my photos from vacation"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("find my pictures"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("get my photos"))
    }

    func testDetectMyPhotosIntent_PhotosOfMe() {
        // "photos of me" patterns should return true
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("photos of me at the beach"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("pictures of me in Greece"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("images of me"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("photos with me"))
    }

    func testDetectMyPhotosIntent_WhereIAm() {
        // "where I am" patterns should return true
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("photos where I am present"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("pictures where I'm visible"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("photos where i am in"))
    }

    func testDetectMyPhotosIntent_PhotosOfMyVacation() {
        // "photos of my vacation" should return FALSE - not asking for photos OF the user
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("photos of my vacation"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("show me photos of my vacation in Miraggio"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("pictures of my trip"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("photos of my dog"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("pictures of my car"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("photos of my house"))
    }

    func testDetectMyPhotosIntent_GeneralQueries() {
        // General photo queries without "my" ownership should return false
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("show me photos from Miraggio"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("photos from Greece"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("beach photos"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("vacation photos"))
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("find photos of the sunset"))
    }

    func testDetectMyPhotosIntent_CriticalScenarios() {
        // THE KEY TEST CASES from the task
        // "show me photos of my vacation in Miraggio hotel" → FALSE (photos of vacation, not user)
        XCTAssertFalse(PhotoQueryParser.detectMyPhotosIntent("show me photos of my vacation in Miraggio hotel"))

        // "show me my photos from Miraggio hotel" → TRUE (user's photos where they appear)
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("show me my photos from Miraggio hotel"))

        // "show me MY photos from Miraggion hotel" → TRUE (explicit MY photos)
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("show me MY photos from Miraggion hotel"))
    }

    // MARK: - Location Extraction Tests

    func testExtractLocation_FromPreposition() {
        XCTAssertEqual(PhotoQueryParser.extractLocation("photos from Miraggio hotel"), "Miraggio hotel")
        XCTAssertEqual(PhotoQueryParser.extractLocation("photos at the beach"), "beach")
        XCTAssertEqual(PhotoQueryParser.extractLocation("pictures in Greece"), "Greece")
    }

    func testExtractLocation_WithHotelResort() {
        XCTAssertEqual(PhotoQueryParser.extractLocation("photos from Miraggio hotel"), "Miraggio hotel")
        XCTAssertEqual(PhotoQueryParser.extractLocation("pictures at Grand Resort"), "Grand Resort")
    }

    func testExtractLocation_FuzzyMatch() {
        // "Miraggion" should fuzzy-match to "Miraggio"
        XCTAssertEqual(PhotoQueryParser.extractLocation("photos from Miraggion"), "Miraggio")
    }

    func testExtractLocation_NoLocation() {
        XCTAssertNil(PhotoQueryParser.extractLocation("show me my latest photos"))
        XCTAssertNil(PhotoQueryParser.extractLocation("photos of dogs"))
    }

    // MARK: - Limit Extraction Tests

    func testExtractLimit_NumericPatterns() {
        XCTAssertEqual(PhotoQueryParser.extractLimit("show me 10 photos"), 10)
        XCTAssertEqual(PhotoQueryParser.extractLimit("5 pictures from Greece"), 5)
        XCTAssertEqual(PhotoQueryParser.extractLimit("last 20 videos"), 20)
        XCTAssertEqual(PhotoQueryParser.extractLimit("top 3 photos"), 3)
    }

    func testExtractLimit_NoLimit() {
        XCTAssertNil(PhotoQueryParser.extractLimit("show me photos"))
        XCTAssertNil(PhotoQueryParser.extractLimit("photos from Greece"))
    }

    // MARK: - Media Type Detection Tests

    func testDetectMediaType_Video() {
        XCTAssertEqual(PhotoQueryParser.detectMediaType("show me videos"), .video)
        XCTAssertEqual(PhotoQueryParser.detectMediaType("find my video from vacation"), .video)
    }

    func testDetectMediaType_Photo() {
        XCTAssertEqual(PhotoQueryParser.detectMediaType("show me photos"), .photo)
        XCTAssertEqual(PhotoQueryParser.detectMediaType("find pictures"), .photo)
        XCTAssertEqual(PhotoQueryParser.detectMediaType("my images"), .photo)
    }

    func testDetectMediaType_All() {
        XCTAssertEqual(PhotoQueryParser.detectMediaType("photos and videos"), .all)
        XCTAssertEqual(PhotoQueryParser.detectMediaType("show me my media"), .all)
    }

    // MARK: - Time Period Extraction Tests

    func testExtractTimePeriod_RelativeTime() {
        XCTAssertEqual(PhotoQueryParser.extractTimePeriod("photos from last week"), "last week")
        XCTAssertEqual(PhotoQueryParser.extractTimePeriod("pictures from last month"), "last month")
        XCTAssertEqual(PhotoQueryParser.extractTimePeriod("this year's photos"), "this year")
    }

    func testExtractTimePeriod_Season() {
        XCTAssertNotNil(PhotoQueryParser.extractTimePeriod("summer vacation photos"))
        XCTAssertNotNil(PhotoQueryParser.extractTimePeriod("photos from winter 2023"))
    }

    func testExtractTimePeriod_NoTime() {
        XCTAssertNil(PhotoQueryParser.extractTimePeriod("photos from Greece"))
        XCTAssertNil(PhotoQueryParser.extractTimePeriod("my latest photos"))
    }

    // MARK: - Full Parse Tests

    func testParse_ComplexQuery1() {
        // "show me photos of my vacation in Miraggio hotel"
        let result = PhotoQueryParser.parse("show me photos of my vacation in Miraggio hotel")
        XCTAssertFalse(result.isMyPhotosRequest)  // NOT asking for photos of user
        XCTAssertNotNil(result.location)
        XCTAssertEqual(result.mediaType, .photo)
    }

    func testParse_ComplexQuery2() {
        // "show me my photos from Miraggio hotel"
        let result = PhotoQueryParser.parse("show me my photos from Miraggio hotel")
        XCTAssertTrue(result.isMyPhotosRequest)  // IS asking for photos of user
        XCTAssertNotNil(result.location)
        XCTAssertEqual(result.mediaType, .photo)
    }

    func testParse_ComplexQuery3() {
        // "find 10 videos of me at the beach last summer"
        let result = PhotoQueryParser.parse("find 10 videos of me at the beach last summer")
        XCTAssertTrue(result.isMyPhotosRequest)
        XCTAssertEqual(result.limit, 10)
        XCTAssertEqual(result.mediaType, .video)
        XCTAssertNotNil(result.timePeriod)
    }

    // MARK: - Levenshtein Distance Tests

    func testLevenshteinDistance_ExactMatch() {
        XCTAssertEqual(PhotoQueryParser.levenshteinDistance("hello", "hello"), 0)
    }

    func testLevenshteinDistance_OneEdit() {
        XCTAssertEqual(PhotoQueryParser.levenshteinDistance("hello", "hallo"), 1)
        XCTAssertEqual(PhotoQueryParser.levenshteinDistance("Miraggio", "Miraggion"), 1)
    }

    func testLevenshteinDistance_MultipleEdits() {
        XCTAssertEqual(PhotoQueryParser.levenshteinDistance("kitten", "sitting"), 3)
    }

    // MARK: - Edge Cases

    func testEdgeCases_EmptyQuery() {
        let result = PhotoQueryParser.parse("")
        XCTAssertFalse(result.isMyPhotosRequest)
        XCTAssertNil(result.location)
        XCTAssertNil(result.limit)
    }

    func testEdgeCases_CaseSensitivity() {
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("MY PHOTOS"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("My Photos"))
        XCTAssertTrue(PhotoQueryParser.detectMyPhotosIntent("my photos"))
    }

    func testEdgeCases_Typos() {
        // Common typos should still work via fuzzy matching
        XCTAssertEqual(PhotoQueryParser.extractLocation("photos from Miraggion hotel"), "Miraggio")
    }
}
