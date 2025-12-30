import AppKit
import SwiftUI

/// Floating panel window for Macs without a notch.
/// Mimics the notch behavior by appearing at the top-center of the screen.
class FloatingPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        // Panel configuration
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.animationBehavior = .utilityWindow

        // Set content view with visual effect background
        let visualEffect = NSVisualEffectView(frame: contentView.bounds)
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true

        // Add the SwiftUI content on top
        contentView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])

        self.contentView = visualEffect
    }

    /// Shows the panel at the top-center of the screen with animation
    func show() {
        guard let screen = NSScreen.main else { return }

        // Position at top-center of screen
        let screenFrame = screen.visibleFrame
        let panelWidth = frame.width
        let x = screenFrame.midX - (panelWidth / 2)
        let y = screenFrame.maxY - frame.height - 20 // 20px from top

        setFrameOrigin(NSPoint(x: x, y: y))

        // Animate in
        alphaValue = 0
        makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Hides the panel with animation
    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// Updates the panel size based on content
    func updateSize(to size: NSSize) {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - (size.width / 2)
        let y = screenFrame.maxY - size.height - 20

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(
                NSRect(x: x, y: y, width: size.width, height: size.height),
                display: true
            )
        }
    }

    // MARK: - Panel Behavior Overrides

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Allow keyboard events to be captured
    override func resignKey() {
        // Don't resign key status when clicking outside
        // The click-outside monitor will handle hiding
    }
}
