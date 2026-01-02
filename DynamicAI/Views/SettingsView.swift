import SwiftUI

struct SettingsView: View {
    @State private var anthropicKey = ""
    @State private var groqKey = ""
    @State private var showingKeysSaved = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: - API Keys Tab
            APIKeysTab(
                anthropicKey: $anthropicKey,
                groqKey: $groqKey,
                showingKeysSaved: $showingKeysSaved
            )
            .tabItem {
                Label("API Keys", systemImage: "key.fill")
            }
            .tag(0)

            // MARK: - Media Index Tab
            MediaIndexTab()
                .tabItem {
                    Label("Media Index", systemImage: "photo.stack")
                }
                .tag(1)

            // MARK: - About Tab
            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle.fill")
                }
                .tag(2)
        }
        .frame(width: 500, height: 520)
        .onAppear {
            loadExistingKeys()
        }
    }

    private func loadExistingKeys() {
        anthropicKey = KeychainService.shared.getAPIKey(for: .anthropic) ?? ""
        groqKey = KeychainService.shared.getAPIKey(for: .groq) ?? ""
    }
}

// MARK: - Settings Card Component

struct SettingsCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
            )
    }
}

// MARK: - Glowing Icon Component

struct GlowingIcon: View {
    let systemName: String
    let colors: [Color]
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: colors.first?.opacity(0.4) ?? .clear, radius: 8, y: 2)

            Image(systemName: systemName)
                .font(.system(size: size * 0.42))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
        }
    }
}

// MARK: - API Keys Tab

struct APIKeysTab: View {
    @Binding var anthropicKey: String
    @Binding var groqKey: String
    @Binding var showingKeysSaved: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // API Key Input Cards
                APIKeyInput(
                    title: "Anthropic API Key",
                    placeholder: "sk-ant-...",
                    key: $anthropicKey,
                    helpText: "Get your key at console.anthropic.com",
                    icon: "brain.head.profile",
                    colors: [.orange, .red]
                )

                APIKeyInput(
                    title: "Groq API Key",
                    placeholder: "gsk_...",
                    key: $groqKey,
                    helpText: "For fast LLM parsing. Free at console.groq.com",
                    icon: "waveform",
                    colors: [.green, .mint],
                    isOptional: true
                )

                // Save Button
                Button {
                    saveKeys()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Save All Keys")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
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
        if !groqKey.isEmpty {
            _ = KeychainService.shared.saveAPIKey(groqKey, for: .groq)
        }
        showingKeysSaved = true
    }
}

struct APIKeyInput: View {
    let title: String
    let placeholder: String
    @Binding var key: String
    let helpText: String
    let icon: String
    let colors: [Color]
    var isOptional: Bool = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    GlowingIcon(systemName: icon, colors: colors, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                            if isOptional {
                                Text("Optional")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tertiary.opacity(0.3))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(helpText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                SecureField(placeholder, text: $key)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

// MARK: - Media Index Tab (Aurora Design)

struct MediaIndexTab: View {
    // Photo indexing state
    @State private var isIndexing = false
    @State private var indexingType = ""
    @State private var showingRebuildConfirm = false
    @State private var indexingProgress: Double = 0
    @State private var geoIndexedCount = 0
    @State private var labelIndexedCount = 0
    @State private var statusMessage = ""
    @State private var hasAppeared = false

    // Video test index
    @State private var testVideoIndex: String = "0"

    // Video indexing state (separate)
    @State private var isVideoIndexing = false
    @State private var videoIndexingProgress: Double = 0
    @State private var videoIndexedCount = 0
    @State private var videoStatusMessage = ""
    @State private var showingVideoRebuildConfirm = false

    private var totalIndexed: Int {
        geoIndexedCount + labelIndexedCount
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero Header with Aurora Background
                ZStack {
                    // Aurora mesh background
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: "1a1a2e"),
                                    Color(hex: "16213e"),
                                    Color(hex: "0f0f23")
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Aurora glow effects
                    ZStack {
                        Circle()
                            .fill(Color.aurora.cyan.opacity(0.15))
                            .frame(width: 150, height: 150)
                            .blur(radius: 50)
                            .offset(x: -80, y: -20)

                        Circle()
                            .fill(Color.aurora.purple.opacity(0.12))
                            .frame(width: 120, height: 120)
                            .blur(radius: 40)
                            .offset(x: 60, y: 30)

                        Circle()
                            .fill(Color.aurora.pink.opacity(0.1))
                            .frame(width: 100, height: 100)
                            .blur(radius: 35)
                            .offset(x: 90, y: -40)
                    }

                    // Content
                    VStack(spacing: 16) {
                        // Animated Icon
                        ZStack {
                            // Outer glow ring
                            Circle()
                                .stroke(
                                    AngularGradient(
                                        colors: [Color.aurora.cyan, Color.aurora.purple, Color.aurora.pink, Color.aurora.cyan],
                                        center: .center
                                    ),
                                    lineWidth: 2
                                )
                                .frame(width: 70, height: 70)
                                .opacity(hasAppeared ? 0.6 : 0)
                                .scaleEffect(hasAppeared ? 1 : 0.8)

                            // Icon background
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.aurora.cyan, Color.aurora.purple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 56, height: 56)
                                .shadow(color: Color.aurora.purple.opacity(0.5), radius: 12, y: 4)

                            Image(systemName: "sparkles")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                                .symbolEffect(.pulse.byLayer, options: .repeating)
                        }

                        VStack(spacing: 6) {
                            Text("Smart Photo Search")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            Text(statusMessage.isEmpty ? "Fast location & visual search" : statusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.aurora.textSecondary)
                        }

                        // Status indicator
                        if totalIndexed > 0 && !isIndexing {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.aurora.success)
                                Text("Index Ready")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.aurora.success)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.aurora.success.opacity(0.15))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 28)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )

                // Stats Grid - Photos
                HStack(spacing: 14) {
                    AuroraStatCard(
                        icon: "location.fill",
                        gradient: LinearGradient(colors: [Color.aurora.cyan, Color.aurora.blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                        title: "Locations",
                        count: geoIndexedCount,
                        features: ["GeoHash", "O(1)"]
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(x: hasAppeared ? 0 : -20)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: hasAppeared)

                    AuroraStatCard(
                        icon: "eye.fill",
                        gradient: LinearGradient(colors: [Color.aurora.purple, Color.aurora.pink], startPoint: .topLeading, endPoint: .bottomTrailing),
                        title: "Labels",
                        count: labelIndexedCount,
                        features: ["Vision", "On-Device"]
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(x: hasAppeared ? 0 : 20)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.2), value: hasAppeared)
                }

                // Video Stats Card
                AuroraStatCard(
                    icon: "video.fill",
                    gradient: LinearGradient(colors: [Color.aurora.success, Color.aurora.cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                    title: "Videos",
                    count: videoIndexedCount,
                    features: ["Groq Vision", "Whisper"]
                )
                .opacity(hasAppeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.25), value: hasAppeared)

                // Progress Card (when indexing)
                if isIndexing {
                    AuroraIndexingCard(
                        type: indexingType,
                        progress: indexingProgress,
                        statusMessage: statusMessage,
                        onCancel: cancelIndexing
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .opacity
                    ))
                }

                // Tech Stack Pills
                SettingsCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("POWERED BY")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .tracking(1.5)

                        HStack(spacing: 10) {
                            AuroraTechPill(icon: "mappin.circle.fill", text: "GeoHash", color: Color.aurora.cyan)
                            AuroraTechPill(icon: "eye.fill", text: "Vision", color: Color.aurora.purple)
                            AuroraTechPill(icon: "bolt.fill", text: "Groq", color: Color.aurora.success)
                        }
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.3), value: hasAppeared)

                Divider()
                    .padding(.vertical, 4)

                // Photo Index Action Buttons
                VStack(spacing: 12) {
                    Text("PHOTO INDEX")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .tracking(1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Primary Action Button
                    Button {
                        startIndexing()
                    } label: {
                        HStack(spacing: 10) {
                            if isIndexing {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            } else {
                                Image(systemName: "photo.stack")
                            }
                            Text(isIndexing ? "Indexing Photos..." : "Build Photo Index")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            isIndexing ?
                                AnyShapeStyle(Color.gray.opacity(0.3)) :
                                AnyShapeStyle(LinearGradient(
                                    colors: [Color.aurora.cyan, Color.aurora.purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: isIndexing ? .clear : Color.aurora.purple.opacity(0.3), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .disabled(isIndexing || isVideoIndexing)

                    // Secondary Action
                    Button {
                        showingRebuildConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Clear & Rebuild Photos")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.aurora.error.opacity(0.1))
                        .foregroundStyle(Color.aurora.error)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.aurora.error.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isIndexing || isVideoIndexing)
                }

                Divider()

                // Video Index Action Buttons
                VStack(spacing: 12) {
                    HStack {
                        Text("VIDEO INDEX")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .tracking(1.5)

                        Spacer()

                        Text("Uses Groq API")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }

                    // Video progress card (when indexing)
                    if isVideoIndexing {
                        AuroraIndexingCard(
                            type: "videos",
                            progress: videoIndexingProgress,
                            statusMessage: videoStatusMessage,
                            onCancel: cancelVideoIndexing
                        )
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }

                    // Video Index Button
                    Button {
                        startVideoIndexing()
                    } label: {
                        HStack(spacing: 10) {
                            if isVideoIndexing {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            } else {
                                Image(systemName: "video.fill")
                            }
                            Text(isVideoIndexing ? "Analyzing Videos..." : "Build Video Index")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            isVideoIndexing ?
                                AnyShapeStyle(Color.gray.opacity(0.3)) :
                                AnyShapeStyle(LinearGradient(
                                    colors: [Color.aurora.success, Color.aurora.cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: isVideoIndexing ? .clear : Color.aurora.success.opacity(0.3), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .disabled(isIndexing || isVideoIndexing)

                    // Clear Video Index
                    Button {
                        showingVideoRebuildConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Clear & Rebuild Videos")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.aurora.error.opacity(0.1))
                        .foregroundStyle(Color.aurora.error)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.aurora.error.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isIndexing || isVideoIndexing)

                    // Test buttons
                    HStack(spacing: 8) {
                        TextField("Index", text: $testVideoIndex)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .font(.system(size: 12, design: .monospaced))

                        Button {
                            testGroqVision()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "eye.fill")
                                Text("Vision")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.aurora.purple.opacity(0.1))
                            .foregroundStyle(Color.aurora.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            testPoseAnalysis()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "figure.walk")
                                Text("Pose→LLM")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.aurora.cyan.opacity(0.1))
                            .foregroundStyle(Color.aurora.cyan)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Storage Info
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 10))
                    Text("~/Library/Application Support/DynamicAI/")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            }
            .padding()
        }
        .task {
            await loadIndexStats()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    hasAppeared = true
                }
            }
        }
        .alert("Clear Photo Index & Rebuild?", isPresented: $showingRebuildConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear & Rebuild", role: .destructive) {
                clearAndRebuild()
            }
        } message: {
            Text("This will delete location and label indexes and re-index your photos.")
        }
        .alert("Clear Video Index & Rebuild?", isPresented: $showingVideoRebuildConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear & Rebuild", role: .destructive) {
                clearAndRebuildVideos()
            }
        } message: {
            Text("This will delete video activity index and re-analyze all videos using Groq Vision + Whisper.")
        }
    }

    private func loadIndexStats() async {
        let geoStats = await GeoHashIndex.shared.stats
        let labelStats = await LabelIndex.shared.stats
        let videoStats = await VideoIndex.shared.stats

        await MainActor.run {
            geoIndexedCount = geoStats.photosIndexed
            labelIndexedCount = labelStats.photosIndexed
            videoIndexedCount = videoStats.videosIndexed
        }
    }

    private func startIndexing() {
        isIndexing = true
        indexingProgress = 0
        Task {
            indexingType = "locations"
            statusMessage = "Building GeoHash spatial index..."

            let geoStats = await GeoHashIndex.shared.buildIndex { current, total in
                Task { @MainActor in
                    indexingProgress = Double(current) / Double(total) * 0.3
                    statusMessage = "Geo: \(current)/\(total) photos"
                }
            }

            await MainActor.run {
                geoIndexedCount = geoStats.photosWithLocation
                indexingProgress = 0.3
            }

            indexingType = "labels"
            statusMessage = "Classifying with Apple Vision..."

            let labelStats = await LabelIndex.shared.buildIndex(limit: nil) { current, total, label in
                Task { @MainActor in
                    indexingProgress = 0.3 + (Double(current) / Double(total) * 0.7)
                    statusMessage = "Labels: \(current)/\(total) - \(label)"
                }
            }

            await MainActor.run {
                labelIndexedCount = labelStats.indexed
                isIndexing = false
                indexingType = ""
                indexingProgress = 0
                statusMessage = "\(geoStats.photosWithLocation) geo + \(labelStats.indexed) labels indexed"
            }
        }
    }

    private func clearAndRebuild() {
        Task {
            await GeoHashIndex.shared.clear()
            await LabelIndex.shared.clear()

            await MainActor.run {
                geoIndexedCount = 0
                labelIndexedCount = 0
                startIndexing()
            }
        }
    }

    private func cancelIndexing() {
        isIndexing = false
        indexingType = ""
        indexingProgress = 0
        statusMessage = "Indexing cancelled"
    }

    // MARK: - Video Indexing

    private func startVideoIndexing() {
        isVideoIndexing = true
        videoIndexingProgress = 0
        Task {
            videoStatusMessage = "Analyzing videos with Groq Vision..."

            let stats = await VideoIndex.shared.buildIndex(limit: nil) { current, total, description in
                Task { @MainActor in
                    videoIndexingProgress = Double(current) / Double(max(total, 1))
                    videoStatusMessage = "[\(current)/\(total)] \(description)"
                }
            }

            await MainActor.run {
                videoIndexedCount = stats.indexed
                isVideoIndexing = false
                videoIndexingProgress = 0
                videoStatusMessage = stats.summary
            }
        }
    }

    private func clearAndRebuildVideos() {
        Task {
            await VideoIndex.shared.clear()

            await MainActor.run {
                videoIndexedCount = 0
                startVideoIndexing()
            }
        }
    }

    private func testGroqVision() {
        let index = Int(testVideoIndex) ?? 0
        Task {
            videoStatusMessage = "Testing Groq Vision on video #\(index)..."
            let result = await VideoIndex.shared.testGroqVision(videoIndex: index)
            await MainActor.run {
                videoStatusMessage = "Vision: \(result)"
            }
        }
    }

    private func testPoseAnalysis() {
        let index = Int(testVideoIndex) ?? 0
        Task {
            videoStatusMessage = "Extracting poses from video #\(index)..."
            let result = await VideoIndex.shared.testPoseAnalysis(videoIndex: index)
            await MainActor.run {
                videoStatusMessage = result
            }
        }
    }

    private func cancelVideoIndexing() {
        Task {
            await VideoIndex.shared.cancelIndexing()
            await MainActor.run {
                isVideoIndexing = false
                videoIndexingProgress = 0
                videoStatusMessage = "Indexing cancelled"
            }
        }
    }
}

// MARK: - Aurora Stat Card

struct AuroraStatCard: View {
    let icon: String
    let gradient: LinearGradient
    let title: String
    let count: Int
    let features: [String]

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(gradient)
                        .frame(width: 32, height: 32)
                        .shadow(color: Color.aurora.purple.opacity(0.3), radius: 6, y: 2)

                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Spacer()

                if count > 0 {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.aurora.success)
                }
            }

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Text("\(count)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(gradient)

            HStack(spacing: 6) {
                ForEach(features, id: \.self) { feature in
                    Text(feature)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.aurora.glass)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isHovered ? AnyShapeStyle(gradient) : AnyShapeStyle(Color.white.opacity(0.1)),
                    lineWidth: isHovered ? 1.5 : 0.5
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Aurora Indexing Card

struct AuroraIndexingCard: View {
    let type: String
    let progress: Double
    let statusMessage: String
    let onCancel: () -> Void

    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                // Animated progress ring
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 3)
                        .frame(width: 44, height: 44)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AngularGradient(
                                colors: type == "locations" ?
                                    [Color.aurora.cyan, Color.aurora.blue, Color.aurora.cyan] :
                                    [Color.aurora.purple, Color.aurora.pink, Color.aurora.purple],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(-90 + rotation))

                    Image(systemName: type == "locations" ? "location.fill" : "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(type == "locations" ? Color.aurora.cyan : Color.aurora.purple)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Indexing \(type.capitalized)")
                        .font(.system(size: 14, weight: .semibold))

                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.1))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: type == "locations" ?
                                    [Color.aurora.cyan, Color.aurora.blue] :
                                    [Color.aurora.purple, Color.aurora.pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progress)
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
            }
            .frame(height: 6)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Aurora Tech Pill

struct AuroraTechPill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// Legacy components kept for backward compatibility
struct MediaStatCard: View {
    let icon: String
    let iconColors: [Color]
    let title: String
    let count: Int
    let features: [String]

    var body: some View {
        AuroraStatCard(
            icon: icon,
            gradient: LinearGradient(colors: iconColors, startPoint: .topLeading, endPoint: .bottomTrailing),
            title: title,
            count: count,
            features: features
        )
    }
}

struct TechBadge: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        AuroraTechPill(icon: icon, text: text, color: color)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated Logo
            ZStack {
                // Glow effect
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.purple.opacity(0.3), .clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                    .scaleEffect(isAnimating ? 1.1 : 1.0)

                GlowingIcon(systemName: "sparkles", colors: [.purple, .blue, .cyan], size: 70)
                    .scaleEffect(isAnimating ? 1.02 : 1.0)
            }
            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: isAnimating)
            .onAppear { isAnimating = true }

            VStack(spacing: 6) {
                Text("DynamicAI")
                    .font(.title.weight(.bold))

                Text("Version 1.0.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }

            Divider()
                .frame(width: 100)

            VStack(spacing: 8) {
                Text("Your AI assistant in the notch")
                    .font(.headline)

                HStack(spacing: 4) {
                    Text("Powered by")
                        .foregroundStyle(.secondary)
                    Text("Claude")
                        .foregroundStyle(.orange)
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            }

            Spacer()

            // Keyboard Shortcuts
            SettingsCard(padding: 14) {
                VStack(spacing: 10) {
                    KeyboardShortcutRow(keys: ["⌘", "⌥", "Space"], action: "Open DynamicAI")
                    Divider()
                    KeyboardShortcutRow(keys: ["ESC"], action: "Dismiss")
                    Divider()
                    KeyboardShortcutRow(keys: ["⌘", "Enter"], action: "Send message")
                }
            }
            .padding(.horizontal)
        }
        .padding()
    }
}

struct KeyboardShortcutRow: View {
    let keys: [String]
    let action: String

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Spacer()

            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
