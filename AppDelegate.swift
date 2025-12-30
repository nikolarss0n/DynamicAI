import AppKit
import SwiftUI
import AVKit
import Combine
import DynamicNotchKit
import MapKit
import CoreLocation
import Photos

// MARK: - Notifications

extension Notification.Name {
    static let hideNotch = Notification.Name("hideNotch")
}

// MARK: - Content Types

enum NotchContentType {
    case chat
    case images([MediaItem])
    case video(URL)
    case videoWithInfo(VideoInfo)
    case movieList([MovieDisplayItem])
    case movieDetail(MovieDisplayItem, String) // Movie + additional info/rumors
    case calendarEvents([CalendarDisplayItem])
    case reminderList([ReminderDisplayItem])
    case contactList([ContactDisplayItem])
    case systemStats(SystemDisplayInfo)
    case placeList([PlaceDisplayItem], NSImage?) // Places + optional map snapshot
    case loading(String)
    case richText(String, String) // Title + markdown-ish content
    case batteryStatus(BatteryInfo)
    case weatherInfo(WeatherInfo)
    case tripSummary(TripInfo)
    case photoSearchResults([PhotoSearchResult], NSImage?) // Photo/video search results + contact sheet
    case indexingProgress(IndexingProgress) // Video indexing progress
}

// MARK: - System Info Models

struct BatteryInfo {
    let macPercent: Int
    let macIsCharging: Bool
    let devices: [DeviceBattery]

    struct DeviceBattery: Identifiable {
        let id = UUID()
        let name: String
        let percent: Int
        let icon: String // SF Symbol name
    }
}

struct WeatherInfo {
    let location: String
    let temperature: Int
    let feelsLike: Int
    let condition: String
    let icon: String // SF Symbol name
    let humidity: Int
    let suggestions: [String]
}

struct TripInfo {
    let destination: String
    let weather: WeatherInfo?
    let battery: BatteryInfo
    let events: [CalendarDisplayItem]
    let suggestions: [String]
    let route: RouteInfo?
}

struct RouteInfo {
    let destinationCoordinate: CLLocationCoordinate2D
    let sourceCoordinate: CLLocationCoordinate2D?
    let distance: Double? // in meters
    let duration: Double? // in seconds
    let routePolyline: MKPolyline?
}

struct MovieDisplayItem: Identifiable {
    let id: Int
    let title: String
    let overview: String
    let posterURL: URL?
    let trailerURL: URL?
    let releaseDate: String
    let rating: Double
}

struct CalendarDisplayItem: Identifiable {
    let id: String
    let title: String
    let time: String // Formatted time string for display
    let location: String?
    let isAllDay: Bool
    let startDate: Date
    var endDate: Date { startDate.addingTimeInterval(3600) } // Default 1h duration for display
}

struct ReminderDisplayItem: Identifiable {
    let id: String
    let title: String
    let notes: String?
    let dueDate: String?
    let isCompleted: Bool
    let priority: String
    let listName: String
}

struct ContactDisplayItem: Identifiable {
    let id: String
    let name: String
    let nickname: String?
    let organization: String?
    let jobTitle: String?
    let phones: [String]
    let emails: [String]
    let address: String?
    let birthday: String?
}

struct SystemDisplayInfo {
    let cpuUsage: Int
    let totalMemoryGB: Double
    let usedMemoryGB: Double
    let memoryUsagePercent: Int
    let totalDiskGB: Double
    let freeDiskGB: Double
    let diskUsagePercent: Int
    let uptime: String
}

struct PlaceDisplayItem: Identifiable {
    let id: UUID
    let name: String
    let category: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    let phoneNumber: String?
    let url: URL?
    var distanceText: String? // e.g., "2.3 km" or "15 min drive"
}

struct VideoInfo {
    let videoURL: URL
    let title: String
    let description: String
    let metadata: [String: String] // e.g., ["Director": "John", "Year": "2024"]
}

struct MediaItem: Identifiable {
    let id = UUID()
    let title: String
    let imageURL: URL?
    let image: NSImage?

    init(title: String, url: URL) {
        self.title = title
        self.imageURL = url
        self.image = nil
    }

    init(title: String, image: NSImage) {
        self.title = title
        self.imageURL = nil
        self.image = image
    }
}

// MARK: - Content Manager

@MainActor
class ContentManager: ObservableObject {
    static let shared = ContentManager()
    @Published var contentType: NotchContentType = .chat
    @Published var contentTypeId: UUID = UUID()

    // Chat history - persists across view recreations
    @Published var chatMessages: [ChatMessage] = []

    // Context tracking for follow-up questions
    @Published var lastSelectedMovie: MovieDisplayItem?
    @Published var lastMovieList: [MovieDisplayItem] = []

    private init() {}

    func resetChat() {
        chatMessages = []
        lastSelectedMovie = nil
        lastMovieList = []
        updateContent(.chat)
    }

    private func updateContent(_ type: NotchContentType) {
        withAnimation(.easeInOut(duration: 0.25)) {
            contentType = type
            contentTypeId = UUID()
        }
    }

    func showChat() {
        updateContent(.chat)
    }

    func showImages(_ items: [MediaItem]) {
        updateContent(.images(items))
    }

    func showVideo(_ url: URL) {
        updateContent(.video(url))
    }

    func showVideoWithInfo(_ info: VideoInfo) {
        updateContent(.videoWithInfo(info))
    }

    func showMovies(_ movies: [MovieDisplayItem]) {
        lastMovieList = movies
        updateContent(.movieList(movies))
    }

    func showMovieDetail(_ movie: MovieDisplayItem, info: String) {
        lastSelectedMovie = movie
        updateContent(.movieDetail(movie, info))
    }

    func showCalendar(_ events: [CalendarDisplayItem]) {
        updateContent(.calendarEvents(events))
    }

    func showReminders(_ reminders: [ReminderDisplayItem]) {
        updateContent(.reminderList(reminders))
    }

    func showContacts(_ contacts: [ContactDisplayItem]) {
        updateContent(.contactList(contacts))
    }

    func showSystemInfo(_ info: SystemDisplayInfo) {
        updateContent(.systemStats(info))
    }

    func showLoading(_ message: String) {
        // Loading is instant, no animation
        contentType = .loading(message)
        contentTypeId = UUID()
    }
    
    func showIndexingProgress(_ progress: IndexingProgress) {
        contentType = .indexingProgress(progress)
        contentTypeId = UUID()
    }

    func showRichText(title: String, content: String) {
        updateContent(.richText(title, content))
    }

    func showBattery(_ info: BatteryInfo) {
        updateContent(.batteryStatus(info))
    }

    func showWeather(_ info: WeatherInfo) {
        updateContent(.weatherInfo(info))
    }

    func showTrip(_ info: TripInfo) {
        updateContent(.tripSummary(info))
    }

    func showPlaces(_ places: [PlaceDisplayItem], mapSnapshot: NSImage?) {
        updateContent(.placeList(places, mapSnapshot))
    }

    func showPhotoResults(_ results: [PhotoSearchResult], contactSheet: NSImage?) {
        updateContent(.photoSearchResults(results, contactSheet))
    }

    func selectMovie(_ movie: MovieDisplayItem) {
        lastSelectedMovie = movie
    }

    // Get context for Claude
    var currentContext: [String: Any] {
        var context: [String: Any] = [:]
        if let movie = lastSelectedMovie {
            context["last_selected_movie"] = [
                "id": movie.id,
                "title": movie.title,
                "overview": movie.overview,
                "release_date": movie.releaseDate
            ]
        }
        if !lastMovieList.isEmpty {
            context["recent_movies"] = lastMovieList.map { $0.title }
        }
        return context
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: DynamicNotch<DynamicContentView, EmptyView, EmptyView>?
    private var floatingPanel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private var eventMonitor: Any?
    private var clickOutsideMonitor: Any?
    private var isVisible = false

    /// Detects if the current Mac has a notch (MacBook Pro 14"/16" 2021+, MacBook Air 2022+)
    private var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        // Macs with notch have safeAreaInsets at the top
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Setup menu bar
        setupMenuBar()

        // Setup global hotkey
        setupHotkey()

        // Initialize appropriate UI based on hardware
        if hasNotch {
            // Initialize DynamicNotch for notch Macs
            notch = DynamicNotch(hoverBehavior: []) {
                DynamicContentView()
            }
            print("DynamicAI ready (notch mode). Press ⌘⌥Space or click menu bar icon.")
        } else {
            // Initialize floating panel for non-notch Macs
            setupFloatingPanel()
            print("DynamicAI ready (floating panel mode). Press ⌘⌥Space or click menu bar icon.")
        }

        // Listen for hide notifications
        NotificationCenter.default.addObserver(forName: .hideNotch, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.hideUI()
            }
        }
    }

    private func setupFloatingPanel() {
        let contentView = DynamicContentView()
        let hostingView = NSHostingView(rootView: contentView)

        floatingPanel = FloatingPanel(contentView: hostingView)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "DynamicAI")
            // Set sendAction on right click to show menu
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle (⌘⌥Space)", action: #selector(toggleNotch), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Demo: Image Gallery", action: #selector(showDemoImages), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Demo: Video Player", action: #selector(showDemoVideo), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Demo: Movie Info", action: #selector(showDemoMovieInfo), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        // Check if right click (show menu) or left click (toggle)
        if let event = NSApp.currentEvent {
            if event.type == .rightMouseUp {
                statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
            } else {
                toggleNotch()
            }
        }
    }

    private func setupHotkey() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⌘ + Option + Space
            if event.modifierFlags.contains([.command, .option]) && event.keyCode == 49 {
                Task { @MainActor in
                    self?.toggleNotch()
                }
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .option]) && event.keyCode == 49 {
                Task { @MainActor in
                    self?.toggleNotch()
                }
                return nil
            }
            if event.keyCode == 53 { // ESC
                Task { @MainActor in
                    await self?.hideUI()
                }
                return nil
            }
            return event
        }
    }

    @objc private func toggleNotch() {
        Task {
            if isVisible {
                await hideUI()
            } else {
                await showUI()
            }
        }
    }

    private func showUI() async {
        if hasNotch {
            await notch?.expand()
        } else {
            floatingPanel?.show()
        }
        isVisible = true
        startClickOutsideMonitor()
    }

    private func hideUI() async {
        if hasNotch {
            await notch?.hide()
        } else {
            floatingPanel?.hide()
        }
        isVisible = false
        stopClickOutsideMonitor()
    }

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                await self?.hideUI()
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private var settingsWindow: NSWindow?

    @objc private func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "DynamicAI Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.isReleasedWhenClosed = false

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showDemoImages() {
        // Sample car images from Unsplash
        let demoItems: [MediaItem] = [
            MediaItem(title: "Car 1", url: URL(string: "https://images.unsplash.com/photo-1544636331-e26879cd4d9b?w=600")!),
            MediaItem(title: "Car 2", url: URL(string: "https://images.unsplash.com/photo-1503376780353-7e6692767b70?w=600")!),
            MediaItem(title: "Car 3", url: URL(string: "https://images.unsplash.com/photo-1525609004556-c46c7d6cf023?w=600")!),
            MediaItem(title: "Car 4", url: URL(string: "https://images.unsplash.com/photo-1492144534655-ae79c964c9d7?w=600")!)
        ]
        ContentManager.shared.showImages(demoItems)
        Task {
            await showUI()
        }
    }

    @objc private func showDemoVideo() {
        // Sample video (Big Buck Bunny trailer)
        let videoURL = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!
        ContentManager.shared.showVideo(videoURL)
        Task {
            await showUI()
        }
    }

    @objc private func showDemoMovieInfo() {
        let movieInfo = VideoInfo(
            videoURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
            title: "Big Buck Bunny",
            description: "A large and lovable rabbit deals with three tiny bullies, led by a flying squirrel, who are determined to ruin his day.",
            metadata: [
                "Director": "Sacha Goedegebure",
                "Year": "2008",
                "Duration": "9:56",
                "Genre": "Animation, Comedy",
                "Studio": "Blender Foundation"
            ]
        )
        ContentManager.shared.showVideoWithInfo(movieInfo)
        Task {
            await showUI()
        }
    }
}

// Chat content for DynamicNotch
struct ChatContentView: View {
    @StateObject private var manager = ContentManager.shared
    @State private var inputText = ""
    @State private var isLoading = false
    @FocusState private var isInputFocused: Bool

    private var messages: [ChatMessage] {
        manager.chatMessages
    }

    // Calculate dynamic size based on screen and content (Column-based sizing)
    private var windowWidth: CGFloat {
        guard let screen = NSScreen.main else { return 400 }
        
        // Minimum width for usability
        let minWidth: CGFloat = 340
        
        // Column-based sizing: grows as conversation gets longer
        let targetWidth: CGFloat
        if messages.count > 10 {
            // Many messages = wider for better readability
            targetWidth = 550
        } else if messages.count > 5 {
            // Medium conversation = moderate width
            targetWidth = 480
        } else {
            // Few or no messages = compact
            targetWidth = 400
        }
        
        // Constrain to screen size (max 50% of screen width)
        let maxWidth = min(screen.frame.width * 0.5, 650)
        
        return min(max(targetWidth, minWidth), maxWidth)
    }
    
    private var windowHeight: CGFloat {
        guard let screen = NSScreen.main else { return 500 }
        
        // Base height components
        let headerHeight: CGFloat = 44  // Header with padding
        let inputHeight: CGFloat = 46   // Input field with padding
        let dividers: CGFloat = 2       // Two dividers
        
        // Calculate content height based on number of messages
        let messageCount = messages.count
        let estimatedMessageHeight: CGFloat = 60 // Average message height
        let estimatedContentHeight = CGFloat(messageCount) * estimatedMessageHeight
        
        // Minimum content area for empty state
        let minContentHeight: CGFloat = 200
        
        // Calculate total with constraints
        let totalHeight = headerHeight + max(estimatedContentHeight, minContentHeight) + inputHeight + dividers
        
        // Constrain to screen size (leave some space at bottom)
        let maxHeight = screen.frame.height * 0.7
        let minHeight: CGFloat = 380
        
        return min(max(totalHeight, minHeight), maxHeight)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                Text("AI Assistant")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty && !isLoading {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text("How can I help?")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)

                                // Suggestion chips
                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        SuggestionChip(text: "Upcoming movies", icon: "film") {
                                            inputText = "Show me upcoming movies"
                                            sendMessage()
                                        }
                                        SuggestionChip(text: "Today's calendar", icon: "calendar") {
                                            inputText = "What's on my calendar today?"
                                            sendMessage()
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        SuggestionChip(text: "Popular movies", icon: "star") {
                                            inputText = "Show popular movies right now"
                                            sendMessage()
                                        }
                                        SuggestionChip(text: "This week", icon: "calendar.badge.clock") {
                                            inputText = "Show my calendar for this week"
                                            sendMessage()
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 40)
                        } else {
                            ForEach(messages) { msg in
                                MessageRow(message: msg)
                                    .id(msg.id)
                            }

                            // Loading indicator
                            if isLoading {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Thinking...")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input
            HStack(spacing: 10) {
                TextField("Ask anything...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isInputFocused)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            inputText.isEmpty ? AnyShapeStyle(.secondary) :
                            AnyShapeStyle(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty)
            }
            .padding(12)
        }
        .frame(width: windowWidth, height: windowHeight)
        .animation(.smooth(duration: 0.3), value: windowWidth)
        .animation(.smooth(duration: 0.3), value: windowHeight)
        .onAppear { isInputFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SendChatMessage"))) { notification in
            if let message = notification.userInfo?["message"] as? String {
                inputText = message
                sendMessage()
            }
        }
    }

    private func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        manager.chatMessages.append(ChatMessage(role: .user, content: inputText))
        let query = inputText
        inputText = ""
        isLoading = true

        Task {
            let response = await AIService.shared.query(query)
            isLoading = false

            switch response {
            case .text(let text):
                manager.chatMessages.append(ChatMessage(role: .assistant, content: text))

            case .toolResults(let text, let results):
                // Show brief confirmation
                if !text.isEmpty {
                    manager.chatMessages.append(ChatMessage(role: .assistant, content: text))
                }

                // Handle tool results - display appropriate view
                for result in results {
                    handleToolResult(result)
                }

            case .error(let error):
                manager.chatMessages.append(ChatMessage(role: .assistant, content: "Error: \(error)"))
            }
        }
    }

    private func handleToolResult(_ result: ToolResult) {
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        switch result.result {
        case .movies(let movies):
            let displayItems = movies.map { movie in
                MovieDisplayItem(
                    id: movie.id,
                    title: movie.title,
                    overview: movie.overview,
                    posterURL: movie.posterURL,
                    trailerURL: movie.trailerURL,
                    releaseDate: movie.releaseDate,
                    rating: movie.rating
                )
            }
            if !displayItems.isEmpty {
                ContentManager.shared.showMovies(displayItems)
            }

        case .movieDetail(let movie, let info):
            ContentManager.shared.showMovieDetail(movie, info: info)

        case .calendarEvents(let events):
            let displayItems = events.map { event in
                let timeStr = event.isAllDay ? "All day" : formatter.string(from: event.startDate)
                return CalendarDisplayItem(
                    id: event.id,
                    title: event.title,
                    time: timeStr,
                    location: event.location,
                    isAllDay: event.isAllDay,
                    startDate: event.startDate
                )
            }
            ContentManager.shared.showCalendar(displayItems)

        case .reminders(let reminders):
            let displayItems = reminders.map { reminder in
                ReminderDisplayItem(
                    id: reminder.id,
                    title: reminder.title,
                    notes: reminder.notes,
                    dueDate: reminder.dueDateText,
                    isCompleted: reminder.isCompleted,
                    priority: reminder.priorityText,
                    listName: reminder.listName
                )
            }
            ContentManager.shared.showReminders(displayItems)

        case .contacts(let contacts):
            let displayItems = contacts.map { contact in
                ContactDisplayItem(
                    id: contact.id,
                    name: contact.name,
                    nickname: contact.nickname,
                    organization: contact.organization,
                    jobTitle: contact.jobTitle,
                    phones: contact.phones,
                    emails: contact.emails,
                    address: contact.address,
                    birthday: contact.birthday
                )
            }
            ContentManager.shared.showContacts(displayItems)

        case .systemInfo(let info):
            let displayInfo = SystemDisplayInfo(
                cpuUsage: info.cpuUsage,
                totalMemoryGB: info.totalMemoryGB,
                usedMemoryGB: info.usedMemoryGB,
                memoryUsagePercent: info.memoryUsagePercent,
                totalDiskGB: info.totalDiskGB,
                freeDiskGB: info.freeDiskGB,
                diskUsagePercent: info.diskUsagePercent,
                uptime: info.uptime
            )
            ContentManager.shared.showSystemInfo(displayInfo)

        case .carResults(let cars):
            // Show as images for now
            let items = cars.compactMap { car -> MediaItem? in
                guard let url = car.imageURL else { return nil }
                return MediaItem(title: "\(car.year) \(car.make) \(car.model)", url: url)
            }
            if !items.isEmpty {
                ContentManager.shared.showImages(items)
            }

        case .battery(let info):
            ContentManager.shared.showBattery(info)

        case .weather(let info):
            ContentManager.shared.showWeather(info)

        case .trip(let info):
            ContentManager.shared.showTrip(info)

        case .places(let places, let mapSnapshot):
            let displayItems = places.map { place in
                PlaceDisplayItem(
                    id: place.id,
                    name: place.name,
                    category: place.category,
                    address: place.address,
                    coordinate: place.coordinate,
                    phoneNumber: place.phoneNumber,
                    url: place.url,
                    distanceText: place.distanceText
                )
            }
            ContentManager.shared.showPlaces(displayItems, mapSnapshot: mapSnapshot)

        case .photoResults(let results, let contactSheet):
            ContentManager.shared.showPhotoResults(results, contactSheet: contactSheet)

        case .text(let text):
            manager.chatMessages.append(ChatMessage(role: .assistant, content: text))

        case .error(let error):
            manager.chatMessages.append(ChatMessage(role: .assistant, content: "Tool error: \(error)"))
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 50) }

            Text(message.content)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == .user
                        ? AnyShapeStyle(LinearGradient(colors: [.purple.opacity(0.8), .blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.gray.opacity(0.15))
                )
                .foregroundColor(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if message.role == .assistant { Spacer(minLength: 50) }
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String

    enum Role { case user, assistant }
}

// MARK: - Suggestion Chip

struct SuggestionChip: View {
    let text: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(text)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dynamic Content View

struct DynamicContentView: View {
    @StateObject private var manager = ContentManager.shared

    var body: some View {
        Group {
            switch manager.contentType {
            case .chat:
                ChatContentView()
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
            case .images(let items):
                ImageGalleryView(items: items)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            case .video(let url):
                VideoContentView(videoURL: url)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            case .videoWithInfo(let info):
                VideoWithInfoView(info: info)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            case .movieList(let movies):
                MovieListView(movies: movies)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            case .movieDetail(let movie, let info):
                MovieDetailView(movie: movie, additionalInfo: info)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            case .calendarEvents(let events):
                CalendarListView(events: events)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            case .reminderList(let reminders):
                RemindersListView(reminders: reminders)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            case .contactList(let contacts):
                ContactsListView(contacts: contacts)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            case .systemStats(let info):
                SystemInfoView(info: info)
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
            case .placeList(let places, let mapSnapshot):
                PlaceListView(places: places, mapSnapshot: mapSnapshot)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            case .loading(let message):
                LoadingView(message: message)
                    .transition(.opacity)
            case .richText(let title, let content):
                RichTextView(title: title, content: content)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            case .batteryStatus(let info):
                BatteryStatusView(info: info)
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
            case .weatherInfo(let info):
                WeatherStatusView(info: info)
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
            case .tripSummary(let info):
                TripSummaryView(info: info)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            case .photoSearchResults(let results, let contactSheet):
                PhotoSearchResultsView(results: results, contactSheet: contactSheet)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            case .indexingProgress(let progress):
                IndexingProgressView(progress: progress)
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.contentTypeId)
    }
}

// MARK: - Image Gallery View

struct ImageGalleryView: View {
    let items: [MediaItem]
    @State private var selectedIndex: Int = 0

    private var viewWidth: CGFloat { 450 }
    private var viewHeight: CGFloat { 320 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "photo.stack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("Gallery")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Text("\(selectedIndex + 1) / \(items.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Button {
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Main Image
            if !items.isEmpty {
                ZStack {
                    if let image = items[selectedIndex].image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if let url = items[selectedIndex].imageURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fit)
                            case .failure:
                                Image(systemName: "photo")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                            default:
                                ProgressView()
                            }
                        }
                    }

                    // Navigation arrows
                    HStack {
                        Button { navigatePrevious() } label: {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .opacity(selectedIndex > 0 ? 1 : 0.3)
                        .disabled(selectedIndex == 0)

                        Spacer()

                        Button { navigateNext() } label: {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .opacity(selectedIndex < items.count - 1 ? 1 : 0.3)
                        .disabled(selectedIndex >= items.count - 1)
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.05))
            }

            Divider()

            // Thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ThumbnailView(item: item, isSelected: index == selectedIndex)
                            .onTapGesture { selectedIndex = index }
                    }
                }
                .padding(8)
            }
            .frame(height: 70)
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    private func navigatePrevious() {
        if selectedIndex > 0 { selectedIndex -= 1 }
    }

    private func navigateNext() {
        if selectedIndex < items.count - 1 { selectedIndex += 1 }
    }
}

struct ThumbnailView: View {
    let item: MediaItem
    let isSelected: Bool

    var body: some View {
        Group {
            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let url = item.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.gray.opacity(0.3)
                    }
                }
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Video Content View

struct VideoContentView: View {
    let videoURL: URL
    @State private var player: AVPlayer?

    private var viewWidth: CGFloat { 480 }
    private var viewHeight: CGFloat { 320 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.purple)

                Text("Video")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Button {
                    player?.pause()
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Video Player
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .onAppear {
                    player = AVPlayer(url: videoURL)
                    player?.play()
                }
                .onDisappear {
                    player?.pause()
                    player = nil
                }
        }
        .frame(width: viewWidth, height: viewHeight)
    }
}

// MARK: - Video With Info View

struct VideoWithInfoView: View {
    let info: VideoInfo
    @State private var player: AVPlayer?

    private var viewWidth: CGFloat { 680 }
    private var viewHeight: CGFloat { 340 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "film.stack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.purple)

                Text(info.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer()

                Button {
                    player?.pause()
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content: Video + Info side by side
            HStack(spacing: 0) {
                // Video Player (left)
                VideoPlayer(player: player)
                    .frame(width: 400)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(12)

                Divider()

                // Info Panel (right)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Description
                        Text(info.description)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !info.metadata.isEmpty {
                            Divider()

                            // Metadata
                            ForEach(Array(info.metadata.keys.sorted()), id: \.self) { key in
                                HStack(alignment: .top) {
                                    Text(key)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 70, alignment: .leading)

                                    Text(info.metadata[key] ?? "")
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(width: 240)
            }
        }
        .frame(width: viewWidth, height: viewHeight)
        .onAppear {
            player = AVPlayer(url: info.videoURL)
            player?.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Movie List View

struct MovieListView: View {
    let movies: [MovieDisplayItem]
    @State private var selectedMovie: MovieDisplayItem?
    @State private var followUpText: String = ""
    @State private var isProcessing: Bool = false

    private var viewWidth: CGFloat { 520 }
    private var viewHeight: CGFloat { 420 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "film")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Movies")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Button {
                    ContentManager.shared.resetChat()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset chat")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Movie Grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(movies) { movie in
                        MovieCardView(movie: movie, isSelected: selectedMovie?.id == movie.id)
                            .onTapGesture {
                                selectedMovie = movie
                                ContentManager.shared.selectMovie(movie) // Track for context
                                showMovieDetail(movie)
                            }
                    }
                }
                .padding(12)
            }

            Divider()

            // Follow-up input
            HStack(spacing: 10) {
                TextField("Ask about a movie...", text: $followUpText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        sendFollowUp()
                    }

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        sendFollowUp()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(followUpText.isEmpty ? .gray : .orange)
                    }
                    .buttonStyle(.plain)
                    .disabled(followUpText.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    private func sendFollowUp() {
        guard !followUpText.isEmpty else { return }
        let query = followUpText
        followUpText = ""
        isProcessing = true

        Task {
            let response = await AIService.shared.query(query)
            await MainActor.run {
                isProcessing = false
                handleResponse(response)
            }
        }
    }

    private func handleResponse(_ response: AIResponse) {
        switch response {
        case .toolResults(_, let results):
            for result in results {
                switch result.result {
                case .movieDetail(let movie, let info):
                    ContentManager.shared.showMovieDetail(movie, info: info)
                case .movies(let movies):
                    let displayItems = movies.map { movie in
                        MovieDisplayItem(
                            id: movie.id,
                            title: movie.title,
                            overview: movie.overview,
                            posterURL: movie.posterURL,
                            trailerURL: movie.trailerURL,
                            releaseDate: movie.releaseDate,
                            rating: movie.rating
                        )
                    }
                    ContentManager.shared.showMovies(displayItems)
                default:
                    break
                }
            }
        case .text(let text):
            // Show as rich text if there's a selected movie
            if let movie = selectedMovie {
                ContentManager.shared.showMovieDetail(movie, info: text)
            }
        case .error(let error):
            print("Error: \(error)")
        }
    }

    private func showMovieDetail(_ movie: MovieDisplayItem) {
        print("🎬 Tapped movie: \(movie.title), trailerURL: \(movie.trailerURL?.absoluteString ?? "nil")")
        if let trailerURL = movie.trailerURL {
            // Open trailer in Safari
            NSWorkspace.shared.open(trailerURL)
            // Close the notch
            NotificationCenter.default.post(name: .hideNotch, object: nil)
        } else {
            print("⚠️ No trailer URL for \(movie.title)")
        }
    }
}

struct MovieCardView: View {
    let movie: MovieDisplayItem
    let isSelected: Bool

    private var hasTrailer: Bool { movie.trailerURL != nil }

    var body: some View {
        VStack(spacing: 6) {
            // Poster with trailer indicator
            ZStack(alignment: .bottomTrailing) {
                if let posterURL = movie.posterURL {
                    AsyncImage(url: posterURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(2/3, contentMode: .fill)
                        case .failure:
                            posterPlaceholder
                        default:
                            ProgressView()
                                .frame(height: 140)
                        }
                    }
                    .frame(width: 100, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    posterPlaceholder
                }

                // Trailer indicator badge
                trailerBadge
                    .padding(4)
            }

            // Title
            Text(movie.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 100)

            // Date & Rating
            HStack(spacing: 6) {
                Text(formatReleaseDate(movie.releaseDate))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3, height: 3)

                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", movie.rating))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
    }

    private var trailerBadge: some View {
        Group {
            if hasTrailer {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(.black.opacity(0.7)))
            } else {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(4)
                    .background(Circle().fill(.gray.opacity(0.6)))
            }
        }
    }

    private var posterPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 100, height: 150)
            .overlay(
                Image(systemName: "film")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            )
    }

    private func formatReleaseDate(_ dateString: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"

        guard let date = inputFormatter.date(from: dateString) else {
            return dateString
        }

        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
        let releaseDay = calendar.startOfDay(for: date)

        let days = calendar.dateComponents([.day], from: now, to: releaseDay).day ?? 0

        // Tomorrow
        if days == 1 {
            return "Tomorrow"
        }

        // Within a week (future)
        if days > 1 && days <= 7 {
            return "\(days)d"
        }

        // Always show year for clarity
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MMM d, yyyy"
        return outputFormatter.string(from: date)
    }
}

// MARK: - Movie Detail View

struct MovieDetailView: View {
    let movie: MovieDisplayItem
    let additionalInfo: String
    @State private var chatText: String = ""
    @State private var isProcessing: Bool = false

    private var viewWidth: CGFloat { 580 }
    private var viewHeight: CGFloat { 420 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    ContentManager.shared.showMovies(ContentManager.shared.lastMovieList)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)

                Image(systemName: "film.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)

                Text(movie.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer()

                if let trailerURL = movie.trailerURL {
                    Button {
                        NSWorkspace.shared.open(trailerURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Trailer")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.orange))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    ContentManager.shared.resetChat()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset chat")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content: Poster left, info right
            HStack(alignment: .top, spacing: 16) {
                // Poster
                if let posterURL = movie.posterURL {
                    AsyncImage(url: posterURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(2/3, contentMode: .fit)
                        default:
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                        }
                    }
                    .frame(width: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 4)
                }

                // Info
                VStack(alignment: .leading, spacing: 12) {
                    // Meta info
                    HStack(spacing: 12) {
                        Label(movie.releaseDate, systemImage: "calendar")
                        Label(String(format: "%.1f", movie.rating), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    // Overview
                    Text(movie.overview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)

                    Divider()

                    // Additional info from Claude
                    ScrollView {
                        Text(additionalInfo)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)

            Divider()

            // Chat input
            HStack(spacing: 10) {
                TextField("Ask something...", text: $chatText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        sendChat()
                    }

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        sendChat()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(chatText.isEmpty ? .gray : .orange)
                    }
                    .buttonStyle(.plain)
                    .disabled(chatText.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    private func sendChat() {
        guard !chatText.isEmpty else { return }
        let query = chatText
        chatText = ""
        isProcessing = true

        Task {
            let response = await AIService.shared.query(query)
            await MainActor.run {
                isProcessing = false
                handleResponse(response)
            }
        }
    }

    private func handleResponse(_ response: AIResponse) {
        switch response {
        case .toolResults(_, let results):
            for result in results {
                switch result.result {
                case .movieDetail(let movie, let info):
                    ContentManager.shared.showMovieDetail(movie, info: info)
                case .movies(let movies):
                    let displayItems = movies.map { movie in
                        MovieDisplayItem(
                            id: movie.id,
                            title: movie.title,
                            overview: movie.overview,
                            posterURL: movie.posterURL,
                            trailerURL: movie.trailerURL,
                            releaseDate: movie.releaseDate,
                            rating: movie.rating
                        )
                    }
                    ContentManager.shared.showMovies(displayItems)
                default:
                    break
                }
            }
        case .text(let text):
            ContentManager.shared.showMovieDetail(movie, info: text)
        case .error(let error):
            print("Error: \(error)")
        }
    }
}

// MARK: - Rich Text View

struct RichTextView: View {
    let title: String
    let content: String

    private var viewWidth: CGFloat { 500 }
    private var viewHeight: CGFloat { 350 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Button {
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                Text(content)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: viewWidth, height: viewHeight)
    }
}

// MARK: - Battery Status View

struct BatteryStatusView: View {
    let info: BatteryInfo
    @State private var chatText: String = ""
    @State private var isProcessing: Bool = false

    private var viewWidth: CGFloat { 380 }
    private var viewHeight: CGFloat { 280 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "battery.100")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)

                Text("Battery Status")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Button {
                    ContentManager.shared.resetChat()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Battery Cards
            ScrollView {
                VStack(spacing: 12) {
                    // Mac Battery
                    BatteryCard(
                        name: "MacBook",
                        percent: info.macPercent,
                        isCharging: info.macIsCharging,
                        icon: "laptopcomputer"
                    )

                    // Connected Devices
                    ForEach(info.devices) { device in
                        BatteryCard(
                            name: device.name,
                            percent: device.percent,
                            isCharging: false,
                            icon: device.icon
                        )
                    }

                    // Low battery warning
                    if info.macPercent < 20 || info.devices.contains(where: { $0.percent < 20 }) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Some devices need charging")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(16)
            }

            Divider()

            // Chat input
            ChatInputField(text: $chatText, isProcessing: $isProcessing)
        }
        .frame(width: viewWidth, height: viewHeight)
    }
}

struct BatteryCard: View {
    let name: String
    let percent: Int
    let isCharging: Bool
    let icon: String

    private var batteryColor: Color {
        if percent > 50 { return .green }
        if percent > 20 { return .yellow }
        return .red
    }

    var body: some View {
        HStack(spacing: 12) {
            // Device Icon
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))

                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                }

                // Battery Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))

                        RoundedRectangle(cornerRadius: 4)
                            .fill(batteryColor)
                            .frame(width: geo.size.width * CGFloat(percent) / 100)
                    }
                }
                .frame(height: 8)
            }

            Text("\(percent)%")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(batteryColor)
                .frame(width: 45, alignment: .trailing)
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Weather Status View

struct WeatherStatusView: View {
    let info: WeatherInfo
    @State private var chatText: String = ""
    @State private var isProcessing: Bool = false

    private var viewWidth: CGFloat { 360 }
    private var viewHeight: CGFloat { 320 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: info.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                Text(info.location)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Button {
                    ContentManager.shared.resetChat()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Weather Content
            VStack(spacing: 16) {
                // Main Temperature
                HStack(alignment: .top, spacing: 4) {
                    Text("\(info.temperature)")
                        .font(.system(size: 64, weight: .light, design: .rounded))

                    Text("°C")
                        .font(.system(size: 24, weight: .light))
                        .padding(.top, 8)
                }

                // Condition
                HStack {
                    Image(systemName: info.icon)
                        .font(.system(size: 20))
                    Text(info.condition.capitalized)
                        .font(.system(size: 16))
                }
                .foregroundStyle(.secondary)

                // Details
                HStack(spacing: 24) {
                    VStack {
                        Text("Feels like")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("\(info.feelsLike)°")
                            .font(.system(size: 15, weight: .medium))
                    }

                    VStack {
                        Text("Humidity")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("\(info.humidity)%")
                            .font(.system(size: 15, weight: .medium))
                    }
                }

                // Suggestions
                if !info.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(info.suggestions, id: \.self) { suggestion in
                            Text(suggestion)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(16)

            Spacer()

            Divider()

            // Chat input
            ChatInputField(text: $chatText, isProcessing: $isProcessing)
        }
        .frame(width: viewWidth, height: viewHeight)
    }
}

// MARK: - Trip Summary View

struct TripSummaryView: View {
    let info: TripInfo
    @State private var chatText: String = ""
    @State private var isProcessing: Bool = false

    // Larger size when showing route/map
    private var viewWidth: CGFloat { info.route != nil ? 480 : 420 }
    private var viewHeight: CGFloat { info.route != nil ? 600 : 450 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "car.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("Trip to \(info.destination)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer()

                Button {
                    ContentManager.shared.resetChat()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Route Map Section
                    if let route = info.route {
                        TripSectionCard(title: "Route", icon: "map.fill", iconColor: .orange) {
                            RouteMapView(route: route, destination: info.destination)
                        }
                    }

                    // Weather Section
                    if let weather = info.weather {
                        TripSectionCard(title: "Weather", icon: weather.icon, iconColor: .blue) {
                            HStack {
                                Text("\(weather.temperature)°C")
                                    .font(.system(size: 28, weight: .light, design: .rounded))

                                VStack(alignment: .leading) {
                                    Text(weather.condition.capitalized)
                                        .font(.system(size: 13))
                                    Text("Feels like \(weather.feelsLike)°")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Battery Section
                    TripSectionCard(title: "Battery", icon: "battery.100", iconColor: .green) {
                        VStack(alignment: .leading, spacing: 8) {
                            TripBatteryRow(name: "Mac", percent: info.battery.macPercent, icon: "laptopcomputer")

                            ForEach(info.battery.devices) { device in
                                TripBatteryRow(name: device.name, percent: device.percent, icon: device.icon)
                            }
                        }
                    }

                    // Calendar Section
                    if !info.events.isEmpty {
                        TripSectionCard(title: "Today's Events", icon: "calendar", iconColor: .red) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(info.events.prefix(3)) { event in
                                    HStack {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 6, height: 6)
                                        Text(event.title)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(formatTime(event.startDate, isAllDay: event.isAllDay))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    // Suggestions
                    if !info.suggestions.isEmpty {
                        TripSectionCard(title: "Suggestions", icon: "lightbulb.fill", iconColor: .yellow) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(info.suggestions, id: \.self) { suggestion in
                                    Text(suggestion)
                                        .font(.system(size: 12))
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Chat input
            ChatInputField(text: $chatText, isProcessing: $isProcessing)
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    private func formatTime(_ date: Date, isAllDay: Bool) -> String {
        if isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct TripSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct TripBatteryRow: View {
    let name: String
    let percent: Int
    let icon: String

    private var color: Color {
        if percent > 50 { return .green }
        if percent > 20 { return .yellow }
        return .red
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(name)
                .font(.system(size: 12))
            Spacer()
            Text("\(percent)%")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Route Map View

struct RouteMapView: View {
    let route: RouteInfo
    let destination: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Clickable Map with Route
            Button {
                openInMaps()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    RouteMapNSView(route: route, destination: destination)

                    // "Tap to open" hint
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app.fill")
                        Text("Tap to open in Maps")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(6)
                    .padding(8)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Route info bar
            if let distance = route.distance, let duration = route.duration {
                HStack(spacing: 0) {
                    // Distance
                    HStack(spacing: 6) {
                        Image(systemName: "road.lanes")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(formatDistance(distance))
                                .font(.system(size: 14, weight: .semibold))
                            Text("Distance")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()
                        .frame(height: 30)
                        .padding(.horizontal, 12)

                    // Duration
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(formatDuration(duration))
                                .font(.system(size: 14, weight: .semibold))
                            Text("Drive time")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.0f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }

    private func openInMaps() {
        let destPlacemark = MKPlacemark(coordinate: route.destinationCoordinate)
        let destItem = MKMapItem(placemark: destPlacemark)
        destItem.name = destination

        let options = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        MKMapItem.openMaps(with: [destItem], launchOptions: options)
    }
}

// MARK: - Photo Search Results View

struct PhotoSearchResultsView: View {
    let results: [PhotoSearchResult]
    let contactSheet: NSImage?
    @State private var chatText: String = ""
    @State private var isProcessing: Bool = false
    @State private var selectedResult: PhotoSearchResult?

    private var viewWidth: CGFloat { 450 }
    private var viewHeight: CGFloat { 500 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: results.first?.info.mediaType == "video" ? "film.stack" : "photo.stack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.purple)

                Text("Found \(results.count) \(results.first?.info.mediaType == "video" ? "video" : "photo")\(results.count == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                if let confidence = results.first?.confidence {
                    Text(confidence.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(confidenceColor(confidence).opacity(0.15))
                        .foregroundStyle(confidenceColor(confidence))
                        .clipShape(Capsule())
                }

                Button {
                    ContentManager.shared.resetChat()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // Contact sheet preview
                    if let sheet = contactSheet {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Search Overview")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            Image(nsImage: sheet)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    // Results grid
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(results, id: \.info.id) { result in
                            PhotoResultCard(result: result) {
                                selectedResult = result
                                openInPhotos(result)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            Divider()

            // Chat input for follow-up queries
            ChatInputField(text: $chatText, isProcessing: $isProcessing)
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    private func confidenceColor(_ confidence: String) -> Color {
        switch confidence.lowercased() {
        case "high": return .green
        case "medium": return .orange
        default: return .gray
        }
    }

    private func openInPhotos(_ result: PhotoSearchResult) {
        // Open the specific asset in Photos app using its local identifier
        let asset = result.asset
        
        // Try to get the PHAsset's URL and open it
        // First, try the photos-redirect URL scheme which opens the specific asset
        if let photosURL = URL(string: "photos-redirect://asset/\(asset.localIdentifier)") {
            if NSWorkspace.shared.open(photosURL) {
                return
            }
        }
        
        // Fallback: Open Photos and use AppleScript to navigate
        let escapedId = asset.localIdentifier.replacingOccurrences(of: "'", with: "\\'")
        let script = """
        tell application "Photos"
            activate
            delay 0.5
            set targetAsset to media item id "\(escapedId)"
            spotlight targetAsset
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error != nil {
                // Final fallback: just open Photos app
                NSWorkspace.shared.open(URL(string: "photos://")!)
            }
        }
    }
}

struct PhotoResultCard: View {
    let result: PhotoSearchResult
    let onTap: () -> Void
    @State private var thumbnail: NSImage?
    private let photosProvider = PhotosProvider()

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 110, height: 80)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 110, height: 80)
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.6)
                            )
                    }

                    // Video indicator
                    if result.info.mediaType == "video" {
                        VStack {
                            Spacer()
                            HStack {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8))
                                if let duration = result.info.duration {
                                    Text(duration)
                                        .font(.system(size: 9, weight: .medium))
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(4)
                        }
                        .frame(width: 110, height: 80, alignment: .bottomLeading)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Date if available
                if let date = result.info.creationDate {
                    Text(date)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .task {
            // Try indexed thumbnail first (high-res 800x600, already cached)
            if result.info.mediaType == "video" {
                let indexService = await VideoIndexService.shared
                if let entry = await indexService.getIndexEntry(for: result.asset),
                   let firstThumb = entry.visual.thumbnails.first,
                   let cachedThumb = await indexService.getThumbnailImage(filename: firstThumb) {
                    thumbnail = cachedThumb
                    return
                }
            }
            // Fallback: generate HIGH QUALITY thumbnail (not fast/degraded)
            thumbnail = await photosProvider.generateThumbnail(
                for: result.asset, 
                size: CGSize(width: 440, height: 320),  // 4x display size for retina
                highQuality: true
            )
        }
    }
}

// MARK: - MKMapView Wrapper with Route Polyline

struct RouteMapNSView: NSViewRepresentable {
    let route: RouteInfo
    let destination: String

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.isZoomEnabled = false
        mapView.isScrollEnabled = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        // Remove existing overlays and annotations
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        // Add destination annotation
        let destAnnotation = RouteAnnotation(
            coordinate: route.destinationCoordinate,
            title: destination,
            isDestination: true
        )
        mapView.addAnnotation(destAnnotation)

        // Add source annotation if available
        if let sourceCoord = route.sourceCoordinate {
            let sourceAnnotation = RouteAnnotation(
                coordinate: sourceCoord,
                title: "Current Location",
                isDestination: false
            )
            mapView.addAnnotation(sourceAnnotation)
        }

        // Add route polyline if available
        if let polyline = route.routePolyline {
            mapView.addOverlay(polyline)
            // Fit map to show the route with padding
            let rect = polyline.boundingMapRect
            let padding = NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
            mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        } else {
            // No route - just show both points
            var coords: [CLLocationCoordinate2D] = [route.destinationCoordinate]
            if let source = route.sourceCoordinate {
                coords.append(source)
            }

            if coords.count > 1 {
                let minLat = coords.map { $0.latitude }.min()!
                let maxLat = coords.map { $0.latitude }.max()!
                let minLon = coords.map { $0.longitude }.min()!
                let maxLon = coords.map { $0.longitude }.max()!

                let center = CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLon + maxLon) / 2
                )
                let span = MKCoordinateSpan(
                    latitudeDelta: (maxLat - minLat) * 1.5 + 0.1,
                    longitudeDelta: (maxLon - minLon) * 1.5 + 0.1
                )
                mapView.setRegion(MKCoordinateRegion(center: center, span: span), animated: false)
            } else {
                let region = MKCoordinateRegion(
                    center: route.destinationCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
                )
                mapView.setRegion(region, animated: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = NSColor.systemBlue
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let routeAnnotation = annotation as? RouteAnnotation else { return nil }

            let identifier = routeAnnotation.isDestination ? "destination" : "source"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)

            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = true
            } else {
                annotationView?.annotation = annotation
            }

            // Create custom pin image
            let size = CGSize(width: 30, height: 40)
            let image = NSImage(size: size, flipped: false) { rect in
                let color: NSColor = routeAnnotation.isDestination ? .systemRed : .systemBlue
                color.setFill()

                // Draw pin shape
                let pinPath = NSBezierPath()
                let centerX = rect.midX
                let circleRadius: CGFloat = 12
                let circleCenter = CGPoint(x: centerX, y: rect.maxY - circleRadius - 2)

                // Circle
                pinPath.appendArc(withCenter: circleCenter, radius: circleRadius, startAngle: 0, endAngle: 360)
                pinPath.fill()

                // Point
                let pointPath = NSBezierPath()
                pointPath.move(to: CGPoint(x: centerX - 8, y: circleCenter.y - 8))
                pointPath.line(to: CGPoint(x: centerX, y: 2))
                pointPath.line(to: CGPoint(x: centerX + 8, y: circleCenter.y - 8))
                pointPath.close()
                pointPath.fill()

                // White dot in center
                NSColor.white.setFill()
                let dotPath = NSBezierPath(ovalIn: CGRect(x: centerX - 4, y: circleCenter.y - 4, width: 8, height: 8))
                dotPath.fill()

                return true
            }

            annotationView?.image = image
            annotationView?.centerOffset = CGPoint(x: 0, y: -20)

            return annotationView
        }
    }
}

class RouteAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let isDestination: Bool

    init(coordinate: CLLocationCoordinate2D, title: String, isDestination: Bool) {
        self.coordinate = coordinate
        self.title = title
        self.isDestination = isDestination
        super.init()
    }
}

struct MapAnnotationItem: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let isDestination: Bool
}

// MARK: - Reusable Chat Input Field

struct ChatInputField: View {
    @Binding var text: String
    @Binding var isProcessing: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("Ask something...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    sendMessage()
                }

            if isProcessing {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(text.isEmpty ? .gray : .orange)
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sendMessage() {
        guard !text.isEmpty else { return }
        let query = text
        text = ""
        isProcessing = true

        Task {
            let response = await AIService.shared.query(query)
            await MainActor.run {
                isProcessing = false
                // Handle response - add to chat
                ContentManager.shared.chatMessages.append(ChatMessage(role: .user, content: query))
                switch response {
                case .text(let responseText):
                    ContentManager.shared.chatMessages.append(ChatMessage(role: .assistant, content: responseText))
                default:
                    break
                }
            }
        }
    }
}

// MARK: - Calendar List View

struct CalendarListView: View {
    let events: [CalendarDisplayItem]

    private var viewWidth: CGFloat { 400 }
    private var viewHeight: CGFloat { 350 }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.red)

                Text("Calendar")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Text("\(events.count) events")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button {
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Events List
            if events.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No events")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(events) { event in
                            CalendarEventRow(
                                event: event,
                                timeFormatter: timeFormatter,
                                dateFormatter: dateFormatter
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: viewWidth, height: viewHeight)
    }
}

struct CalendarEventRow: View {
    let event: CalendarDisplayItem
    let timeFormatter: DateFormatter
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(spacing: 12) {
            // Time indicator
            VStack(alignment: .trailing, spacing: 2) {
                if event.isAllDay {
                    Text("All Day")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(timeFormatter.string(from: event.startDate))
                        .font(.system(size: 12, weight: .semibold))
                    Text(timeFormatter.string(from: event.endDate))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 60)

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue)
                .frame(width: 4)

            // Event details
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 9))
                        Text(location)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Reminders List View

struct RemindersListView: View {
    let reminders: [ReminderDisplayItem]

    private var viewWidth: CGFloat { 400 }
    private var viewHeight: CGFloat { 380 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checklist")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Reminders")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Text("\(reminders.count) items")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button {
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Reminders List
            if reminders.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No reminders")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(reminders) { reminder in
                            ReminderRow(reminder: reminder)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: viewWidth, height: viewHeight)
    }
}

struct ReminderRow: View {
    let reminder: ReminderDisplayItem

    var priorityColor: Color {
        switch reminder.priority {
        case "High": return .red
        case "Medium": return .orange
        case "Low": return .blue
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox indicator
            Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(reminder.isCompleted ? .green : .secondary)

            // Reminder details
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(reminder.isCompleted, color: .secondary)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    // List name
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 9))
                        Text(reminder.listName)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)

                    // Due date
                    if let dueDate = reminder.dueDate {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                            Text(dueDate)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                    }

                    // Priority
                    if !reminder.priority.isEmpty {
                        Text(reminder.priority)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(priorityColor.opacity(0.15))
                            .foregroundStyle(priorityColor)
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Contacts List View

struct ContactsListView: View {
    let contacts: [ContactDisplayItem]

    private var viewWidth: CGFloat { 400 }
    private var viewHeight: CGFloat { 400 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("Contacts")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Text("\(contacts.count) found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button {
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if contacts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No contacts found")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(contacts) { contact in
                            ContactRow(contact: contact)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: viewWidth, height: viewHeight)
    }
}

struct ContactRow: View {
    let contact: ContactDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name and organization
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.system(size: 14, weight: .semibold))

                    if let org = contact.organization {
                        Text(org)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if contact.nickname != nil || contact.jobTitle != nil {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let nick = contact.nickname {
                            Text("\"\(nick)\"")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                        if let job = contact.jobTitle {
                            Text(job)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Phone numbers
            if !contact.phones.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text(contact.phones.joined(separator: " • "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Emails
            if !contact.emails.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text(contact.emails.joined(separator: " • "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Address
            if let address = contact.address {
                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(address)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Birthday
            if let birthday = contact.birthday {
                HStack(spacing: 4) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                    Text(birthday)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - System Info View

struct SystemInfoView: View {
    let info: SystemDisplayInfo

    private var viewWidth: CGFloat { 360 }
    private var viewHeight: CGFloat { 320 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cpu")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.cyan)

                Text("System Status")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Button {
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Stats Grid
            VStack(spacing: 16) {
                // CPU Usage
                SystemStatRow(
                    icon: "cpu",
                    iconColor: .cyan,
                    label: "CPU",
                    value: "\(info.cpuUsage)%",
                    progress: Double(info.cpuUsage) / 100,
                    progressColor: cpuColor(info.cpuUsage)
                )

                // Memory Usage
                SystemStatRow(
                    icon: "memorychip",
                    iconColor: .purple,
                    label: "Memory",
                    value: String(format: "%.1f / %.1f GB", info.usedMemoryGB, info.totalMemoryGB),
                    progress: Double(info.memoryUsagePercent) / 100,
                    progressColor: memoryColor(info.memoryUsagePercent)
                )

                // Disk Usage
                SystemStatRow(
                    icon: "internaldrive",
                    iconColor: .orange,
                    label: "Storage",
                    value: String(format: "%.0f GB free of %.0f GB", info.freeDiskGB, info.totalDiskGB),
                    progress: Double(info.diskUsagePercent) / 100,
                    progressColor: diskColor(info.diskUsagePercent)
                )

                // Uptime
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                        .frame(width: 24)

                    Text("Uptime")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(info.uptime)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                }
            }
            .padding(16)

            Spacer()
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    private func cpuColor(_ usage: Int) -> Color {
        if usage > 80 { return .red }
        if usage > 50 { return .orange }
        return .green
    }

    private func memoryColor(_ usage: Int) -> Color {
        if usage > 85 { return .red }
        if usage > 60 { return .orange }
        return .purple
    }

    private func diskColor(_ usage: Int) -> Color {
        if usage > 90 { return .red }
        if usage > 75 { return .orange }
        return .blue
    }
}

struct SystemStatRow: View {
    let icon: String
    let iconColor: Color
    let label: String
    let value: String
    let progress: Double
    let progressColor: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(value)
                    .font(.system(size: 13, weight: .medium))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(progressColor)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Place List View

struct PlaceListView: View {
    let places: [PlaceDisplayItem]
    let mapSnapshot: NSImage?
    @State private var followUpText = ""
    @FocusState private var isInputFocused: Bool

    private var viewWidth: CGFloat { 440 }
    private var viewHeight: CGFloat { 520 }  // Taller to fit bigger map

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Places")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Spacer()

                Text("\(places.count) found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button {
                    ContentManager.shared.showChat()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if places.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No places found")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        // Map snapshot at top if available - clickable to open Maps
                        if let snapshot = mapSnapshot {
                            Image(nsImage: snapshot)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .frame(height: 180)  // Bigger map
                                .clipShape(RoundedRectangle(cornerRadius: 16))  // macOS style
                                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .onTapGesture {
                                    // Open first place in Maps with directions
                                    if let first = places.first {
                                        let coord = first.coordinate
                                        // Use saddr=Current+Location for directions mode
                                        if let url = URL(string: "maps://?daddr=\(coord.latitude),\(coord.longitude)&dirflg=d") {
                                            NSWorkspace.shared.open(url)
                                            NotificationCenter.default.post(name: .hideNotch, object: nil)
                                        }
                                    }
                                }
                                .help("Click to get directions")
                        }

                        // Places list
                        LazyVStack(spacing: 6) {
                            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                                PlaceRow(place: place, index: index + 1)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }
            }

            // Chat input for follow-up questions
            Divider()

            HStack(spacing: 8) {
                TextField("Ask about these places...", text: $followUpText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isInputFocused)
                    .onSubmit {
                        sendFollowUp()
                    }

                Button {
                    sendFollowUp()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(followUpText.isEmpty ? .gray : .blue)
                }
                .buttonStyle(.plain)
                .disabled(followUpText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.gray.opacity(0.05))
        }
        .frame(width: viewWidth, height: viewHeight)
    }

    private func sendFollowUp() {
        guard !followUpText.isEmpty else { return }
        let message = followUpText
        followUpText = ""

        // Switch to chat view and send the message
        Task { @MainActor in
            ContentManager.shared.showChat()
            // Small delay to ensure chat is visible
            try? await Task.sleep(nanoseconds: 100_000_000)
            NotificationCenter.default.post(
                name: NSNotification.Name("SendChatMessage"),
                object: nil,
                userInfo: ["message": message]
            )
        }
    }
}

struct PlaceRow: View {
    let place: PlaceDisplayItem
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            // Index number in circle
            ZStack {
                Circle()
                    .fill(index == 1 ? Color.red : Color.blue)
                    .frame(width: 24, height: 24)

                Text("\(index)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(place.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let distance = place.distanceText {
                        Text("• \(distance)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    Text(place.category)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.8))
                        .clipShape(Capsule())

                    Text(place.address)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                if let phone = place.phoneNumber {
                    Button {
                        if let url = URL(string: "tel:\(phone)") {
                            NSWorkspace.shared.open(url)
                            NotificationCenter.default.post(name: .hideNotch, object: nil)
                        }
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                }

                // Open in Maps button
                Button {
                    let coordinate = place.coordinate
                    if let url = URL(string: "maps://?q=\(place.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&ll=\(coordinate.latitude),\(coordinate.longitude)") {
                        NSWorkspace.shared.open(url)
                        NotificationCenter.default.post(name: .hideNotch, object: nil)
                    }
                } label: {
                    Image(systemName: "map.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Loading View

struct LoadingView: View {
    let message: String

    private var viewWidth: CGFloat { 300 }
    private var viewHeight: CGFloat { 150 }

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(width: viewWidth, height: viewHeight)
    }
}

// MARK: - Indexing Progress View

struct IndexingProgressView: View {
    let progress: IndexingProgress

    private var viewWidth: CGFloat { 280 }
    private var viewHeight: CGFloat { 50 }

    var body: some View {
        HStack(spacing: 12) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progress.progressPercent, height: 8)
                        .animation(.easeInOut(duration: 0.3), value: progress.progressPercent)
                }
            }
            .frame(height: 8)

            // Count
            Text("\(progress.current)/\(progress.total)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            // Cancel button
            Button(action: {
                VideoIndexService.shared.cancelIndexing()
                ContentManager.shared.showChat()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: viewWidth, height: viewHeight)
    }
}
