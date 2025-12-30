import SwiftUI
import StoreKit

struct SettingsView: View {
    @StateObject private var storeService = StoreService.shared
    @State private var anthropicKey = ""
    @State private var weatherKey = ""
    @State private var groqKey = ""
    @State private var showingKeysSaved = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: - Subscription Tab
            SubscriptionTab(storeService: storeService)
                .tabItem {
                    Label("Subscription", systemImage: "crown.fill")
                }
                .tag(0)

            // MARK: - API Keys Tab
            APIKeysTab(
                anthropicKey: $anthropicKey,
                weatherKey: $weatherKey,
                groqKey: $groqKey,
                showingKeysSaved: $showingKeysSaved,
                storeService: storeService
            )
            .tabItem {
                Label("API Keys", systemImage: "key.fill")
            }
            .tag(1)
            
            // MARK: - Video Index Tab
            VideoIndexTab()
                .tabItem {
                    Label("Video Index", systemImage: "film.stack")
                }
                .tag(2)

            // MARK: - About Tab
            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle.fill")
                }
                .tag(3)
        }
        .frame(width: 450, height: 450)
        .onAppear {
            loadExistingKeys()
        }
    }

    private func loadExistingKeys() {
        anthropicKey = KeychainService.shared.getAPIKey(for: .anthropic) ?? ""
        weatherKey = KeychainService.shared.getAPIKey(for: .openWeather) ?? ""
        groqKey = KeychainService.shared.getAPIKey(for: .groq) ?? ""
    }
}

// MARK: - Subscription Tab

struct SubscriptionTab: View {
    @ObservedObject var storeService: StoreService

    var body: some View {
        VStack(spacing: 20) {
            // Current Status
            statusCard

            Divider()

            // Products
            if storeService.isLoading {
                ProgressView("Loading plans...")
            } else if storeService.products.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Products not available")
                        .font(.headline)
                    Text("Please check your internet connection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                productsGrid
            }

            Spacer()

            // Restore button
            Button("Restore Purchases") {
                Task {
                    await storeService.restorePurchases()
                }
            }
            .buttonStyle(.link)
        }
        .padding()
    }

    private var statusCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: storeService.isPro ? "crown.fill" : "person.fill")
                        .foregroundStyle(storeService.isPro ? .yellow : .secondary)
                    Text(storeService.isPro ? "Pro" : "Free Plan")
                        .font(.headline)
                }

                if !storeService.isPro {
                    Text("\(storeService.remainingFreeQueries) queries remaining today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unlimited queries")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if storeService.isPro {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var productsGrid: some View {
        VStack(spacing: 12) {
            ForEach(storeService.products, id: \.id) { product in
                ProductRow(product: product, storeService: storeService)
            }
        }
    }
}

struct ProductRow: View {
    let product: Product
    @ObservedObject var storeService: StoreService
    @State private var isPurchasing = false

    var isPurchased: Bool {
        storeService.purchasedProductIDs.contains(product.id)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.displayName)
                    .font(.headline)
                Text(product.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isPurchased {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task {
                        isPurchasing = true
                        defer { isPurchasing = false }
                        _ = try? await storeService.purchase(product)
                    }
                } label: {
                    if isPurchasing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text(product.displayPrice)
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPurchasing)
            }
        }
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - API Keys Tab

struct APIKeysTab: View {
    @Binding var anthropicKey: String
    @Binding var weatherKey: String
    @Binding var groqKey: String
    @Binding var showingKeysSaved: Bool
    @ObservedObject var storeService: StoreService

    var canEditKeys: Bool {
        storeService.hasByok || storeService.isPro
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !canEditKeys {
                // Upsell
                VStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text("Bring Your Own Keys")
                        .font(.headline)

                    Text("Purchase the BYOK option or Pro subscription to use your own API keys for unlimited queries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Anthropic API Key")
                                .font(.headline)
                            SecureField("sk-ant-...", text: $anthropicKey)
                                .textFieldStyle(.roundedBorder)
                            Text("Get your key at console.anthropic.com")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("OpenWeather API Key (Optional)")
                                .font(.headline)
                            SecureField("API key for weather", text: $weatherKey)
                                .textFieldStyle(.roundedBorder)
                            Text("Free at openweathermap.org")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Groq API Key (Optional)")
                                .font(.headline)
                            SecureField("gsk_...", text: $groqKey)
                                .textFieldStyle(.roundedBorder)
                            Text("For video audio transcription. Free at console.groq.com")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                HStack {
                    Spacer()

                    Button("Save Keys") {
                        saveKeys()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .alert("Keys Saved", isPresented: $showingKeysSaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your API keys have been securely saved to the Keychain.")
        }
    }

    private func saveKeys() {
        if !anthropicKey.isEmpty {
            _ = KeychainService.shared.saveAPIKey(anthropicKey, for: .anthropic)
        }
        if !weatherKey.isEmpty {
            _ = KeychainService.shared.saveAPIKey(weatherKey, for: .openWeather)
        }
        if !groqKey.isEmpty {
            _ = KeychainService.shared.saveAPIKey(groqKey, for: .groq)
        }
        showingKeysSaved = true
    }
}

// MARK: - Video Index Tab

struct VideoIndexTab: View {
    @StateObject private var indexService = VideoIndexService.shared
    @State private var isIndexing = false
    @State private var showingClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Status Card
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "film.stack.fill")
                            .foregroundStyle(.blue)
                        Text("Video Index")
                            .font(.headline)
                    }

                    Text("\(indexService.indexedCount) videos indexed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if indexService.indexedCount > 0 {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
            }
            .padding()
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Info
            VStack(alignment: .leading, spacing: 8) {
                Label("Index videos once for instant AI search", systemImage: "bolt.fill")
                Label("Uses Claude Haiku for visual analysis", systemImage: "eye.fill")
                Label("Uses Groq Whisper for audio transcription", systemImage: "waveform")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            // Progress if indexing
            if isIndexing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Indexing videos...")
                            .font(.subheadline)
                    }

                    Text("This runs in the background. Progress shown in notch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            // Actions
            HStack {
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label("Clear Index", systemImage: "trash")
                }
                .disabled(indexService.indexedCount == 0 || isIndexing)

                Spacer()

                Button {
                    startIndexing()
                } label: {
                    Label(isIndexing ? "Indexing..." : "Start Indexing", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isIndexing)
            }

            // Storage location
            Text("Index stored in: ~/Library/Application Support/DynamicAI/video_index/")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .alert("Clear Video Index?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                indexService.clearIndex()
            }
        } message: {
            Text("This will remove all indexed video data. You'll need to re-index to search videos.")
        }
    }

    private func startIndexing() {
        isIndexing = true
        Task {
            await indexService.startIndexing(videos: nil) { progress in
                // Progress is shown in the notch via ContentManager
                Task { @MainActor in
                    ContentManager.shared.showIndexingProgress(progress)
                }
            }
            await MainActor.run {
                isIndexing = false
            }
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 50))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("DynamicAI")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text("Your AI assistant in the notch")
                    .font(.headline)

                Text("Powered by Claude")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 4) {
                Text("Keyboard Shortcut: ⌘⌥Space")
                    .font(.caption)
                Text("Press ESC to dismiss")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    SettingsView()
}
