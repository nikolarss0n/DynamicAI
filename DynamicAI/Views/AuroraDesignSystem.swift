// MARK: - Aurora Design System
// A liquid, depth-driven design language with aurora gradients and organic motion
// For DynamicAI macOS notch app

import SwiftUI

// MARK: - Aurora Color Palette

extension Color {
    static let aurora = AuroraColors()

    struct AuroraColors {
        // Primary aurora gradient stops
        let cyan = Color(hex: "00D4FF")
        let blue = Color(hex: "5B8DEE")
        let purple = Color(hex: "A855F7")
        let pink = Color(hex: "EC4899")
        let magenta = Color(hex: "F472B6")

        // Frosted glass backgrounds
        let glass = Color.white.opacity(0.08)
        let glassLight = Color.white.opacity(0.12)
        let glassDark = Color.black.opacity(0.3)

        // Accent colors
        let success = Color(hex: "10B981")
        let warning = Color(hex: "F59E0B")
        let error = Color(hex: "EF4444")

        // Text hierarchy
        let textPrimary = Color.white
        let textSecondary = Color.white.opacity(0.7)
        let textTertiary = Color.white.opacity(0.45)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Aurora Gradients

struct AuroraGradient {
    static let primary = LinearGradient(
        colors: [Color.aurora.cyan, Color.aurora.purple, Color.aurora.pink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let subtle = LinearGradient(
        colors: [Color.aurora.cyan.opacity(0.6), Color.aurora.purple.opacity(0.6)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let mesh = MeshGradient(
        width: 3, height: 3,
        points: [
            [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
            [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
            [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
        ],
        colors: [
            Color.aurora.cyan.opacity(0.3), Color.aurora.blue.opacity(0.2), Color.aurora.purple.opacity(0.3),
            Color.aurora.blue.opacity(0.2), Color.aurora.purple.opacity(0.25), Color.aurora.pink.opacity(0.2),
            Color.aurora.purple.opacity(0.3), Color.aurora.pink.opacity(0.2), Color.aurora.magenta.opacity(0.3)
        ]
    )

    static func radial(from color: Color) -> RadialGradient {
        RadialGradient(
            colors: [color.opacity(0.4), color.opacity(0)],
            center: .center,
            startRadius: 0,
            endRadius: 100
        )
    }
}

// MARK: - Frosted Glass Card

struct AuroraCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 16
    var glowColor: Color? = nil
    var isActive: Bool = false

    init(
        padding: CGFloat = 16,
        cornerRadius: CGFloat = 16,
        glowColor: Color? = nil,
        isActive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.glowColor = glowColor
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background {
                ZStack {
                    // Base glass layer
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)

                    // Inner glow when active
                    if isActive, let glow = glowColor {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(glow.opacity(0.1))
                    }

                    // Subtle border
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isActive ? 0.3 : 0.15),
                                    Color.white.opacity(isActive ? 0.15 : 0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            }
            .shadow(color: (glowColor ?? .clear).opacity(isActive ? 0.2 : 0), radius: 16, y: 4)
            .shadow(color: Color.black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Aurora Progress Ring

struct AuroraProgressRing: View {
    let progress: Double
    var size: CGFloat = 44
    var lineWidth: CGFloat = 4
    var showPulse: Bool = true

    @State private var isPulsing = false
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // Pulse glow
            if showPulse && progress < 1.0 {
                Circle()
                    .fill(Color.aurora.purple.opacity(0.2))
                    .frame(width: size + 16, height: size + 16)
                    .scaleEffect(isPulsing ? 1.15 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.6)
            }

            // Track
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
                .frame(width: size, height: size)

            // Progress arc with aurora gradient
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [Color.aurora.cyan, Color.aurora.purple, Color.aurora.pink, Color.aurora.cyan],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90 + rotation))

            // Center content
            if progress >= 1.0 {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.35, weight: .bold))
                    .foregroundStyle(Color.aurora.success)
            } else {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: size * 0.28, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.aurora.textSecondary)
            }
        }
        .onAppear {
            if progress < 1.0 {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
                withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        }
        .onChange(of: progress) { _, newValue in
            if newValue >= 1.0 {
                isPulsing = false
            }
        }
    }
}

// MARK: - Aurora Progress Bar

struct AuroraProgressBar: View {
    let progress: Double
    var height: CGFloat = 6
    var showGlow: Bool = true

    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.white.opacity(0.1))

                // Progress fill
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(AuroraGradient.primary)
                    .frame(width: geo.size.width * progress)
                    .overlay {
                        // Shimmer effect
                        RoundedRectangle(cornerRadius: height / 2)
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Color.white.opacity(0.4), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .offset(x: geo.size.width * shimmerOffset)
                            .mask(
                                RoundedRectangle(cornerRadius: height / 2)
                            )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))

                // Glow effect at progress head
                if showGlow && progress > 0 && progress < 1 {
                    Circle()
                        .fill(Color.aurora.pink)
                        .frame(width: height * 2, height: height * 2)
                        .blur(radius: 4)
                        .offset(x: geo.size.width * progress - height)
                }
            }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                shimmerOffset = 2
            }
        }
    }
}

// MARK: - Aurora Badge

struct AuroraBadge: View {
    let text: String
    var color: Color = Color.aurora.purple
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.2))
        .foregroundStyle(color)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Aurora Stat Display

struct AuroraStat: View {
    let value: String
    let label: String
    var icon: String? = nil
    var gradient: LinearGradient = AuroraGradient.primary

    var body: some View {
        VStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(gradient)
            }

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(gradient)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.aurora.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }
}

// MARK: - Aurora Animated Background

struct AuroraBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            // Base dark
            Color.black.opacity(0.95)

            // Aurora blobs
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(blobColor(for: i))
                    .frame(width: 200, height: 200)
                    .blur(radius: 80)
                    .offset(
                        x: animate ? blobOffset(for: i).x : -blobOffset(for: i).x,
                        y: animate ? blobOffset(for: i).y : -blobOffset(for: i).y
                    )
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }

    private func blobColor(for index: Int) -> Color {
        switch index {
        case 0: return Color.aurora.cyan.opacity(0.3)
        case 1: return Color.aurora.purple.opacity(0.25)
        default: return Color.aurora.pink.opacity(0.2)
        }
    }

    private func blobOffset(for index: Int) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: 50, y: -30)
        case 1: return CGPoint(x: -40, y: 40)
        default: return CGPoint(x: 30, y: 50)
        }
    }
}

// MARK: - Aurora Icon Button

struct AuroraIconButton: View {
    let icon: String
    let action: () -> Void
    var size: CGFloat = 32
    var isDestructive: Bool = false

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isPressed ? 0.15 : 0.08))

                Circle()
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)

                Image(systemName: icon)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(isDestructive ? Color.aurora.error : Color.aurora.textSecondary)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.92 : 1.0)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Thumbnail Placeholder

struct ThumbnailPlaceholder: View {
    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .overlay {
                GeometryReader { geo in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(0.08), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: geo.size.width * shimmerPhase)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1.4
                }
            }
    }
}

// MARK: - Spring Animations

extension Animation {
    static let auroraSpring = Animation.spring(response: 0.4, dampingFraction: 0.75)
    static let auroraBounce = Animation.spring(response: 0.35, dampingFraction: 0.65)
    static let auroraSmooth = Animation.easeInOut(duration: 0.3)
}

// MARK: - View Extensions

extension View {
    func auroraGlow(color: Color = Color.aurora.purple, radius: CGFloat = 12) -> some View {
        self.shadow(color: color.opacity(0.4), radius: radius, y: 0)
    }

    func auroraBorder(isActive: Bool = false) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isActive ? AuroraGradient.primary : LinearGradient(colors: [Color.white.opacity(0.15)], startPoint: .top, endPoint: .bottom),
                    lineWidth: isActive ? 1.5 : 0.5
                )
        )
    }
}
