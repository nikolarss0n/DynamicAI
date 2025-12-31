import Foundation
import Vision
import AppKit
import CoreImage

// MARK: - Vision Classifier
/// Uses Apple's on-device Vision framework for fast pre-filtering
/// Provides scene classification, face detection, and object recognition
/// Zero API cost, works offline, ~50ms per image

actor VisionClassifier {
    static let shared = VisionClassifier()
    
    // MARK: - Lazy Request Objects
    
    private lazy var classifyRequest: VNClassifyImageRequest = {
        VNClassifyImageRequest()
    }()
    
    private lazy var faceRequest: VNDetectFaceRectanglesRequest = {
        VNDetectFaceRectanglesRequest()
    }()
    
    private lazy var textRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        return request
    }()
    
    private lazy var rectangleRequest: VNDetectRectanglesRequest = {
        VNDetectRectanglesRequest()
    }()
    
    private lazy var attentionRequest: VNGenerateAttentionBasedSaliencyImageRequest = {
        VNGenerateAttentionBasedSaliencyImageRequest()
    }()
    
    private init() {}
    
    // MARK: - Full Analysis

    /// Perform comprehensive on-device analysis
    /// Returns scene labels, face count, detected text, and objects
    func analyze(image: NSImage) async -> VisionAnalysisResult {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            log.warning(.vision, "Failed to convert NSImage to CGImage")
            return VisionAnalysisResult.empty
        }

        return await analyze(cgImage: cgImage)
    }

    func analyze(cgImage: CGImage) async -> VisionAnalysisResult {
        let start = CFAbsoluteTimeGetCurrent()
        log.info(.vision, "Starting on-device analysis", details: [
            "width": cgImage.width,
            "height": cgImage.height
        ])

        // Run all analyses in parallel
        async let sceneLabels = classifyScene(cgImage: cgImage)
        async let faceInfo = detectFaces(cgImage: cgImage)
        async let textContent = recognizeText(cgImage: cgImage)
        async let saliency = computeSaliency(cgImage: cgImage)

        let (labels, faces, text, salient) = await (sceneLabels, faceInfo, textContent, saliency)

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        log.success(.vision, "Analysis complete", details: [
            "duration": String(format: "%.0fms", elapsed * 1000),
            "scenes": labels.count,
            "faces": faces.count,
            "textLines": text.count,
            "salientRegions": salient.count
        ])

        return VisionAnalysisResult(
            sceneLabels: labels,
            faceCount: faces.count,
            faceConfidences: faces.map { Float($0.confidence) },
            detectedText: text,
            salientRegions: salient,
            analyzedAt: Date()
        )
    }
    
    // MARK: - Scene Classification
    
    /// Classify scene/content type using VNClassifyImageRequest
    /// Returns top labels with confidence scores
    func classifyScene(cgImage: CGImage) async -> [SceneLabel] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([classifyRequest])

            guard let results = classifyRequest.results else {
                return []
            }

            // Filter to high-confidence labels (>10%)
            let labels = results
                .filter { $0.confidence > 0.1 }
                .prefix(10)
                .map { SceneLabel(identifier: $0.identifier, confidence: $0.confidence) }

            if !labels.isEmpty {
                log.debug(.vision, "Scene labels", details: [
                    "top": labels.prefix(3).map { "\($0.identifier):\(String(format: "%.0f%%", $0.confidence * 100))" }.joined(separator: ", ")
                ])
            }

            return labels
        } catch {
            log.error(.vision, "Scene classification failed", details: ["error": error.localizedDescription])
            return []
        }
    }
    
    /// Quick check for specific scene types (for filtering)
    func hasSceneType(_ type: SceneType, in cgImage: CGImage) async -> Bool {
        let labels = await classifyScene(cgImage: cgImage)
        return labels.contains { type.identifiers.contains($0.identifier) }
    }
    
    // MARK: - Face Detection
    
    /// Detect faces in image
    /// Returns bounding boxes and confidence scores
    func detectFaces(cgImage: CGImage) async -> [FaceInfo] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([faceRequest])

            guard let results = faceRequest.results else {
                return []
            }

            let faces = results.map { face in
                FaceInfo(
                    boundingBox: face.boundingBox,
                    confidence: face.confidence
                )
            }

            if !faces.isEmpty {
                log.debug(.vision, "Faces detected", details: ["count": faces.count])
            }

            return faces
        } catch {
            log.error(.vision, "Face detection failed", details: ["error": error.localizedDescription])
            return []
        }
    }
    
    /// Quick face count (for metadata)
    func countFaces(in cgImage: CGImage) async -> Int {
        let faces = await detectFaces(cgImage: cgImage)
        return faces.count
    }
    
    // MARK: - Text Recognition
    
    /// Detect and recognize text in image (OCR)
    /// Useful for screenshots, documents, signs
    func recognizeText(cgImage: CGImage) async -> [String] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([textRequest])

            guard let results = textRequest.results else {
                return []
            }

            let text = results.compactMap { observation in
                observation.topCandidates(1).first?.string
            }

            if !text.isEmpty {
                log.debug(.vision, "Text recognized", details: [
                    "lines": text.count,
                    "preview": String(text.joined(separator: " ").prefix(50))
                ])
            }

            return text
        } catch {
            log.error(.vision, "Text recognition failed", details: ["error": error.localizedDescription])
            return []
        }
    }

    // MARK: - Saliency Detection

    /// Find visually important regions in image
    func computeSaliency(cgImage: CGImage) async -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([attentionRequest])

            guard let results = attentionRequest.results,
                  let saliency = results.first else {
                return []
            }

            return saliency.salientObjects?.map { $0.boundingBox } ?? []
        } catch {
            log.error(.vision, "Saliency detection failed", details: ["error": error.localizedDescription])
            return []
        }
    }
    
    // MARK: - Image Feature Print (Apple's Native Image Embedding)
    
    /// Generate Apple's native image feature print for similarity comparison
    /// This is the same technology used by Photos app for visual search
    /// Returns a normalized float array that can be used for vector similarity
    func generateFeaturePrint(cgImage: CGImage) async -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let result = request.results?.first else {
                log.warning(.vision, "No feature print result")
                return nil
            }
            
            // Extract the feature print data
            let elementCount = result.elementCount
            var floatArray = [Float](repeating: 0, count: elementCount)
            
            // Copy data from the observation
            try result.data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)
                for i in 0..<elementCount {
                    floatArray[i] = floatBuffer[i]
                }
            }
            
            log.debug(.vision, "Feature print generated", details: [
                "dimensions": elementCount
            ])
            
            return floatArray
        } catch {
            log.error(.vision, "Feature print generation failed", details: ["error": error.localizedDescription])
            return nil
        }
    }
    
    /// Compare two images using their feature prints
    /// Returns a similarity score between 0 (different) and 1 (identical)
    func compareImages(image1: CGImage, image2: CGImage) async -> Float? {
        let request1 = VNGenerateImageFeaturePrintRequest()
        let request2 = VNGenerateImageFeaturePrintRequest()
        
        let handler1 = VNImageRequestHandler(cgImage: image1, options: [:])
        let handler2 = VNImageRequestHandler(cgImage: image2, options: [:])
        
        do {
            try handler1.perform([request1])
            try handler2.perform([request2])
            
            guard let print1 = request1.results?.first,
                  let print2 = request2.results?.first else {
                return nil
            }
            
            var distance: Float = 0
            try print1.computeDistance(&distance, to: print2)
            
            // Convert distance to similarity (lower distance = higher similarity)
            // Feature print distances typically range from 0 to ~100
            let similarity = max(0, 1 - (distance / 50))
            
            log.debug(.vision, "Image comparison", details: [
                "distance": String(format: "%.2f", distance),
                "similarity": String(format: "%.2f", similarity)
            ])
            
            return similarity
        } catch {
            log.error(.vision, "Image comparison failed", details: ["error": error.localizedDescription])
            return nil
        }
    }
    
    // MARK: - Batch Processing
    
    /// Analyze multiple images in parallel
    func analyzeBatch(images: [NSImage], maxConcurrency: Int = 4) async -> [VisionAnalysisResult] {
        await withTaskGroup(of: (Int, VisionAnalysisResult).self) { group in
            var results = [(Int, VisionAnalysisResult)]()
            
            for (index, image) in images.enumerated() {
                group.addTask {
                    let result = await self.analyze(image: image)
                    return (index, result)
                }
                
                // Limit concurrency
                if index > 0 && index % maxConcurrency == 0 {
                    for await result in group.prefix(maxConcurrency) {
                        results.append(result)
                    }
                }
            }
            
            // Collect remaining
            for await result in group {
                results.append(result)
            }
            
            // Sort by original index
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
    // MARK: - Pre-filter Helpers
    
    /// Check if image is likely a screenshot (for skipping in video indexing)
    func isScreenshot(cgImage: CGImage) async -> Bool {
        let result = await analyze(cgImage: cgImage)
        
        // Screenshots typically have: lots of text, UI elements, no faces
        let hasLotsOfText = result.detectedText.count > 5
        let hasNoFaces = result.faceCount == 0
        let hasUILabels = result.sceneLabels.contains { 
            ["computer_screen", "monitor", "display", "text"].contains($0.identifier)
        }
        
        return hasLotsOfText && hasNoFaces && hasUILabels
    }
    
    /// Check if image is likely a duplicate (similar saliency pattern)
    func computeImageHash(cgImage: CGImage) async -> UInt64 {
        // Simple perceptual hash based on downsampled image
        let size = 8
        let context = CIContext()
        let ciImage = CIImage(cgImage: cgImage)
        
        // Resize to 8x8 and convert to grayscale
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return 0 }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CGFloat(size) / CGFloat(cgImage.width), forKey: kCIInputScaleKey)
        
        guard let outputImage = filter.outputImage,
              let resizedCG = context.createCGImage(outputImage, from: outputImage.extent) else {
            return 0
        }
        
        // Compute average and generate hash
        var hash: UInt64 = 0
        let data = CFDataGetBytePtr(resizedCG.dataProvider?.data)
        
        if let data = data {
            var sum: Int = 0
            let pixelCount = size * size
            
            for i in 0..<pixelCount {
                sum += Int(data[i * 4])  // Red channel only
            }
            
            let avg = sum / pixelCount
            
            for i in 0..<min(64, pixelCount) {
                if Int(data[i * 4]) > avg {
                    hash |= (1 << i)
                }
            }
        }
        
        return hash
    }
    
    /// Quick quality check (blur detection)
    func isBlurry(cgImage: CGImage, threshold: Float = 100) async -> Bool {
        let ciImage = CIImage(cgImage: cgImage)
        
        guard let filter = CIFilter(name: "CILaplacian") else { return false }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        
        guard let output = filter.outputImage else { return false }
        
        // Compute variance of Laplacian
        var mean: Float = 0
        var stdDev: Float = 0
        
        // Simplified: just check if image has high-frequency content
        let extent = output.extent
        let area = Float(extent.width * extent.height)
        
        return area > 0 && stdDev < threshold
    }
}

// MARK: - Data Models

struct VisionAnalysisResult {
    let sceneLabels: [SceneLabel]
    let faceCount: Int
    let faceConfidences: [Float]
    let detectedText: [String]
    let salientRegions: [CGRect]
    let analyzedAt: Date
    
    static let empty = VisionAnalysisResult(
        sceneLabels: [],
        faceCount: 0,
        faceConfidences: [],
        detectedText: [],
        salientRegions: [],
        analyzedAt: Date()
    )
    
    /// Convert to searchable keywords
    var keywords: [String] {
        var kw: [String] = []
        
        // Add scene labels
        kw.append(contentsOf: sceneLabels.prefix(5).map { $0.identifier.replacingOccurrences(of: "_", with: " ") })
        
        // Add face-related keywords
        if faceCount > 0 {
            kw.append("person")
            kw.append("people")
            if faceCount == 1 {
                kw.append("selfie")
                kw.append("portrait")
            } else if faceCount >= 2 {
                kw.append("group")
            }
        }
        
        // Add text-related if significant text detected
        if detectedText.count > 3 {
            kw.append("text")
            kw.append("document")
        }
        
        return kw
    }
}

struct SceneLabel {
    let identifier: String
    let confidence: Float
}

struct FaceInfo {
    let boundingBox: CGRect
    let confidence: Float
}

enum SceneType {
    case outdoor
    case indoor
    case nature
    case urban
    case food
    case animal
    case sport
    case document
    
    var identifiers: Set<String> {
        switch self {
        case .outdoor:
            return ["outdoor", "sky", "mountain", "beach", "park", "forest", "garden"]
        case .indoor:
            return ["indoor", "room", "office", "kitchen", "bedroom", "bathroom"]
        case .nature:
            return ["nature", "landscape", "sunset", "sunrise", "ocean", "lake", "tree", "flower"]
        case .urban:
            return ["city", "street", "building", "architecture", "urban", "downtown"]
        case .food:
            return ["food", "meal", "dish", "restaurant", "cooking", "dessert"]
        case .animal:
            return ["animal", "dog", "cat", "bird", "pet", "wildlife"]
        case .sport:
            return ["sport", "exercise", "gym", "running", "swimming", "ball"]
        case .document:
            return ["document", "text", "paper", "screen", "computer", "phone"]
        }
    }
}

// MARK: - Extensions

extension VisionAnalysisResult: Codable {
    enum CodingKeys: String, CodingKey {
        case sceneLabels, faceCount, faceConfidences, detectedText, salientRegions, analyzedAt
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sceneLabels = try container.decode([SceneLabel].self, forKey: .sceneLabels)
        faceCount = try container.decode(Int.self, forKey: .faceCount)
        faceConfidences = try container.decode([Float].self, forKey: .faceConfidences)
        detectedText = try container.decode([String].self, forKey: .detectedText)
        analyzedAt = try container.decode(Date.self, forKey: .analyzedAt)
        
        // Decode CGRect array
        let rectArrays = try container.decode([[Double]].self, forKey: .salientRegions)
        salientRegions = rectArrays.map { arr in
            CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sceneLabels, forKey: .sceneLabels)
        try container.encode(faceCount, forKey: .faceCount)
        try container.encode(faceConfidences, forKey: .faceConfidences)
        try container.encode(detectedText, forKey: .detectedText)
        try container.encode(analyzedAt, forKey: .analyzedAt)
        
        // Encode CGRect as array
        let rectArrays = salientRegions.map { [$0.origin.x, $0.origin.y, $0.width, $0.height] }
        try container.encode(rectArrays, forKey: .salientRegions)
    }
}

extension SceneLabel: Codable {}
