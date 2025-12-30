import Foundation
import MapKit
import AppKit

// MARK: - Place Info Model

struct PlaceInfo: Identifiable {
    let id = UUID()
    let name: String
    let category: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    let phoneNumber: String?
    let url: URL?
    let mapSnapshotURL: URL?
    var rating: Double? // Would need external API for real ratings
    var priceLevel: Int? // $ to $$$$
    var distanceText: String? // e.g., "1.2 km" from search center
}

// MARK: - Place Provider

actor PlaceProvider {
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

    // MARK: - Search Places

    func searchPlaces(query: String, location: String?, category: PlaceCategory?, fromCurrentLocation: Bool = false) async -> PlaceSearchResult {
        Self.log("📍 PlaceProvider.search - query: '\(query)', location: '\(location ?? "none")', category: '\(category?.rawValue ?? "none")', fromCurrent: \(fromCurrentLocation)")

        // Build a clean search query - don't add category if already implied by query
        var searchQuery = query

        // Only add category if query doesn't already contain similar words
        if let category = category {
            let queryLower = query.lowercased()
            let categoryWord = category.rawValue.lowercased()
            if !queryLower.contains(categoryWord) && !queryLower.contains(categoryWord.dropLast()) {
                searchQuery = "\(category.rawValue) \(query)"
            }
        }

        Self.log("📍 Final search query: '\(searchQuery)'")

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery

        // Set result types - include both POI and addresses for better results
        request.resultTypes = [.pointOfInterest, .address]

        // Apply POI filter based on category
        if let category = category {
            request.pointOfInterestFilter = poiFilter(for: category)
        }

        // If we have a specific location, geocode it first to center the search
        var searchRegion: MKCoordinateRegion?
        if let location = location {
            searchRegion = await geocodeLocation(location)
            if let region = searchRegion {
                request.region = region
                Self.log("📍 Search region set: \(region.center.latitude), \(region.center.longitude)")
            } else {
                // Fallback: include location in query if geocoding fails
                searchQuery = "\(searchQuery) \(location)"
                request.naturalLanguageQuery = searchQuery
                Self.log("⚠️ Geocoding failed, using query: '\(searchQuery)'")
            }
        }

        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            Self.log("📍 Found \(response.mapItems.count) places")

            // Get reference point for distance calculation
            var referenceCoordinate: CLLocationCoordinate2D
            var useCurrentLocation = false

            if fromCurrentLocation {
                // Try to get current location (CLLocationManager -> IP fallback)
                if let currentLoc = await LocationManager.shared.getCurrentLocation() {
                    referenceCoordinate = currentLoc.coordinate
                    useCurrentLocation = true
                    Self.log("📍 Using GPS location: \(referenceCoordinate.latitude), \(referenceCoordinate.longitude)")
                } else if let ipLocation = await getIPBasedLocation() {
                    // Fallback to IP-based location
                    referenceCoordinate = ipLocation
                    useCurrentLocation = true
                    Self.log("📍 Using IP location: \(referenceCoordinate.latitude), \(referenceCoordinate.longitude)")
                } else {
                    // Last resort: use search center
                    referenceCoordinate = searchRegion?.center ?? response.boundingRegion.center
                    Self.log("⚠️ No location available, using search center")
                }
            } else {
                referenceCoordinate = searchRegion?.center ?? response.boundingRegion.center
            }

            var places: [PlaceInfo] = []
            for item in response.mapItems.prefix(5) {
                var place = await mapItemToPlaceInfo(item)

                if useCurrentLocation {
                    // Calculate travel time for current location
                    place.distanceText = await calculateTravelTime(from: referenceCoordinate, to: place.coordinate)
                } else {
                    place.distanceText = formatDistance(from: referenceCoordinate, to: place.coordinate)
                }
                places.append(place)
            }

            // Generate a map snapshot showing all places (with route if from current location)
            let mapSnapshot = await generateMapSnapshot(
                for: places,
                region: response.boundingRegion,
                fromLocation: useCurrentLocation ? referenceCoordinate : nil
            )

            return PlaceSearchResult(places: places, mapSnapshot: mapSnapshot)
        } catch let error as NSError {
            Self.log("❌ Place search error: \(error) (code: \(error.code))")

            // If first search fails, try a simpler query
            if error.domain == "MKErrorDomain" && error.code == 4 {
                Self.log("🔄 Retrying with simpler query...")
                return await retryWithSimpleSearch(query: query, location: location, region: searchRegion, fromCurrentLocation: fromCurrentLocation)
            }

            return PlaceSearchResult(places: [], mapSnapshot: nil, error: "No places found. Try a different search.")
        }
    }

    // MARK: - Retry with Simple Search

    private func retryWithSimpleSearch(query: String, location: String?, region: MKCoordinateRegion?, fromCurrentLocation: Bool = false) async -> PlaceSearchResult {
        // Try a very simple search - just the query with location appended
        var simpleQuery = query
        if let location = location {
            simpleQuery = "\(query) \(location)"
        }

        Self.log("📍 Simple retry query: '\(simpleQuery)'")

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = simpleQuery
        request.resultTypes = [.pointOfInterest, .address]

        if let region = region {
            request.region = region
        }

        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            Self.log("📍 Retry found \(response.mapItems.count) places")

            // Get reference coordinate
            var referenceCoordinate: CLLocationCoordinate2D
            var useCurrentLocation = false

            if fromCurrentLocation {
                if let currentLoc = await LocationManager.shared.getCurrentLocation() {
                    referenceCoordinate = currentLoc.coordinate
                    useCurrentLocation = true
                } else if let ipLocation = await getIPBasedLocation() {
                    referenceCoordinate = ipLocation
                    useCurrentLocation = true
                } else {
                    referenceCoordinate = region?.center ?? response.boundingRegion.center
                }
            } else {
                referenceCoordinate = region?.center ?? response.boundingRegion.center
            }

            var places: [PlaceInfo] = []
            for item in response.mapItems.prefix(5) {
                var place = await mapItemToPlaceInfo(item)
                if useCurrentLocation {
                    place.distanceText = await calculateTravelTime(from: referenceCoordinate, to: place.coordinate)
                } else {
                    place.distanceText = formatDistance(from: referenceCoordinate, to: place.coordinate)
                }
                places.append(place)
            }

            let mapSnapshot = await generateMapSnapshot(
                for: places,
                region: response.boundingRegion,
                fromLocation: useCurrentLocation ? referenceCoordinate : nil
            )
            return PlaceSearchResult(places: places, mapSnapshot: mapSnapshot)
        } catch {
            Self.log("❌ Retry also failed: \(error)")
            return PlaceSearchResult(places: [], mapSnapshot: nil, error: "No places found for '\(query)'. Try being more specific.")
        }
    }

    // MARK: - POI Filter for Category

    private func poiFilter(for category: PlaceCategory) -> MKPointOfInterestFilter {
        switch category {
        case .restaurant:
            return MKPointOfInterestFilter(including: [.restaurant, .bakery, .brewery, .winery, .foodMarket])
        case .cafe:
            return MKPointOfInterestFilter(including: [.cafe, .bakery])
        case .bar:
            return MKPointOfInterestFilter(including: [.nightlife, .brewery, .winery])
        case .hotel:
            return MKPointOfInterestFilter(including: [.hotel])
        case .attraction:
            return MKPointOfInterestFilter(including: [.museum, .theater, .amusementPark, .aquarium, .zoo, .beach, .park])
        case .museum:
            return MKPointOfInterestFilter(including: [.museum])
        case .park:
            return MKPointOfInterestFilter(including: [.park, .beach])
        case .shopping:
            return MKPointOfInterestFilter(including: [.store, .foodMarket])
        case .gym:
            return MKPointOfInterestFilter(including: [.fitnessCenter])
        }
    }

    // MARK: - Format Distance

    private func formatDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> String {
        let fromLocation = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let toLocation = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let distanceMeters = fromLocation.distance(from: toLocation)

        if distanceMeters < 1000 {
            return "\(Int(distanceMeters)) m"
        } else {
            let km = distanceMeters / 1000.0
            return String(format: "%.1f km", km)
        }
    }

    // MARK: - Calculate Travel Time

    private func calculateTravelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> String {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile

        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()

            if let route = response.routes.first {
                let minutes = Int(route.expectedTravelTime / 60)
                let distanceKm = route.distance / 1000.0

                if minutes < 60 {
                    return "\(minutes) min (\(String(format: "%.1f", distanceKm)) km)"
                } else {
                    let hours = minutes / 60
                    let remainingMins = minutes % 60
                    return "\(hours)h \(remainingMins)m (\(String(format: "%.1f", distanceKm)) km)"
                }
            }
        } catch {
            Self.log("⚠️ Travel time calculation failed: \(error)")
        }

        // Fallback to straight-line distance
        return formatDistance(from: from, to: to)
    }

    // MARK: - IP-Based Location Fallback

    private func getIPBasedLocation() async -> CLLocationCoordinate2D? {
        let apis = [
            "https://ipapi.co/json/",
            "https://ipwho.is/",
            "https://freeipapi.com/api/json"
        ]

        for apiURL in apis {
            guard let url = URL(string: apiURL) else { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let lat = json["latitude"] as? Double ?? json["lat"] as? Double
                    let lon = json["longitude"] as? Double ?? json["lon"] as? Double

                    if let lat = lat, let lon = lon {
                        Self.log("📍 IP location from \(apiURL): \(lat), \(lon)")
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                }
            } catch {
                continue
            }
        }

        return nil
    }

    // MARK: - Geocode Location

    private func geocodeLocation(_ location: String) async -> MKCoordinateRegion? {
        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.geocodeAddressString(location)
            if let placemark = placemarks.first, let clLocation = placemark.location {
                // Create a region around the location (roughly city-sized)
                return MKCoordinateRegion(
                    center: clLocation.coordinate,
                    latitudinalMeters: 10000,
                    longitudinalMeters: 10000
                )
            }
        } catch {
            Self.log("⚠️ Geocoding failed for '\(location)': \(error)")
        }

        return nil
    }

    // MARK: - Map Item to PlaceInfo

    private func mapItemToPlaceInfo(_ item: MKMapItem) async -> PlaceInfo {
        let placemark = item.placemark

        // Build address from components
        var addressParts: [String] = []
        if let street = placemark.thoroughfare {
            if let number = placemark.subThoroughfare {
                addressParts.append("\(number) \(street)")
            } else {
                addressParts.append(street)
            }
        }
        if let city = placemark.locality {
            addressParts.append(city)
        }
        if let country = placemark.country, placemark.locality != country {
            addressParts.append(country)
        }

        let address = addressParts.isEmpty ? "Address unavailable" : addressParts.joined(separator: ", ")

        // Get category from point of interest
        var category = "Place"
        if let poiCategory = item.pointOfInterestCategory {
            category = formatCategory(poiCategory)
        }

        return PlaceInfo(
            name: item.name ?? "Unknown Place",
            category: category,
            address: address,
            coordinate: placemark.coordinate,
            phoneNumber: item.phoneNumber,
            url: item.url,
            mapSnapshotURL: nil,
            rating: nil,
            priceLevel: nil
        )
    }

    // MARK: - Generate Map Snapshot

    private func generateMapSnapshot(for places: [PlaceInfo], region: MKCoordinateRegion, fromLocation: CLLocationCoordinate2D? = nil) async -> NSImage? {
        guard !places.isEmpty else { return nil }

        // Calculate route to first place if we have user's location
        var routePolyline: MKPolyline?
        if let userLocation = fromLocation, let firstPlace = places.first {
            routePolyline = await calculateRoutePolyline(from: userLocation, to: firstPlace.coordinate)
        }

        // Expand region to include user location and route
        var snapshotRegion = region
        if let userLocation = fromLocation {
            snapshotRegion = regionContaining(coordinates: [userLocation] + places.map { $0.coordinate })
        }

        let options = MKMapSnapshotter.Options()
        options.region = snapshotRegion
        options.size = CGSize(width: 800, height: 400)  // Bigger map
        options.mapType = .standard
        options.showsBuildings = true
        options.pointOfInterestFilter = .includingAll

        let snapshotter = MKMapSnapshotter(options: options)

        do {
            let snapshot = try await snapshotter.start()
            let image = snapshot.image
            let cornerRadius: CGFloat = 20  // macOS style rounded corners

            // Create rounded image
            let finalImage = NSImage(size: image.size)
            finalImage.lockFocus()

            // Clip to rounded rect
            let roundedPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: image.size), xRadius: cornerRadius, yRadius: cornerRadius)
            roundedPath.addClip()

            // Draw the map
            image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)

            // Draw route if available
            if let polyline = routePolyline {
                NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
                let routePath = NSBezierPath()
                routePath.lineWidth = 4
                routePath.lineCapStyle = .round
                routePath.lineJoinStyle = .round

                var isFirst = true
                for i in 0..<polyline.pointCount {
                    let mapPoint = polyline.points()[i]
                    let coord = mapPoint.coordinate
                    let point = snapshot.point(for: coord)
                    let flippedPoint = NSPoint(x: point.x, y: image.size.height - point.y)

                    if isFirst {
                        routePath.move(to: flippedPoint)
                        isFirst = false
                    } else {
                        routePath.line(to: flippedPoint)
                    }
                }
                routePath.stroke()
            }

            // Draw user location marker if available
            if let userLocation = fromLocation {
                let userPoint = snapshot.point(for: userLocation)
                let flippedUserPoint = NSPoint(x: userPoint.x, y: image.size.height - userPoint.y)

                // Outer circle (blue glow)
                NSColor.systemBlue.withAlphaComponent(0.3).setFill()
                let outerCircle = NSBezierPath(ovalIn: NSRect(x: flippedUserPoint.x - 16, y: flippedUserPoint.y - 16, width: 32, height: 32))
                outerCircle.fill()

                // Inner circle (solid blue)
                NSColor.systemBlue.setFill()
                NSColor.white.setStroke()
                let innerCircle = NSBezierPath(ovalIn: NSRect(x: flippedUserPoint.x - 8, y: flippedUserPoint.y - 8, width: 16, height: 16))
                innerCircle.lineWidth = 3
                innerCircle.fill()
                innerCircle.stroke()
            }

            // Draw pins for each place
            for (index, place) in places.prefix(5).enumerated() {
                let point = snapshot.point(for: place.coordinate)
                let flippedPoint = NSPoint(x: point.x, y: image.size.height - point.y)

                // Pin shadow
                NSColor.black.withAlphaComponent(0.3).setFill()
                let shadowRect = NSRect(x: flippedPoint.x - 11, y: flippedPoint.y - 23, width: 22, height: 22)
                NSBezierPath(ovalIn: shadowRect).fill()

                // Pin background
                let pinRect = NSRect(x: flippedPoint.x - 12, y: flippedPoint.y - 22, width: 24, height: 24)
                let pinColor: NSColor = index == 0 ? .systemRed : .systemBlue
                pinColor.setFill()
                NSColor.white.setStroke()
                let pinPath = NSBezierPath(ovalIn: pinRect)
                pinPath.lineWidth = 2
                pinPath.fill()
                pinPath.stroke()

                // Pin number
                let numberStr = "\(index + 1)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: NSColor.white
                ]
                let size = numberStr.size(withAttributes: attrs)
                let textPoint = NSPoint(
                    x: pinRect.midX - size.width / 2,
                    y: pinRect.midY - size.height / 2
                )
                numberStr.draw(at: textPoint, withAttributes: attrs)
            }

            finalImage.unlockFocus()
            Self.log("✅ Map snapshot generated with route")
            return finalImage
        } catch {
            Self.log("❌ Map snapshot error: \(error)")
            return nil
        }
    }

    // MARK: - Route Polyline

    private func calculateRoutePolyline(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> MKPolyline? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile

        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            return response.routes.first?.polyline
        } catch {
            Self.log("⚠️ Route calculation failed: \(error)")
            return nil
        }
    }

    // MARK: - Region Containing Coordinates

    private func regionContaining(coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion()
        }

        var minLat = coordinates[0].latitude
        var maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude
        var maxLon = coordinates[0].longitude

        for coord in coordinates {
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Add padding
        let latDelta = (maxLat - minLat) * 1.4 + 0.01
        let lonDelta = (maxLon - minLon) * 1.4 + 0.01

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    // MARK: - Format Category

    private func formatCategory(_ category: MKPointOfInterestCategory) -> String {
        switch category {
        case .restaurant: return "Restaurant"
        case .cafe: return "Cafe"
        case .bakery: return "Bakery"
        case .brewery: return "Brewery"
        case .winery: return "Winery"
        case .nightlife: return "Nightlife"
        case .foodMarket: return "Food Market"
        case .hotel: return "Hotel"
        case .museum: return "Museum"
        case .theater: return "Theater"
        case .park: return "Park"
        case .beach: return "Beach"
        case .zoo: return "Zoo"
        case .aquarium: return "Aquarium"
        case .amusementPark: return "Amusement Park"
        case .stadium: return "Stadium"
        case .fitnessCenter: return "Fitness Center"
        case .store: return "Store"
        case .pharmacy: return "Pharmacy"
        case .hospital: return "Hospital"
        case .bank: return "Bank"
        case .atm: return "ATM"
        case .gasStation: return "Gas Station"
        case .evCharger: return "EV Charger"
        case .airport: return "Airport"
        case .publicTransport: return "Public Transport"
        case .parking: return "Parking"
        case .postOffice: return "Post Office"
        case .library: return "Library"
        case .school: return "School"
        case .university: return "University"
        default: return "Place"
        }
    }
}

// MARK: - Place Category Enum

enum PlaceCategory: String, CaseIterable {
    case restaurant = "restaurant"
    case cafe = "cafe"
    case bar = "bar"
    case hotel = "hotel"
    case attraction = "tourist attraction"
    case museum = "museum"
    case park = "park"
    case shopping = "shopping"
    case gym = "gym"
}

// MARK: - Place Search Result

struct PlaceSearchResult {
    let places: [PlaceInfo]
    let mapSnapshot: NSImage?
    var error: String?
}
