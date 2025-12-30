import Foundation
import CoreLocation
import Combine

// MARK: - Location Manager

@MainActor
class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isAuthorized: Bool = false

    private let manager = CLLocationManager()
    private var continuations: [CheckedContinuation<CLLocation?, Never>] = []

    private static func log(_ message: String) {
        let logPath = "/tmp/dynamicai.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        updateAuthorizationStatus()
    }

    private func updateAuthorizationStatus() {
        authorizationStatus = manager.authorizationStatus
        isAuthorized = authorizationStatus == .authorizedAlways || authorizationStatus == .authorized
        Self.log("📍 Location authorization: \(authorizationStatus.rawValue), isAuthorized: \(isAuthorized)")
    }

    func requestPermission() {
        Self.log("📍 Requesting location permission...")
        manager.requestWhenInUseAuthorization()
    }

    func getCurrentLocation() async -> CLLocation? {
        Self.log("📍 Getting current location...")

        // Check authorization first
        if !isAuthorized {
            requestPermission()
            // Wait a moment for permission dialog
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !isAuthorized {
                Self.log("⚠️ Location not authorized")
                return nil
            }
        }

        // If we have a recent location (< 5 min old), use it
        if let location = currentLocation,
           Date().timeIntervalSince(location.timestamp) < 300 {
            Self.log("📍 Using cached location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            return location
        }

        // Request a fresh location
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
            self.manager.requestLocation()
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            Self.log("📍 Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            self.currentLocation = location

            // Resume all waiting continuations
            for continuation in self.continuations {
                continuation.resume(returning: location)
            }
            self.continuations.removeAll()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            Self.log("❌ Location error: \(error.localizedDescription)")

            // Resume all waiting continuations with nil
            for continuation in self.continuations {
                continuation.resume(returning: nil)
            }
            self.continuations.removeAll()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updateAuthorizationStatus()
        }
    }
}
