import Foundation
import IOKit.ps

/// Sandbox-compliant battery monitoring using IOKit Power Sources
@MainActor
class BatteryService {
    static let shared = BatteryService()

    private init() {}

    // MARK: - Mac Battery

    func getMacBattery() -> (percent: Int, isCharging: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return (100, false) // Default for desktop Macs without battery
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            // Check if this is the internal battery
            guard let type = info[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else {
                continue
            }

            let percent = info[kIOPSCurrentCapacityKey] as? Int ?? 100
            let isCharging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            let powerSource = info[kIOPSPowerSourceStateKey] as? String ?? ""

            // "AC Power" means plugged in, "Battery Power" means on battery
            let isPluggedIn = powerSource == kIOPSACPowerValue

            return (percent, isCharging || isPluggedIn)
        }

        return (100, false)
    }

    // MARK: - Connected Devices (Bluetooth)

    /// Get battery levels for connected Bluetooth devices
    /// Note: This uses IOBluetooth which has limited sandbox support
    /// For full functionality, may need to request Bluetooth entitlement
    func getConnectedDevicesBattery() -> [DeviceBatteryInfo] {
        var devices: [DeviceBatteryInfo] = []

        // Use IORegistry to find Bluetooth HID devices with battery info
        let matchingDict = IOServiceMatching("AppleDeviceManagementHIDEventService")
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return devices
        }

        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            // Get device properties
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = properties?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            // Extract battery info if available
            if let product = props["Product"] as? String,
               let battery = props["BatteryPercent"] as? Int {
                let icon = iconForDevice(product)
                devices.append(DeviceBatteryInfo(name: product, percent: battery, icon: icon))
            }
        }

        return devices
    }

    // MARK: - Full Battery Info

    func getBatteryInfo() -> BatteryInfo {
        let mac = getMacBattery()
        let devices = getConnectedDevicesBattery().map { device in
            BatteryInfo.DeviceBattery(
                name: device.name,
                percent: device.percent,
                icon: device.icon
            )
        }

        return BatteryInfo(
            macPercent: mac.percent,
            macIsCharging: mac.isCharging,
            devices: devices
        )
    }

    // MARK: - Helpers

    private func iconForDevice(_ name: String) -> String {
        let lowerName = name.lowercased()

        if lowerName.contains("iphone") { return "iphone" }
        if lowerName.contains("ipad") { return "ipad" }
        if lowerName.contains("airpods pro") { return "airpodspro" }
        if lowerName.contains("airpods") { return "airpods" }
        if lowerName.contains("watch") { return "applewatch" }
        if lowerName.contains("magic mouse") { return "magicmouse" }
        if lowerName.contains("magic trackpad") || lowerName.contains("trackpad") { return "trackpad" }
        if lowerName.contains("keyboard") { return "keyboard" }
        if lowerName.contains("mouse") { return "computermouse" }

        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - Device Battery Info

struct DeviceBatteryInfo: Identifiable {
    let id = UUID()
    let name: String
    let percent: Int
    let icon: String
}
