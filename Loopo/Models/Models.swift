//
//  Models.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//

import Foundation
import Combine
import CoreLocation
import MapKit

// MARK: - Terrain Profile

enum TerrainProfile: String, CaseIterable, Codable {
    case flat        = "Flat"
    case mostlyFlat  = "Mostly Flat"
    case hilly       = "Hilly"
    case reallyHilly = "Really Hilly"

    var icon: String {
        switch self {
        case .flat:        return "minus"
        case .mostlyFlat:  return "chart.line.uptrend.xyaxis"
        case .hilly:       return "mountain.2"
        case .reallyHilly: return "mountain.2.fill"
        }
    }

    /// Metres of climbing per kilometre
    var climbPerKm: ClosedRange<Double> {
        switch self {
        case .flat:        return 0...5
        case .mostlyFlat:  return 5...10
        case .hilly:       return 10...18
        case .reallyHilly: return 18...100
        }
    }

    var description: String {
        switch self {
        case .flat:        return "< 5m/km"
        case .mostlyFlat:  return "5–10m/km"
        case .hilly:       return "10–18m/km"
        case .reallyHilly: return "18m/km+"
        }
    }
}

// MARK: - Route Instruction

/// A single turn-by-turn manoeuvre returned by GraphHopper.
struct RouteInstruction: Identifiable {
    let id = UUID()

    /// Human-readable instruction text, e.g. "Turn left onto High Street".
    let text: String

    /// Street name for the upcoming segment (may be empty on unnamed roads).
    let streetName: String

    /// Distance in metres from this manoeuvre to the next.
    let distanceToNextM: Double

    /// Index into the route's coordinate array where this manoeuvre occurs.
    let pointIndex: Int

    /// GraphHopper sign value — used to pick the correct SF Symbol arrow.
    let sign: Int

    /// Returns an SF Symbol name that matches the manoeuvre type.
    var symbolName: String {
        switch sign {
        case -3:    return "arrow.uturn.left"
        case -2:    return "arrow.turn.up.left"
        case -1:    return "arrow.left"
        case 0:     return "arrow.up"
        case 1:     return "arrow.right"
        case 2:     return "arrow.turn.up.right"
        case 3:     return "arrow.uturn.right"
        case 4, -4: return "flag.checkered"
        case 5:     return "arrow.up"
        case 6:     return "arrow.merge"
        case 7:     return "arrow.branch.right"
        default:    return "arrow.up"
        }
    }

    /// Formatted distance string for display, e.g. "320 m" or "1.2 km".
    var formattedDistance: String {
        if distanceToNextM >= 1000 {
            return String(format: "%.1f km", distanceToNextM / 1000)
        }
        return String(format: "%.0f m", distanceToNextM)
    }
}

// MARK: - Generated Route

struct GeneratedRoute: Identifiable {
    let id   = UUID()
    let name: String
    let polyline: MKPolyline
    let waypoints: [CLLocationCoordinate2D]
    let distanceKm: Double
    let estimatedClimbM: Double
    let estimatedDurationMin: Double
    let terrain: TerrainProfile

    /// Turn-by-turn instructions decoded from the GraphHopper response.
    let instructions: [RouteInstruction]

    init(
        name: String,
        polyline: MKPolyline,
        waypoints: [CLLocationCoordinate2D] = [],
        distanceKm: Double,
        estimatedClimbM: Double,
        estimatedDurationMin: Double,
        terrain: TerrainProfile,
        instructions: [RouteInstruction] = []
    ) {
        self.name                 = name
        self.polyline             = polyline
        self.waypoints            = waypoints
        self.distanceKm           = distanceKm
        self.estimatedClimbM      = estimatedClimbM
        self.estimatedDurationMin = estimatedDurationMin
        self.terrain              = terrain
        self.instructions         = instructions
    }

    var climbPerKm: Double {
        distanceKm > 0 ? estimatedClimbM / distanceKm : 0
    }

    var formattedDistance: String {
        String(format: "%.1f km", distanceKm)
    }

    var formattedClimb: String {
        String(format: "%.0f m", estimatedClimbM)
    }

    var formattedDuration: String {
        let hours = Int(estimatedDurationMin) / 60
        let mins  = Int(estimatedDurationMin) % 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

// MARK: - Active Ride (in progress)

class ActiveRide: ObservableObject {
    let route: GeneratedRoute
    let startDate: Date

    @Published var elapsedSeconds: Double = 0
    @Published var distanceCoveredKm: Double = 0
    @Published var recordedCoordinates: [CLLocationCoordinate2D] = []
    @Published var currentSpeed: Double = 0  // km/h

    private var timer: Timer?

    init(route: GeneratedRoute) {
        self.route     = route
        self.startDate = Date()
        startTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsedSeconds += 1
        }
    }

    func stop() {
        timer?.invalidate()
    }

    var formattedElapsed: String {
        let h = Int(elapsedSeconds) / 3600
        let m = (Int(elapsedSeconds) % 3600) / 60
        let s = Int(elapsedSeconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var averageSpeedKph: Double {
        elapsedSeconds > 0 ? distanceCoveredKm / (elapsedSeconds / 3600) : 0
    }

    func toSavedRide() -> SavedRide {
        SavedRide(
            id: UUID(),
            routeName: route.name,
            date: startDate,
            durationSeconds: elapsedSeconds,
            distanceKm: distanceCoveredKm,
            estimatedClimbM: route.estimatedClimbM,
            terrain: route.terrain,
            coordinates: recordedCoordinates.map { CodableCoordinate($0) }
        )
    }
}

// MARK: - Saved Ride (persisted)

struct SavedRide: Identifiable, Codable {
    let id: UUID
    let routeName: String
    let date: Date
    let durationSeconds: Double
    let distanceKm: Double
    let estimatedClimbM: Double
    let terrain: TerrainProfile
    let coordinates: [CodableCoordinate]

    var averageSpeedKph: Double {
        durationSeconds > 0 ? distanceKm / (durationSeconds / 3600) : 0
    }

    var formattedDuration: String {
        let h = Int(durationSeconds) / 3600
        let m = (Int(durationSeconds) % 3600) / 60
        let s = Int(durationSeconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Codable coordinate wrapper

struct CodableCoordinate: Codable {
    let latitude: Double
    let longitude: Double

    init(_ coord: CLLocationCoordinate2D) {
        self.latitude  = coord.latitude
        self.longitude = coord.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
