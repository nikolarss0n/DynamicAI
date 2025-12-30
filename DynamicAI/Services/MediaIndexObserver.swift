import Foundation
import Photos
import Combine

// MARK: - Media Index Observer
/// Monitors Photos library for changes and triggers incremental indexing
/// Uses PHPhotoLibraryChangeObserver for reliable change detection

@MainActor
class MediaIndexObserver: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = MediaIndexObserver()
    
    // MARK: - Published State
    
    @Published var pendingChanges: Int = 0
    @Published var lastSyncDate: Date?
    @Published var isAutoIndexEnabled: Bool = true
    
    // MARK: - Configuration
    
    private let debounceInterval: TimeInterval = 5.0  // Wait 5s before processing changes
    private let batchSize = 20  // Process this many at a time
    
    // MARK: - Internal State
    
    private var isRegistered = false
    private var pendingAssetIds: Set<String> = []
    private var deletedAssetIds: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    private var fetchResult: PHFetchResult<PHAsset>?
    
    // MARK: - Services
    
    private let vectorStore = VectorStore.shared
    
    // MARK: - Callbacks
    
    var onNewAssetsDetected: (([PHAsset]) -> Void)?
    var onAssetsDeleted: (([String]) -> Void)?
    
    // MARK: - Initialization
    
    override private init() {
        super.init()
        loadLastSyncDate()
    }
    
    // MARK: - Registration
    
    func startObserving() {
        guard !isRegistered else { return }
        
        // Request authorization first
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            print("[MediaIndexObserver] Not authorized to observe Photos library")
            return
        }
        
        // Register for changes
        PHPhotoLibrary.shared().register(self)
        isRegistered = true
        
        // Fetch initial reference for change detection
        refreshFetchResult()
        
        print("[MediaIndexObserver] Started observing Photos library")
    }
    
    func stopObserving() {
        guard isRegistered else { return }
        
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isRegistered = false
        debounceTask?.cancel()
        
        print("[MediaIndexObserver] Stopped observing Photos library")
    }
    
    // MARK: - PHPhotoLibraryChangeObserver
    
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            await handlePhotoLibraryChange(changeInstance)
        }
    }
    
    private func handlePhotoLibraryChange(_ changeInstance: PHChange) async {
        guard let fetchResult = fetchResult else {
            refreshFetchResult()
            return
        }
        
        guard let changes = changeInstance.changeDetails(for: fetchResult) else {
            return
        }
        
        // Update fetch result
        self.fetchResult = changes.fetchResultAfterChanges
        
        // Track inserted assets
        if let inserted = changes.insertedObjects as? [PHAsset], !inserted.isEmpty {
            print("[MediaIndexObserver] Detected \(inserted.count) new assets")
            for asset in inserted {
                pendingAssetIds.insert(asset.localIdentifier)
            }
        }
        
        // Track changed assets (modifications)
        if let changed = changes.changedObjects as? [PHAsset], !changed.isEmpty {
            print("[MediaIndexObserver] Detected \(changed.count) changed assets")
            for asset in changed {
                pendingAssetIds.insert(asset.localIdentifier)
            }
        }
        
        // Track deleted assets
        if let removed = changes.removedObjects as? [PHAsset], !removed.isEmpty {
            print("[MediaIndexObserver] Detected \(removed.count) deleted assets")
            for asset in removed {
                deletedAssetIds.insert(asset.localIdentifier)
                pendingAssetIds.remove(asset.localIdentifier)
            }
        }
        
        pendingChanges = pendingAssetIds.count + deletedAssetIds.count
        
        // Debounce processing
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            await processPendingChanges()
        }
    }
    
    // MARK: - Process Changes
    
    private func processPendingChanges() async {
        guard isAutoIndexEnabled else {
            print("[MediaIndexObserver] Auto-index disabled, skipping \(pendingChanges) changes")
            return
        }
        
        // Process deletions first (fast)
        if !deletedAssetIds.isEmpty {
            let deleted = Array(deletedAssetIds)
            deletedAssetIds.removeAll()
            
            print("[MediaIndexObserver] Processing \(deleted.count) deletions")
            onAssetsDeleted?(deleted)
            
            // Remove from vector store
            for id in deleted {
                await vectorStore.delete(id: id)
            }
        }
        
        // Process new/changed assets in batches
        if !pendingAssetIds.isEmpty {
            let pending = Array(pendingAssetIds)
            pendingAssetIds.removeAll()
            
            // Fetch actual assets
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "localIdentifier IN %@", pending)
            let assets = PHAsset.fetchAssets(with: options)
            
            var assetsToIndex: [PHAsset] = []
            assets.enumerateObjects { asset, _, _ in
                assetsToIndex.append(asset)
            }
            
            print("[MediaIndexObserver] Processing \(assetsToIndex.count) new/changed assets")
            
            // Notify for indexing
            if !assetsToIndex.isEmpty {
                onNewAssetsDetected?(assetsToIndex)
            }
        }
        
        pendingChanges = 0
        lastSyncDate = Date()
        saveLastSyncDate()
        
        // Save vector store
        await vectorStore.saveToDisk()
    }
    
    // MARK: - Manual Sync
    
    /// Find all assets added since last sync
    func findAssetsSinceLastSync(mediaTypes: [PHAssetMediaType] = [.image, .video]) async -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Filter by date if we have a last sync
        if let lastSync = lastSyncDate {
            options.predicate = NSPredicate(format: "creationDate > %@", lastSync as NSDate)
        }
        
        var assets: [PHAsset] = []
        
        for mediaType in mediaTypes {
            let result = PHAsset.fetchAssets(with: mediaType, options: options)
            result.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }
        }
        
        return assets
    }
    
    /// Force full sync (compare all assets with index)
    func performFullSync() async -> SyncResult {
        print("[MediaIndexObserver] Starting full sync...")
        
        let startTime = Date()
        
        // Fetch all assets
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        var allAssetIds: Set<String> = []
        
        let imageAssets = PHAsset.fetchAssets(with: .image, options: options)
        imageAssets.enumerateObjects { asset, _, _ in
            allAssetIds.insert(asset.localIdentifier)
        }
        
        let videoAssets = PHAsset.fetchAssets(with: .video, options: options)
        videoAssets.enumerateObjects { asset, _, _ in
            allAssetIds.insert(asset.localIdentifier)
        }
        
        // Compare with indexed assets
        let indexedCount = await vectorStore.count
        
        // Find assets not in index
        var missingAssets: [PHAsset] = []
        
        for id in allAssetIds {
            if await vectorStore.get(id: id) == nil {
                // Need to fetch the actual asset
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                if let asset = fetchResult.firstObject {
                    missingAssets.append(asset)
                }
            }
        }
        
        // Find orphaned index entries (assets no longer exist)
        // This would require iterating the vector store - skip for now
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        let result = SyncResult(
            totalAssets: allAssetIds.count,
            indexedAssets: indexedCount,
            missingAssets: missingAssets.count,
            orphanedEntries: 0,
            duration: elapsed
        )
        
        print("[MediaIndexObserver] Full sync complete: \(result)")
        
        // Trigger indexing for missing assets
        if !missingAssets.isEmpty {
            onNewAssetsDetected?(missingAssets)
        }
        
        lastSyncDate = Date()
        saveLastSyncDate()
        
        return result
    }
    
    // MARK: - Helpers
    
    private func refreshFetchResult() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Fetch all media (photos + videos)
        fetchResult = PHAsset.fetchAssets(with: options)
        print("[MediaIndexObserver] Tracking \(fetchResult?.count ?? 0) assets")
    }
    
    private func loadLastSyncDate() {
        lastSyncDate = UserDefaults.standard.object(forKey: "MediaIndexObserver.lastSyncDate") as? Date
    }
    
    private func saveLastSyncDate() {
        UserDefaults.standard.set(lastSyncDate, forKey: "MediaIndexObserver.lastSyncDate")
    }
}

// MARK: - Sync Result

struct SyncResult: CustomStringConvertible {
    let totalAssets: Int
    let indexedAssets: Int
    let missingAssets: Int
    let orphanedEntries: Int
    let duration: TimeInterval
    
    var description: String {
        "SyncResult(total: \(totalAssets), indexed: \(indexedAssets), missing: \(missingAssets), orphaned: \(orphanedEntries), took: \(String(format: "%.1f", duration))s)"
    }
    
    var isComplete: Bool {
        missingAssets == 0 && orphanedEntries == 0
    }
}

// MARK: - Indexing Priority

enum IndexingPriority: Int, Comparable {
    case low = 0       // Old assets
    case normal = 1    // Regular assets
    case high = 2      // Recently added
    case immediate = 3 // User-requested
    
    static func < (lhs: IndexingPriority, rhs: IndexingPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct PendingIndexItem {
    let asset: PHAsset
    let priority: IndexingPriority
    let addedAt: Date
}
