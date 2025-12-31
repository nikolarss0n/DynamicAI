import AppKit
import Photos
import AVFoundation

// MARK: - Photos Provider

actor PhotosProvider {
    private var isAuthorized = false

    // MARK: - Authorization

    private func requestAccess() async -> Bool {
        if isAuthorized { return true }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .authorized, .limited:
            isAuthorized = true
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            isAuthorized = (newStatus == .authorized || newStatus == .limited)
            return isAuthorized
        default:
            return false
        }
    }

    // MARK: - Fetch Videos

    func fetchVideos(limit: Int = 500, daysBack: Int? = nil) async -> [PHAsset] {
        guard await requestAccess() else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        // Filter by date if specified
        if let days = daysBack {
            let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@",
                                           PHAssetMediaType.video.rawValue, startDate as NSDate)
        } else {
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }

        let results = PHAsset.fetchAssets(with: options)

        var assets: [PHAsset] = []
        results.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        return assets
    }

    // MARK: - Fetch Photos

    /// Fetch photos from library
    /// - Parameters:
    ///   - limit: Maximum photos to fetch. Use 0 for unlimited (full library scan)
    ///   - daysBack: Optional filter for photos within N days
    ///   - mediaType: Filter by media type (.image, .video, or nil for all)
    func fetchPhotos(limit: Int = 0, daysBack: Int? = nil, mediaType: PHAssetMediaType? = .image) async -> [PHAsset] {
        guard await requestAccess() else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if limit > 0 {
            options.fetchLimit = limit
        }
        // limit = 0 means no fetchLimit (full library)

        // Build predicate based on mediaType and daysBack
        var predicates: [NSPredicate] = []
        
        if let type = mediaType {
            predicates.append(NSPredicate(format: "mediaType == %d", type.rawValue))
        }
        
        if let days = daysBack {
            let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            predicates.append(NSPredicate(format: "creationDate >= %@", startDate as NSDate))
        }
        
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        let results = PHAsset.fetchAssets(with: options)

        var assets: [PHAsset] = []
        results.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        return assets
    }

    // MARK: - Generate Thumbnail

    func generateThumbnail(for asset: PHAsset, size: CGSize = CGSize(width: 150, height: 150), highQuality: Bool = false) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = highQuality ? .highQualityFormat : .fastFormat
            options.resizeMode = highQuality ? .exact : .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true // Allow iCloud downloads

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Get Video Middle Frame (extracts actual middle, not first frame)

    func getVideoThumbnail(for asset: PHAsset, size: CGSize) async -> NSImage? {
        // For videos, extract middle frame to show actual action
        // For photos, use fast PHImageManager
        if asset.mediaType == .video {
            return await extractMiddleFrame(from: asset, size: size)
        } else {
            return await generateThumbnail(for: asset, size: size)
        }
    }
    
    /// Extract thumbnail at specific position in video
    /// - Parameters:
    ///   - asset: PHAsset video
    ///   - size: Target thumbnail size
    ///   - position: Position in video (0.0 = start, 0.5 = middle, 1.0 = end)
    func getVideoThumbnail(for asset: PHAsset, size: CGSize, position: Double) async -> NSImage? {
        guard asset.mediaType == .video else {
            return await generateThumbnail(for: asset, size: size)
        }
        
        guard let avAsset = await getAVAssetFast(for: asset) else { return nil }
        
        let duration = CMTimeGetSeconds(avAsset.duration)
        guard duration > 0 else { return nil }
        
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        // Tolerance for faster extraction (uses nearest keyframe)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)
        
        let clampedPosition = max(0, min(1, position))
        let targetTime = CMTime(seconds: duration * clampedPosition, preferredTimescale: 600)
        
        do {
            let cgImage = try generator.copyCGImage(at: targetTime, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            print("[PhotosProvider] Frame extraction failed at position \(position): \(error)")
            return nil
        }
    }

    private func extractMiddleFrame(from asset: PHAsset, size: CGSize) async -> NSImage? {
        guard let avAsset = await getAVAssetFast(for: asset) else { return nil }

        let duration = CMTimeGetSeconds(avAsset.duration)
        guard duration > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        // LARGE tolerance = uses nearest keyframe = FAST
        generator.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)

        let middleTime = CMTime(seconds: duration / 2, preferredTimescale: 600)

        do {
            let cgImage = try generator.copyCGImage(at: middleTime, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }

    private func getAVAssetFast(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .fastFormat  // FAST - lower quality OK for thumbnails
            options.isNetworkAccessAllowed = true  // Allow iCloud (needed for synced videos)

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    // MARK: - Extract Video Thumbnails for Batch Processing

    func extractVideoThumbnails(
        videos: [PHAsset],
        size: CGSize = CGSize(width: 400, height: 300)
    ) async -> [(index: Int, asset: PHAsset, base64: String)] {

        var results: [(index: Int, asset: PHAsset, base64: String)] = []

        // Process in parallel for speed
        await withTaskGroup(of: (Int, PHAsset, String?).self) { group in
            for (index, asset) in videos.enumerated() {
                group.addTask {
                    guard let frame = await self.extractMiddleFrame(from: asset, size: size) else {
                        return (index, asset, nil)
                    }

                    // Convert to base64 JPEG
                    guard let tiffData = frame.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiffData),
                          let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                        return (index, asset, nil)
                    }

                    let base64 = jpegData.base64EncodedString()
                    return (index, asset, base64)
                }
            }

            for await (index, asset, base64) in group {
                if let b64 = base64 {
                    results.append((index: index, asset: asset, base64: b64))
                }
            }
        }

        // Sort by index to maintain order
        return results.sorted { $0.index < $1.index }
    }

    // MARK: - Sample Video Frames

    func sampleVideoFrames(from asset: PHAsset, count: Int = 4) async -> [NSImage] {
        guard asset.mediaType == .video else {
            print("[FrameSample] Asset is not a video")
            return []
        }

        // Get the video AVAsset directly (not URL)
        guard let avAsset = await getAVAsset(for: asset) else {
            print("[FrameSample] Failed to get AVAsset for video")
            return []
        }

        let duration = CMTimeGetSeconds(avAsset.duration)
        print("[FrameSample] Video duration: \(duration)s")

        guard duration > 0 else {
            print("[FrameSample] Invalid duration")
            return []
        }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)  // Larger for better quality
        // Use tolerance for MUCH faster frame extraction (uses nearest keyframe)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        var frames: [NSImage] = []
        let interval = duration / Double(count + 1)

        for i in 1...count {
            let time = CMTime(seconds: interval * Double(i), preferredTimescale: 600)

            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                frames.append(nsImage)
            } catch {
                print("[FrameSample] Frame \(i) failed: \(error.localizedDescription)")
                continue
            }
        }

        print("[FrameSample] Extracted \(frames.count) frames")
        return frames
    }

    private func getAVAsset(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true  // Allow iCloud downloads

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, audioMix, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    print("[GetAVAsset] Error: \(error.localizedDescription)")
                }
                if avAsset == nil {
                    print("[GetAVAsset] Returned nil AVAsset, info: \(String(describing: info))")
                } else {
                    print("[GetAVAsset] Got AVAsset: \(type(of: avAsset!))")
                }
                continuation.resume(returning: avAsset)
            }
        }
    }

    // MARK: - Create Contact Sheet

    func createContactSheet(
        videos: [PHAsset],
        framesPerVideo: Int = 4,
        thumbnailSize: CGSize = CGSize(width: 120, height: 90),
        videosPerSheet: Int = 25
    ) async -> (image: NSImage, assetMap: [Int: PHAsset])? {

        let videosToProcess = Array(videos.prefix(videosPerSheet))
        guard !videosToProcess.isEmpty else { return nil }

        // Calculate grid dimensions
        let columns = framesPerVideo
        let rows = videosToProcess.count

        let gridWidth = Int(CGFloat(columns) * thumbnailSize.width)
        let gridHeight = Int(CGFloat(rows) * thumbnailSize.height)

        // Map row index to asset
        var assetMap: [Int: PHAsset] = [:]

        // Collect all frames in PARALLEL for speed
        var allFrames: [[NSImage]] = Array(repeating: [], count: videosToProcess.count)

        await withTaskGroup(of: (Int, [NSImage]).self) { group in
            for (rowIndex, asset) in videosToProcess.enumerated() {
                assetMap[rowIndex] = asset
                group.addTask {
                    let frames = await self.sampleVideoFrames(from: asset, count: framesPerVideo)
                    return (rowIndex, frames)
                }
            }

            for await (index, frames) in group {
                allFrames[index] = frames
                print("[ContactSheet] Row \(index + 1): extracted \(frames.count) frames")
            }
        }

        // Create bitmap on main thread
        let finalImage = await MainActor.run { () -> NSImage? in
            guard let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: gridWidth,
                pixelsHigh: gridHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                print("[ContactSheet] Failed to create bitmap")
                return nil
            }

            NSGraphicsContext.saveGraphicsState()
            guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
                print("[ContactSheet] Failed to create graphics context")
                return nil
            }
            NSGraphicsContext.current = context

            // Fill background with dark gray (not pure black)
            NSColor.darkGray.setFill()
            NSRect(x: 0, y: 0, width: gridWidth, height: gridHeight).fill()

            // Draw frames
            for (rowIndex, frames) in allFrames.enumerated() {
                for (colIndex, frame) in frames.enumerated() {
                    let x = CGFloat(colIndex) * thumbnailSize.width
                    // Y is from bottom in NSGraphicsContext
                    let y = CGFloat(gridHeight) - CGFloat(rowIndex + 1) * thumbnailSize.height

                    let destRect = NSRect(x: x, y: y, width: thumbnailSize.width, height: thumbnailSize.height)
                    frame.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }

                // Draw row number label
                let label = "\(rowIndex + 1)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.8)
                ]
                let labelY = CGFloat(gridHeight) - CGFloat(rowIndex + 1) * thumbnailSize.height + 4
                label.draw(at: NSPoint(x: 4, y: labelY), withAttributes: attrs)
            }

            NSGraphicsContext.restoreGraphicsState()

            let image = NSImage(size: NSSize(width: gridWidth, height: gridHeight))
            image.addRepresentation(bitmapRep)
            print("[ContactSheet] Created image: \(image.size), representations: \(image.representations.count)")
            return image
        }

        guard let image = finalImage else { return nil }
        return (image, assetMap)
    }

    // MARK: - Create Video Grid (1 middle frame per video)

    func createVideoGrid(
        videos: [PHAsset],
        thumbnailSize: CGSize = CGSize(width: 200, height: 150),
        columns: Int = 5
    ) async -> (image: NSImage, assetMap: [Int: PHAsset])? {

        guard !videos.isEmpty else { return nil }

        let rows = Int(ceil(Double(videos.count) / Double(columns)))
        let gridWidth = Int(CGFloat(columns) * thumbnailSize.width)
        let gridHeight = Int(CGFloat(rows) * thumbnailSize.height)

        var assetMap: [Int: PHAsset] = [:]

        // Use PHImageManager for FAST cached thumbnails (not AVAssetImageGenerator)
        var thumbnails: [(index: Int, frame: NSImage)] = []

        await withTaskGroup(of: (Int, NSImage?).self) { group in
            for (index, asset) in videos.enumerated() {
                assetMap[index] = asset
                group.addTask {
                    let thumb = await self.getVideoThumbnail(for: asset, size: thumbnailSize)
                    return (index, thumb)
                }
            }

            for await (index, frame) in group {
                if let frame = frame {
                    thumbnails.append((index, frame))
                }
            }
        }

        print("[VideoGrid] Got \(thumbnails.count) thumbnails from \(videos.count) videos")

        // DEBUG: Save individual thumbnails to folder
        let debugFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/video_thumbnails")
        try? FileManager.default.createDirectory(at: debugFolder, withIntermediateDirectories: true)
        // Clear old files
        if let files = try? FileManager.default.contentsOfDirectory(at: debugFolder, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        for (index, frame) in thumbnails {
            if let tiffData = frame.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                let fileURL = debugFolder.appendingPathComponent(String(format: "%03d.jpg", index + 1))
                try? jpegData.write(to: fileURL)
            }
        }
        print("[VideoGrid] DEBUG: Saved thumbnails to \(debugFolder.path)")

        // Create bitmap on main thread
        let finalImage = await MainActor.run { () -> NSImage? in
            guard let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: gridWidth,
                pixelsHigh: gridHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }

            NSGraphicsContext.saveGraphicsState()
            guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
            NSGraphicsContext.current = context

            // Fill background
            NSColor.darkGray.setFill()
            NSRect(x: 0, y: 0, width: gridWidth, height: gridHeight).fill()

            // Draw frames in grid
            for (index, frame) in thumbnails {
                let col = index % columns
                let row = index / columns

                let x = CGFloat(col) * thumbnailSize.width
                let y = CGFloat(gridHeight) - CGFloat(row + 1) * thumbnailSize.height

                let destRect = NSRect(x: x, y: y, width: thumbnailSize.width, height: thumbnailSize.height)
                frame.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)

                // Draw index label
                let label = "\(index + 1)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.7)
                ]
                label.draw(at: NSPoint(x: x + 4, y: y + 4), withAttributes: attrs)
            }

            NSGraphicsContext.restoreGraphicsState()

            let image = NSImage(size: NSSize(width: gridWidth, height: gridHeight))
            image.addRepresentation(bitmapRep)
            print("[VideoGrid] Created grid: \(image.size)")
            return image
        }

        return finalImage.map { ($0, assetMap) }
    }

    // MARK: - Create Photo Contact Sheet

    func createPhotoContactSheet(
        photos: [PHAsset],
        thumbnailSize: CGSize = CGSize(width: 100, height: 100),
        columns: Int = 10,
        maxPhotos: Int = 100
    ) async -> (image: NSImage, assetMap: [Int: PHAsset])? {

        let photosToProcess = Array(photos.prefix(maxPhotos))
        guard !photosToProcess.isEmpty else { return nil }

        let rows = Int(ceil(Double(photosToProcess.count) / Double(columns)))

        let gridWidth = Int(CGFloat(columns) * thumbnailSize.width)
        let gridHeight = Int(CGFloat(rows) * thumbnailSize.height)

        var assetMap: [Int: PHAsset] = [:]

        // First collect all thumbnails
        var thumbnails: [(index: Int, thumbnail: NSImage)] = []
        for (index, asset) in photosToProcess.enumerated() {
            assetMap[index] = asset
            if let thumbnail = await generateThumbnail(for: asset, size: thumbnailSize) {
                thumbnails.append((index, thumbnail))
            }
        }
        print("[ContactSheet] Generated \(thumbnails.count) photo thumbnails")

        // Create bitmap on main thread
        let finalImage = await MainActor.run { () -> NSImage? in
            guard let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: gridWidth,
                pixelsHigh: gridHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }

            NSGraphicsContext.saveGraphicsState()
            guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
            NSGraphicsContext.current = context

            // Fill background
            NSColor.darkGray.setFill()
            NSRect(x: 0, y: 0, width: gridWidth, height: gridHeight).fill()

            // Draw thumbnails
            for (index, thumbnail) in thumbnails {
                let col = index % columns
                let row = index / columns

                let x = CGFloat(col) * thumbnailSize.width
                let y = CGFloat(gridHeight) - CGFloat(row + 1) * thumbnailSize.height

                let destRect = NSRect(x: x, y: y, width: thumbnailSize.width, height: thumbnailSize.height)
                thumbnail.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)

                // Draw index label
                let label = "\(index + 1)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 10),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.7)
                ]
                label.draw(at: NSPoint(x: x + 2, y: y + 2), withAttributes: attrs)
            }

            NSGraphicsContext.restoreGraphicsState()

            let image = NSImage(size: NSSize(width: gridWidth, height: gridHeight))
            image.addRepresentation(bitmapRep)
            return image
        }

        return finalImage.map { ($0, assetMap) }
    }

    // MARK: - Get Asset Details

    func getAssetInfo(_ asset: PHAsset) -> PhotoAssetInfo {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        return PhotoAssetInfo(
            id: asset.localIdentifier,
            mediaType: asset.mediaType == .video ? "video" : "photo",
            creationDate: asset.creationDate.map { formatter.string(from: $0) },
            duration: asset.mediaType == .video ? formatDuration(asset.duration) : nil,
            location: asset.location?.coordinate,
            isFavorite: asset.isFavorite
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Get Full Size Image/Video

    func getFullSizeImage(for asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .default,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - People/Faces Tags
    
    /// Cache for main person to avoid repeated lookups
    private var cachedMainPerson: String?
    private var mainPersonCacheDate: Date?
    
    /// Fetches People albums and builds a mapping of asset IDs to person names
    /// Uses Apple's Photos People recognition (set up in Photos.app > People)
    func fetchPeopleMapping() async -> [String: [String]] {
        guard await requestAccess() else {
            print("[PhotosProvider] ❌ No photo library access for people mapping")
            return [:]
        }

        var assetToPeople: [String: [String]] = [:]
        var peopleFound: [String: Int] = [:] // Track people counts for logging

        // Method 1: Fetch the Faces smart folder (contains People albums)
        let facesFolders = PHCollectionList.fetchCollectionLists(
            with: .smartFolder,
            subtype: .smartFolderFaces,
            options: nil
        )
        
        print("[PhotosProvider] 👥 Fetching People albums... (found \(facesFolders.count) face folders)")

        facesFolders.enumerateObjects { peopleFolder, folderIdx, _ in
            print("[PhotosProvider]   📁 Folder[\(folderIdx)]: '\(peopleFolder.localizedTitle ?? "unnamed")'")
            
            // Get person collections from the People folder
            let personCollections = PHAssetCollection.fetchCollections(in: peopleFolder, options: nil)
            print("[PhotosProvider]      → \(personCollections.count) person collections inside")
            
            personCollections.enumerateObjects { collection, _, _ in
                // Each person is an asset collection containing their photos
                guard let assetCollection = collection as? PHAssetCollection,
                      let personName = assetCollection.localizedTitle,
                      !personName.isEmpty else { return }
                
                // Fetch photos for this person
                let assets = PHAsset.fetchAssets(in: assetCollection, options: nil)
                let photoCount = assets.count
                
                if photoCount > 0 {
                    peopleFound[personName] = (peopleFound[personName] ?? 0) + photoCount
                    
                    assets.enumerateObjects { asset, _, _ in
                        let assetId = asset.localIdentifier
                        if assetToPeople[assetId] == nil {
                            assetToPeople[assetId] = []
                        }
                        if !assetToPeople[assetId]!.contains(personName) {
                            assetToPeople[assetId]!.append(personName)
                        }
                    }
                }
            }
        }

        // Method 2: Also check Selfies album and tag as potential "me"
        let selfies = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumSelfPortraits,
            options: nil
        )
        
        if let selfieAlbum = selfies.firstObject {
            let selfieAssets = PHAsset.fetchAssets(in: selfieAlbum, options: nil)
            print("[PhotosProvider] 🤳 Found \(selfieAssets.count) selfies (marking as potential 'me')")
            
            selfieAssets.enumerateObjects { asset, _, _ in
                let assetId = asset.localIdentifier
                if assetToPeople[assetId] == nil {
                    assetToPeople[assetId] = []
                }
                // Add special marker for selfies if no person already tagged
                if assetToPeople[assetId]!.isEmpty {
                    assetToPeople[assetId]!.append("__selfie__")
                }
            }
        }

        // Log summary
        if peopleFound.isEmpty {
            print("[PhotosProvider] ⚠️ No People albums found! To enable 'photos of me' search:")
            print("[PhotosProvider]    1. Open Photos.app")
            print("[PhotosProvider]    2. Go to People & Pets album")
            print("[PhotosProvider]    3. Identify yourself and others")
        } else {
            print("[PhotosProvider] ✅ Found \(peopleFound.count) people:")
            for (name, count) in peopleFound.sorted(by: { $0.value > $1.value }).prefix(5) {
                print("[PhotosProvider]    • \(name): \(count) photos")
            }
        }
        
        print("[PhotosProvider] 📊 Total: \(assetToPeople.count) assets with people/selfie tags")
        return assetToPeople
    }

    /// Get people names for a specific asset
    func getPeopleForAsset(_ asset: PHAsset) async -> [String] {
        let mapping = await fetchPeopleMapping()
        return mapping[asset.localIdentifier] ?? []
    }
    
    /// Debug function to explore Photos library structure
    func debugPhotosStructure() async {
        guard await requestAccess() else {
            print("[PhotosProvider] ❌ No access to photos")
            return
        }
        
        print("\n" + String(repeating: "=", count: 60))
        print("[PhotosProvider] 🔍 DEBUGGING PHOTOS LIBRARY STRUCTURE")
        print(String(repeating: "=", count: 60))
        
        // 1. Check ALL smart folders
        print("\n📁 SMART FOLDERS (PHCollectionList.smartFolder):")
        let allSmartFolders = PHCollectionList.fetchCollectionLists(with: .smartFolder, subtype: .any, options: nil)
        print("   Found \(allSmartFolders.count) smart folders")
        allSmartFolders.enumerateObjects { folder, idx, _ in
            print("   [\(idx)] '\(folder.localizedTitle ?? "nil")' - subtype: \(folder.collectionListSubtype.rawValue)")
            
            // Get collections inside this folder
            let collections = PHAssetCollection.fetchCollections(in: folder, options: nil)
            print("        → \(collections.count) collections inside")
            
            // If this is People/Faces, enumerate contents
            if folder.collectionListSubtype == .smartFolderFaces {
                print("        🧑 This is the FACES folder! Enumerating people:")
                
                collections.enumerateObjects { collection, cIdx, _ in
                    if let assetCollection = collection as? PHAssetCollection {
                        let count = PHAsset.fetchAssets(in: assetCollection, options: nil).count
                        print("           [\(cIdx)] '\(assetCollection.localizedTitle ?? "unnamed")' - \(count) photos")
                    } else {
                        print("           [\(cIdx)] '\(collection.localizedTitle ?? "unnamed")' - (not an asset collection)")
                    }
                }
            }
        }
        
        // 2. Check smart albums
        print("\n📷 SMART ALBUMS (PHAssetCollection.smartAlbum):")
        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smartAlbums.enumerateObjects { album, _, _ in
            let count = PHAsset.fetchAssets(in: album, options: nil).count
            if count > 0 {
                print("   '\(album.localizedTitle ?? "nil")' - \(count) assets (subtype: \(album.assetCollectionSubtype.rawValue))")
            }
        }
        
        // 3. Check user albums
        print("\n👤 USER ALBUMS (first 10 with content):")
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var albumCount = 0
        userAlbums.enumerateObjects { album, _, stop in
            let count = PHAsset.fetchAssets(in: album, options: nil).count
            if count > 0 {
                print("   '\(album.localizedTitle ?? "nil")' - \(count) assets")
                albumCount += 1
                if albumCount >= 10 { stop.pointee = true }
            }
        }
        
        // 4. Specifically check Selfies
        print("\n🤳 SELFIES ALBUM:")
        let selfies = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
        if let selfieAlbum = selfies.firstObject {
            let count = PHAsset.fetchAssets(in: selfieAlbum, options: nil).count
            print("   Found Selfies album with \(count) photos")
        } else {
            print("   ❌ No Selfies album found")
        }
        
        // 5. Favorites
        print("\n⭐ FAVORITES ALBUM:")
        let favorites = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        if let favAlbum = favorites.firstObject {
            let count = PHAsset.fetchAssets(in: favAlbum, options: nil).count
            print("   Found Favorites album with \(count) photos")
        }
        
        print("\n" + String(repeating: "=", count: 60))
        print("[PhotosProvider] 🔍 DEBUG COMPLETE")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    /// Get all unique person names from the library with their photo counts
    func getAllPeople() async -> [(name: String, count: Int)] {
        guard await requestAccess() else { 
            print("[PhotosProvider] No access to photos")
            return [] 
        }
        
        var personCounts: [String: Int] = [:]
        
        // Get the People/Faces smart folder
        let facesFolders = PHCollectionList.fetchCollectionLists(
            with: .smartFolder,
            subtype: .smartFolderFaces,
            options: nil
        )
        print("[PhotosProvider] Found \(facesFolders.count) faces smart folders")
        
        facesFolders.enumerateObjects { peopleFolder, _, _ in
            print("[PhotosProvider] People folder: '\(peopleFolder.localizedTitle ?? "unnamed")'")
            
            // Get collections inside the People folder - each person is a PHAssetCollection
            let personCollections = PHAssetCollection.fetchCollections(in: peopleFolder, options: nil)
            print("[PhotosProvider]   → \(personCollections.count) person collections")
            
            personCollections.enumerateObjects { collection, _, _ in
                // Each person is an asset collection containing their photos
                guard let assetCollection = collection as? PHAssetCollection,
                      let personName = assetCollection.localizedTitle,
                      !personName.isEmpty else { return }
                
                // Count photos for this person
                let photoCount = PHAsset.fetchAssets(in: assetCollection, options: nil).count
                if photoCount > 0 {
                    personCounts[personName] = (personCounts[personName] ?? 0) + photoCount
                    print("[PhotosProvider]   Found person: '\(personName)' with \(photoCount) photos")
                }
            }
        }
        
        print("[PhotosProvider] Total people found: \(personCounts.count)")
        for (name, count) in personCounts.sorted(by: { $0.value > $1.value }).prefix(5) {
            print("[PhotosProvider]   - \(name): \(count) photos")
        }
        
        return personCounts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
    
    /// Get the "main" person (likely device owner) - person with most photos
    /// Caches the result in UserDefaults for faster subsequent lookups
    func getMainPerson() async -> String? {
        // Check cache first (valid for 1 hour)
        let cacheKey = "PhotosProvider.mainPerson"
        let cacheTimeKey = "PhotosProvider.mainPersonCacheTime"
        
        if let cached = UserDefaults.standard.string(forKey: cacheKey),
           let cacheTime = UserDefaults.standard.object(forKey: cacheTimeKey) as? Date,
           Date().timeIntervalSince(cacheTime) < 3600 { // 1 hour cache
            print("[PhotosProvider] 👤 Using cached main person: '\(cached)'")
            return cached
        }
        
        // Fetch fresh data
        let people = await getAllPeople()
        let mainPerson = people.first?.name
        
        // Cache the result
        if let person = mainPerson {
            UserDefaults.standard.set(person, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheTimeKey)
            print("[PhotosProvider] 👤 Cached main person: '\(person)'")
        }
        
        return mainPerson
    }
    
    /// Clear the cached main person (call when user changes People albums)
    func clearMainPersonCache() {
        UserDefaults.standard.removeObject(forKey: "PhotosProvider.mainPerson")
        UserDefaults.standard.removeObject(forKey: "PhotosProvider.mainPersonCacheTime")
        print("[PhotosProvider] 🗑️ Cleared main person cache")
    }
    
    /// Fetch photos containing a specific person
    func fetchPhotosOfPerson(name: String, limit: Int = 50, mediaType: PHAssetMediaType? = nil) async -> [PHAsset] {
        guard await requestAccess() else { return [] }
        
        var matchingAssets: [PHAsset] = []
        let lowercaseName = name.lowercased()
        
        // Get the People/Faces smart folder
        let facesFolders = PHCollectionList.fetchCollectionLists(
            with: .smartFolder,
            subtype: .smartFolderFaces,
            options: nil
        )
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let mediaType = mediaType {
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
        }
        
        facesFolders.enumerateObjects { peopleFolder, _, folderStop in
            // Get person collections from the People folder
            let personCollections = PHAssetCollection.fetchCollections(in: peopleFolder, options: nil)
            
            personCollections.enumerateObjects { collection, _, collectionStop in
                guard let assetCollection = collection as? PHAssetCollection,
                      let personName = assetCollection.localizedTitle,
                      personName.lowercased().contains(lowercaseName) else { return }
                
                print("[PhotosProvider] Found matching person: '\(personName)'")
                
                // Fetch photos directly from this person's collection
                let assets = PHAsset.fetchAssets(in: assetCollection, options: fetchOptions)
                assets.enumerateObjects { asset, _, assetStop in
                    if matchingAssets.count >= limit {
                        assetStop.pointee = true
                        collectionStop.pointee = true
                        folderStop.pointee = true
                        return
                    }
                    if !matchingAssets.contains(where: { $0.localIdentifier == asset.localIdentifier }) {
                        matchingAssets.append(asset)
                    }
                }
            }
        }
        
        print("[PhotosProvider] Found \(matchingAssets.count) photos of '\(name)'")
        return matchingAssets
    }
    
    /// Fetch "my" photos - photos of the main person (device owner)
    /// Uses Apple's Photos People recognition + Selfies album as fallback
    func fetchMyPhotos(limit: Int = 50, mediaType: PHAssetMediaType? = nil) async -> [PHAsset] {
        print("[PhotosProvider] 🔍 fetchMyPhotos (limit: \(limit))")
        
        var allMyPhotos: [PHAsset] = []
        var seenIds = Set<String>()
        
        // Strategy 1: Get photos from People album (main person)
        let mainPerson = await getMainPerson()
        if let person = mainPerson {
            print("[PhotosProvider] 👤 Main person: '\(person)'")
            let personPhotos = await fetchPhotosOfPerson(name: person, limit: limit, mediaType: mediaType)
            for photo in personPhotos where !seenIds.contains(photo.localIdentifier) {
                allMyPhotos.append(photo)
                seenIds.insert(photo.localIdentifier)
            }
            print("[PhotosProvider]    → \(personPhotos.count) photos from People album")
        }
        
        // Strategy 2: Add Selfies (front camera = definitely me)
        let selfies = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumSelfPortraits,
            options: nil
        )
        
        if let selfieAlbum = selfies.firstObject {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if let mediaType = mediaType {
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
            }
            
            let selfieAssets = PHAsset.fetchAssets(in: selfieAlbum, options: fetchOptions)
            var selfieCount = 0
            selfieAssets.enumerateObjects { asset, _, stop in
                if !seenIds.contains(asset.localIdentifier) {
                    allMyPhotos.append(asset)
                    seenIds.insert(asset.localIdentifier)
                    selfieCount += 1
                }
                if allMyPhotos.count >= limit {
                    stop.pointee = true
                }
            }
            print("[PhotosProvider]    → \(selfieCount) additional selfies")
        }
        
        // If we have enough photos, return them sorted by date
        if !allMyPhotos.isEmpty {
            let sorted = allMyPhotos.sorted { 
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) 
            }
            print("[PhotosProvider] ✅ Returning \(min(sorted.count, limit)) 'me' photos")
            return Array(sorted.prefix(limit))
        }
        
        // Fallback: No People or Selfies found
        print("[PhotosProvider] ⚠️ No 'me' photos found via People/Selfies")
        print("[PhotosProvider]    💡 Tip: Open Photos.app → People & Pets → Identify yourself")
        
        // Last resort: Favorites album
        print("[PhotosProvider] Fallback: Trying Favorites album...")
        let favorites = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumFavorites,
            options: nil
        )
        
        if let favoritesAlbum = favorites.firstObject {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if let mediaType = mediaType {
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
            }
            
            let assets = PHAsset.fetchAssets(in: favoritesAlbum, options: fetchOptions)
            var results: [PHAsset] = []
            assets.enumerateObjects { asset, _, stop in
                results.append(asset)
                if results.count >= limit {
                    stop.pointee = true
                }
            }
            
            if !results.isEmpty {
                print("[PhotosProvider] ✅ Found \(results.count) favorites")
                return results
            }
        }
        
        // Final fallback: Recent photos
        print("[PhotosProvider] Fallback 3: Returning recent photos...")
        let recent = await fetchPhotos(limit: limit, daysBack: nil, mediaType: mediaType)
        print("[PhotosProvider] ✅ Found \(recent.count) recent photos")
        return recent
    }
}

// MARK: - Photo Asset Info

struct PhotoAssetInfo {
    let id: String
    let mediaType: String
    let creationDate: String?
    let duration: String?
    let location: CLLocationCoordinate2D?
    let isFavorite: Bool
}

// MARK: - Search Result

struct PhotoSearchResult {
    let asset: PHAsset
    let thumbnail: NSImage?
    let info: PhotoAssetInfo
    let confidence: String? // From AI response
}
