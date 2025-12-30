import Foundation
import AVFoundation
import Photos

// MARK: - Groq Service (Whisper Transcription)

actor GroqService {
    static let shared = GroqService()

    private let apiEndpoint = "https://api.groq.com/openai/v1/audio/transcriptions"
    private let model = "whisper-large-v3-turbo"

    private init() {}

    private nonisolated func log(_ message: String) {
        Log.shared.print("Groq", message)
    }
    
    // MARK: - API Key

    private var apiKey: String? {
        // Try Keychain first
        if let key = KeychainService.shared.getAPIKey(for: .groq) {
            return key
        }
        // Fallback to ~/.interview-master-keys
        return loadKeyFromFile()
    }

    private func loadKeyFromFile() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let keysFile = homeDir.appendingPathComponent(".interview-master-keys")

        guard let content = try? String(contentsOf: keysFile, encoding: .utf8) else {
            return nil
        }

        // Parse GROQ_API_KEY=xxx format
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("GROQ_API_KEY=") {
                return String(line.dropFirst("GROQ_API_KEY=".count))
            }
        }
        return nil
    }
    
    // MARK: - Transcribe Audio
    
    /// Transcribes audio from a file URL
    /// - Parameters:
    ///   - audioURL: URL to audio file (mp3, m4a, wav, etc.)
    ///   - language: Optional language hint (e.g., "en", "es")
    /// - Returns: Transcription result with text and segments
    func transcribe(audioURL: URL, language: String? = nil) async throws -> TranscriptionResult {
        guard let apiKey = apiKey else {
            throw GroqError.noAPIKey
        }
        
        let audioData = try Data(contentsOf: audioURL)
        return try await transcribe(audioData: audioData, filename: audioURL.lastPathComponent, language: language)
    }
    
    /// Transcribes audio from raw data
    func transcribe(audioData: Data, filename: String, language: String? = nil) async throws -> TranscriptionResult {
        guard let apiKey = apiKey else {
            log("❌ No API key found")
            throw GroqError.noAPIKey
        }

        // Check file size (25MB limit for free tier)
        let maxSize = 25 * 1024 * 1024
        guard audioData.count <= maxSize else {
            log("❌ File too large: \(audioData.count / 1024)KB (max \(maxSize / 1024 / 1024)MB)")
            throw GroqError.fileTooLarge(audioData.count, maxSize)
        }

        // Log request details
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log("📤 REQUEST")
        log("   endpoint: \(apiEndpoint)")
        log("   model: \(model)")
        log("   file: \(filename)")
        log("   size: \(audioData.count / 1024)KB")
        log("   language: \(language ?? "auto")")
        log("   format: verbose_json")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Build multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(String(apiKey.prefix(10)))...", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Add response format (verbose_json for timestamps)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json\r\n".data(using: .utf8)!)

        // Add language if specified
        if let lang = language {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(lang)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        // Fix authorization header (was logging masked version)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let startTime = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(startTime)

        guard let httpResponse = response as? HTTPURLResponse else {
            log("❌ Invalid response type")
            throw GroqError.invalidResponse
        }

        log("📥 RESPONSE (\(String(format: "%.2f", elapsed))s)")
        log("   status: \(httpResponse.statusCode)")

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            log("❌ Error: \(errorBody)")
            throw GroqError.apiError(httpResponse.statusCode, errorBody)
        }

        // Parse response
        let result = try JSONDecoder().decode(WhisperResponse.self, from: data)

        log("   language: \(result.language ?? "unknown")")
        log("   duration: \(String(format: "%.1f", result.duration ?? 0))s")
        log("   segments: \(result.segments?.count ?? 0)")
        log("   text: \"\(result.text.prefix(100))...\"")
        log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        return TranscriptionResult(
            text: result.text,
            language: result.language,
            duration: result.duration,
            segments: result.segments?.map { segment in
                TranscriptionSegment(
                    start: segment.start,
                    end: segment.end,
                    text: segment.text
                )
            } ?? []
        )
    }
    
    // MARK: - Extract & Transcribe from Video
    
    /// Extracts middle audio segment from video and transcribes it
    /// - Parameters:
    ///   - asset: PHAsset video
    ///   - segmentDuration: Duration of audio to extract (default 60 seconds)
    /// - Returns: Transcription result
    func transcribeVideoAudio(asset: PHAsset, segmentDuration: TimeInterval = 60) async throws -> TranscriptionResult {
        guard asset.mediaType == .video else {
            log("❌ Asset is not a video")
            throw GroqError.notAVideo
        }

        log("🎬 Processing video: \(asset.localIdentifier.prefix(20))...")

        // Get AVAsset
        guard let avAsset = await getAVAsset(for: asset) else {
            log("❌ Could not load AVAsset")
            throw GroqError.couldNotLoadVideo
        }

        // Calculate middle segment
        let duration = CMTimeGetSeconds(avAsset.duration)
        let startTime = max(0, (duration / 2) - (segmentDuration / 2))
        let endTime = min(duration, startTime + segmentDuration)
        let actualDuration = endTime - startTime

        log("🎵 Extracting audio segment")
        log("   video duration: \(String(format: "%.1f", duration))s")
        log("   segment: \(String(format: "%.1f", startTime))s → \(String(format: "%.1f", endTime))s (\(String(format: "%.1f", actualDuration))s)")

        // Extract audio to temporary file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try await extractAudio(
            from: avAsset,
            to: tempURL,
            startTime: startTime,
            duration: actualDuration
        )

        // Check file size
        let fileSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int ?? 0
        log("   exported: \(fileSize / 1024)KB → \(tempURL.lastPathComponent)")

        // Transcribe
        return try await transcribe(audioURL: tempURL)
    }
    
    // MARK: - Audio Extraction
    
    private func extractAudio(
        from asset: AVAsset,
        to outputURL: URL,
        startTime: TimeInterval,
        duration: TimeInterval
    ) async throws {
        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw GroqError.exportFailed("Could not create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.audioTimePitchAlgorithm = .spectral
        
        // Set time range for middle segment
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let durationCM = CMTime(seconds: duration, preferredTimescale: 600)
        exportSession.timeRange = CMTimeRange(start: start, duration: durationCM)
        
        await exportSession.export()
        
        if let error = exportSession.error {
            throw GroqError.exportFailed(error.localizedDescription)
        }
        
        guard exportSession.status == .completed else {
            throw GroqError.exportFailed("Export status: \(exportSession.status.rawValue)")
        }
    }
    
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
}

// MARK: - Response Models

struct WhisperResponse: Codable {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [WhisperSegment]?
}

struct WhisperSegment: Codable {
    let start: Double
    let end: Double
    let text: String
}

// MARK: - Result Models

struct TranscriptionResult {
    let text: String
    let language: String?
    let duration: Double?
    let segments: [TranscriptionSegment]
    
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct TranscriptionSegment {
    let start: Double
    let end: Double
    let text: String
}

// MARK: - Errors

enum GroqError: LocalizedError {
    case noAPIKey
    case notAVideo
    case couldNotLoadVideo
    case fileTooLarge(Int, Int)
    case exportFailed(String)
    case invalidResponse
    case apiError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Groq API key not configured"
        case .notAVideo:
            return "Asset is not a video"
        case .couldNotLoadVideo:
            return "Could not load video"
        case .fileTooLarge(let actual, let max):
            return "Audio file too large: \(actual / 1024 / 1024)MB (max \(max / 1024 / 1024)MB)"
        case .exportFailed(let reason):
            return "Audio export failed: \(reason)"
        case .invalidResponse:
            return "Invalid API response"
        case .apiError(let code, let msg):
            return "Groq API error \(code): \(msg)"
        }
    }
}
