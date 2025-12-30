import AppKit
import Foundation
import UserNotifications
import IOKit.ps

// MARK: - System Provider

@MainActor
class SystemProvider {
    static let shared = SystemProvider()
    private init() {}

    // MARK: - App Launcher

    func launchApp(name: String) -> ToolExecutionResult {
        let workspace = NSWorkspace.shared

        // Try exact match first
        if let url = workspace.urlForApplication(withBundleIdentifier: name) {
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return .text("Launched \(name)")
        }

        // Try by name
        let appPaths = [
            "/Applications/\(name).app",
            "/Applications/\(name.replacingOccurrences(of: " ", with: "")).app",
            "/System/Applications/\(name).app",
            "/System/Applications/Utilities/\(name).app",
            "~/Applications/\(name).app"
        ]

        for path in appPaths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            if FileManager.default.fileExists(atPath: expandedPath) {
                workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return .text("Launched \(name)")
            }
        }

        // Try Spotlight search for app
        let task = Process()
        task.launchPath = "/usr/bin/mdfind"
        task.arguments = ["kMDItemKind == 'Application' && kMDItemDisplayName == '\(name)'cd"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               let firstPath = output.components(separatedBy: "\n").first,
               !firstPath.isEmpty {
                let url = URL(fileURLWithPath: firstPath)
                workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return .text("Launched \(name)")
            }
        } catch {}

        return .error("Could not find app '\(name)'")
    }

    func listRunningApps() -> ToolExecutionResult {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()

        return .text("Running apps: \(apps.joined(separator: ", "))")
    }

    // MARK: - System Info

    func getSystemInfo() -> ToolExecutionResult {
        var info = SystemInfo()

        // CPU info
        var cpuUsage: Double = 0
        var hostInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &hostInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let userTicks = Double(hostInfo.cpu_ticks.0)
            let systemTicks = Double(hostInfo.cpu_ticks.1)
            let idleTicks = Double(hostInfo.cpu_ticks.2)
            let niceTicks = Double(hostInfo.cpu_ticks.3)
            let totalTicks = userTicks + systemTicks + idleTicks + niceTicks
            cpuUsage = ((userTicks + systemTicks + niceTicks) / totalTicks) * 100
        }
        info.cpuUsage = Int(cpuUsage)

        // Memory info
        var vmStats = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let vmResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }

        if vmResult == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let totalMemory = ProcessInfo.processInfo.physicalMemory
            let freeMemory = UInt64(vmStats.free_count) * pageSize
            let usedMemory = totalMemory - freeMemory

            info.totalMemoryGB = Double(totalMemory) / 1_073_741_824
            info.usedMemoryGB = Double(usedMemory) / 1_073_741_824
            info.memoryUsagePercent = Int((Double(usedMemory) / Double(totalMemory)) * 100)
        }

        // Disk info
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            if let totalSize = attrs[.systemSize] as? UInt64,
               let freeSize = attrs[.systemFreeSize] as? UInt64 {
                info.totalDiskGB = Double(totalSize) / 1_073_741_824
                info.freeDiskGB = Double(freeSize) / 1_073_741_824
                info.diskUsagePercent = Int(((Double(totalSize) - Double(freeSize)) / Double(totalSize)) * 100)
            }
        }

        // Uptime
        let uptime = ProcessInfo.processInfo.systemUptime
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        info.uptime = "\(hours)h \(minutes)m"

        return .systemInfo(info)
    }

    // MARK: - Timer

    func setTimer(minutes: Int, label: String?) async -> ToolExecutionResult {
        let center = UNUserNotificationCenter.current()

        // Request permission
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            if !granted {
                return .error("Notification permission denied")
            }
        } catch {
            return .error("Failed to request notification permission")
        }

        let content = UNMutableNotificationContent()
        content.title = "Timer Complete"
        content.body = label ?? "Your \(minutes) minute timer is done!"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes * 60),
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "timer-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            return .text("Timer set for \(minutes) minute\(minutes == 1 ? "" : "s")\(label != nil ? " (\(label!))" : "")")
        } catch {
            return .error("Failed to set timer: \(error.localizedDescription)")
        }
    }

    // MARK: - Clipboard

    func getClipboard() -> ToolExecutionResult {
        let pasteboard = NSPasteboard.general

        if let string = pasteboard.string(forType: .string) {
            let truncated = string.count > 500 ? String(string.prefix(500)) + "..." : string
            return .text("Clipboard contents:\n\(truncated)")
        }

        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil {
            return .text("Clipboard contains an image")
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return .text("Clipboard contains: \(urls.map { $0.lastPathComponent }.joined(separator: ", "))")
        }

        return .text("Clipboard is empty")
    }

    func setClipboard(text: String) -> ToolExecutionResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return .text("Copied to clipboard")
    }

    // MARK: - Dark Mode

    func getDarkMode() -> ToolExecutionResult {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return .text("Dark mode is \(isDark ? "ON" : "OFF")")
    }

    func toggleDarkMode() -> ToolExecutionResult {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
            end tell
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return .text("Dark mode toggled \(isDark ? "OFF" : "ON")")
            }
        }

        return .error("Failed to toggle dark mode. Grant Automation permission in System Settings.")
    }

    func setDarkMode(enabled: Bool) -> ToolExecutionResult {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(enabled ? "true" : "false")
            end tell
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                return .text("Dark mode \(enabled ? "enabled" : "disabled")")
            }
        }

        return .error("Failed to set dark mode. Grant Automation permission in System Settings.")
    }

    // MARK: - Volume Control

    func getVolume() -> ToolExecutionResult {
        let script = "output volume of (get volume settings)"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: "return \(script)"),
           let result = appleScript.executeAndReturnError(&error).stringValue {
            return .text("Volume: \(result)%")
        }
        return .error("Failed to get volume")
    }

    func setVolume(level: Int) -> ToolExecutionResult {
        let clampedLevel = max(0, min(100, level))
        let script = "set volume output volume \(clampedLevel)"

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                return .text("Volume set to \(clampedLevel)%")
            }
        }
        return .error("Failed to set volume")
    }

    func toggleMute() -> ToolExecutionResult {
        let script = """
        set currentMute to output muted of (get volume settings)
        set volume output muted (not currentMute)
        return not currentMute
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script),
           let result = appleScript.executeAndReturnError(&error).stringValue {
            let isMuted = result == "true"
            return .text(isMuted ? "Muted" : "Unmuted")
        }
        return .error("Failed to toggle mute")
    }

    // MARK: - Brightness (requires accessibility)

    func getBrightness() -> ToolExecutionResult {
        let script = """
        tell application "System Events"
            tell process "ControlCenter"
                -- This is a simplified approach
            end tell
        end tell
        """
        // Brightness control is complex without private APIs
        return .text("Brightness control requires Display preferences. Use Fn+F1/F2 keys.")
    }

    // MARK: - Do Not Disturb / Focus

    func getDNDStatus() -> ToolExecutionResult {
        let script = """
        do shell script "defaults read com.apple.controlcenter 'NSStatusItem Visible FocusModes' 2>/dev/null || echo '0'"
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script),
           let result = appleScript.executeAndReturnError(&error).stringValue {
            return .text("Focus mode indicator: \(result == "1" ? "visible" : "hidden")")
        }

        return .text("Could not determine Focus status")
    }
}

// MARK: - System Info Model

struct SystemInfo {
    var cpuUsage: Int = 0
    var totalMemoryGB: Double = 0
    var usedMemoryGB: Double = 0
    var memoryUsagePercent: Int = 0
    var totalDiskGB: Double = 0
    var freeDiskGB: Double = 0
    var diskUsagePercent: Int = 0
    var uptime: String = ""
}
