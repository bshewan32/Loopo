//
//  NavigationEngine.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//

import Foundation
import Combine
import CoreLocation
import MapKit
import AVFoundation

// MARK: - Spatial Grid Index

/// Divides the route polyline into a coarse lat/lon grid so nearest-segment
/// lookups are O(1) rather than O(n) over the full coordinate list.
///
/// For a 150 km route with ~5 000 coordinates, a brute-force scan on every
/// GPS fix (1 Hz) would do 5 000 distance calculations per second on the main
/// thread. The grid reduces that to ~20–50 candidates per lookup.
private struct SpatialGrid {

    struct Cell: Hashable {
        let row: Int
        let col: Int
    }

    /// Each segment is stored by its start-point index into `coords`.
    private var buckets: [Cell: [Int]] = [:]
    private let coords: [CLLocationCoordinate2D]
    private let cellSizeDeg: Double   // degrees per cell (~1 km at mid-latitudes)

    init(coords: [CLLocationCoordinate2D], cellSizeDeg: Double = 0.01) {
        self.coords      = coords
        self.cellSizeDeg = cellSizeDeg

        // Index every segment by both its start and end cell so segments that
        // straddle a cell boundary are still found.
        for i in 0..<(coords.count - 1) {
            let cells = Set([cell(for: coords[i]), cell(for: coords[i + 1])])
            for c in cells {
                buckets[c, default: []].append(i)
            }
        }
    }

    private func cell(for coord: CLLocationCoordinate2D) -> Cell {
        Cell(
            row: Int(floor(coord.latitude  / cellSizeDeg)),
            col: Int(floor(coord.longitude / cellSizeDeg))
        )
    }

    /// Returns the index of the segment start-point whose segment is nearest
    /// to `location`, and the perpendicular distance to that segment in metres.
    func nearestSegment(to location: CLLocation) -> (segmentIndex: Int, distanceM: Double, closestPoint: CLLocationCoordinate2D) {
        let c = cell(for: location.coordinate)

        // Search the cell and its 8 neighbours
        var candidates = Set<Int>()
        for dr in -1...1 {
            for dc in -1...1 {
                let neighbour = Cell(row: c.row + dr, col: c.col + dc)
                if let segs = buckets[neighbour] {
                    candidates.formUnion(segs)
                }
            }
        }

        // If no candidates found in nearby cells, fall back to a broader search
        // (handles sparse routes or large cell gaps)
        if candidates.isEmpty {
            candidates = Set(0..<(coords.count - 1))
        }

        var bestDist  = Double.greatestFiniteMagnitude
        var bestIndex = 0
        var bestPoint = coords[0]

        for i in candidates {
            let (dist, pt) = distanceToSegment(
                point:  location.coordinate,
                segA:   coords[i],
                segB:   coords[i + 1]
            )
            if dist < bestDist {
                bestDist  = dist
                bestIndex = i
                bestPoint = pt
            }
        }

        return (bestIndex, bestDist, bestPoint)
    }

    /// Perpendicular distance (metres) from `point` to segment [segA, segB],
    /// clamped so the foot-of-perpendicular stays within the segment.
    private func distanceToSegment(
        point: CLLocationCoordinate2D,
        segA:  CLLocationCoordinate2D,
        segB:  CLLocationCoordinate2D
    ) -> (Double, CLLocationCoordinate2D) {

        // Work in a local flat-earth projection (accurate to <0.1% within 100 km)
        let cosLat = cos(segA.latitude * .pi / 180)
        let ax = segA.longitude * cosLat,  ay = segA.latitude
        let bx = segB.longitude * cosLat,  by = segB.latitude
        let px = point.longitude * cosLat, py = point.latitude

        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy

        var t = 0.0
        if lenSq > 0 {
            t = ((px - ax) * dx + (py - ay) * dy) / lenSq
            t = max(0, min(1, t))
        }

        let closestLon = (ax + t * dx) / cosLat
        let closestLat =  ay + t * dy
        let closest    = CLLocationCoordinate2D(latitude: closestLat, longitude: closestLon)

        let dist = CLLocation(latitude: point.latitude, longitude: point.longitude)
                       .distance(from: CLLocation(latitude: closestLat, longitude: closestLon))
        return (dist, closest)
    }
}

// MARK: - Navigation Engine

/// Drives turn-by-turn navigation for an active ride.
///
/// All heavy geometry work runs on a background actor so the main thread
/// (and therefore the map camera) is never blocked.
class NavigationEngine: ObservableObject {

    // MARK: - Published state

    @Published var currentInstruction: RouteInstruction?
    @Published var distanceToNextM: Double = 0
    @Published var isOffRoute: Bool = false
    @Published var hasArrived: Bool = false

    // Approach / NDB mode
    @Published var isOnLoop: Bool = false
    @Published var distanceToLoopM: Double = 0
    @Published var bearingToLoopDeg: Double = 0
    @Published var nearestLoopCoordinate: CLLocationCoordinate2D?

    // MARK: - Private state

    private let route: GeneratedRoute
    private let routeCoordinates: [CLLocationCoordinate2D]
    private let grid: SpatialGrid
    private var currentInstructionIndex: Int = 0

    // Thresholds tuned for cycling (20–35 km/h)
    private let advanceThresholdM: Double  = 60    // advance to next instruction
    private let prepareThresholdM: Double  = 300   // "prepare to turn" audio cue
    private let onLoopThresholdM: Double   = 100   // consider rider "on the loop"
                                                    // raised from 80m → 100m to
                                                    // tolerate parallel paths/sidewalks

    private var prepareCueFired: Bool = false
    private var wasOffRoute: Bool     = false
    private var wasApproaching: Bool  = true

    // GPS smoothing for the displayed distance value
    private var smoothedDistanceToNextM: Double = 0
    private let smoothingFactor: Double = 0.25

    private let speechSynthesiser = AVSpeechSynthesizer()

    // Background queue for geometry work
    private let geometryQueue = DispatchQueue(label: "com.loopo.navigation.geometry", qos: .userInteractive)

    // MARK: - Init

    init(route: GeneratedRoute) {
        self.route = route

        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: route.polyline.pointCount
        )
        route.polyline.getCoordinates(
            &coords,
            range: NSRange(location: 0, length: route.polyline.pointCount)
        )
        self.routeCoordinates = coords
        self.grid = SpatialGrid(coords: coords)

        self.currentInstruction = route.instructions.first
        if let first = route.instructions.first {
            self.distanceToNextM         = first.distanceToNextM
            self.smoothedDistanceToNextM = first.distanceToNextM
        }
    }

    // MARK: - Public update (called on every GPS fix)

    func update(location: CLLocation) {
        guard !hasArrived else { return }

        // All geometry runs on the background queue; only @Published writes
        // are dispatched back to the main thread.
        geometryQueue.async { [weak self] in
            self?.processLocation(location)
        }
    }

    // MARK: - Core processing (runs on geometryQueue)

    private func processLocation(_ location: CLLocation) {

        // ── 1. Find nearest segment using the spatial grid ────────────────
        let (_, nearestDist, nearestPt) = grid.nearestSegment(to: location)
        let bearing = bearingFrom(location.coordinate, to: nearestPt)

        DispatchQueue.main.async { [weak self] in
            self?.distanceToLoopM       = nearestDist
            self?.bearingToLoopDeg      = bearing
            self?.nearestLoopCoordinate = nearestPt
        }

        let nowOnLoop = nearestDist <= onLoopThresholdM

        if wasApproaching && nowOnLoop {
            speak("You're on the loop. Navigation starting.")
            resyncToNearestInstruction(from: location)
        }
        wasApproaching = !nowOnLoop
        DispatchQueue.main.async { [weak self] in self?.isOnLoop = nowOnLoop }
        guard nowOnLoop else { return }

        // ── 2. Off-route detection (segment-based, tolerates sidewalks) ───
        // Using segment distance means a rider on a parallel path 30 m away
        // from the route line is correctly considered on-route, even if the
        // nearest *coordinate point* is 80+ m away.
        let nowOffRoute = nearestDist > onLoopThresholdM

        if wasOffRoute && !nowOffRoute {
            resyncToNearestInstruction(from: location)
        }
        wasOffRoute = nowOffRoute
        DispatchQueue.main.async { [weak self] in self?.isOffRoute = nowOffRoute }
        guard !nowOffRoute else { return }

        // ── 3. Instruction advancement ────────────────────────────────────
        let instructions = route.instructions
        guard !instructions.isEmpty else { return }
        let nextIndex = currentInstructionIndex + 1
        guard nextIndex < instructions.count else {
            // Past last instruction — show distance to route end
            if let last = routeCoordinates.last {
                let d = location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
                DispatchQueue.main.async { [weak self] in self?.distanceToNextM = d }
            }
            return
        }

        let nextInstruction = instructions[nextIndex]
        let manoeuvreCoord  = routeCoordinates[safe: nextInstruction.pointIndex]
                              ?? routeCoordinates[routeCoordinates.count - 1]
        let rawDist = location.distance(from: CLLocation(
            latitude:  manoeuvreCoord.latitude,
            longitude: manoeuvreCoord.longitude
        ))

        // Smooth the displayed distance (eliminates GPS jitter in the banner)
        smoothedDistanceToNextM = smoothedDistanceToNextM * (1 - smoothingFactor)
                                + rawDist * smoothingFactor
        let displayDist = smoothedDistanceToNextM

        DispatchQueue.main.async { [weak self] in self?.distanceToNextM = displayDist }

        // "Prepare" audio cue (use raw distance for accuracy)
        if rawDist <= prepareThresholdM && !prepareCueFired {
            prepareCueFired = true
            speak("In \(nextInstruction.formattedDistance), \(nextInstruction.text)")
        }

        // Advance instruction
        if rawDist <= advanceThresholdM {
            currentInstructionIndex  = nextIndex
            prepareCueFired          = false
            smoothedDistanceToNextM  = 0
            speak(nextInstruction.text)

            DispatchQueue.main.async { [weak self] in
                self?.currentInstruction = nextInstruction
                if nextInstruction.sign == 4 || nextInstruction.sign == -4 {
                    self?.hasArrived = true
                    self?.speak("You have arrived. Great ride!")
                }
            }
        }
    }

    // MARK: - Route re-sync

    private func resyncToNearestInstruction(from location: CLLocation) {
        guard !routeCoordinates.isEmpty, !route.instructions.isEmpty else { return }

        let (nearestSegIdx, _, _) = grid.nearestSegment(to: location)
        let instructions          = route.instructions
        var newIndex              = currentInstructionIndex

        for i in (currentInstructionIndex + 1)..<instructions.count {
            if instructions[i].pointIndex <= nearestSegIdx {
                newIndex = i
            } else {
                break
            }
        }

        if newIndex > currentInstructionIndex {
            currentInstructionIndex  = newIndex
            prepareCueFired          = false
            smoothedDistanceToNextM  = 0
            let instruction          = instructions[newIndex]
            DispatchQueue.main.async { [weak self] in self?.currentInstruction = instruction }
            speak("Back on route. \(instruction.text)")
        } else {
            speak("Back on route.")
        }
    }

    // MARK: - Geometry helpers

    private func bearingFrom(_ from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude  * .pi / 180
        let lat2 = to.latitude    * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Audio

    func speak(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speechSynthesiser.stopSpeaking(at: .immediate)
            let utterance             = AVSpeechUtterance(string: text)
            utterance.voice           = AVSpeechSynthesisVoice(language: "en-AU")
            utterance.rate            = 0.52
            utterance.pitchMultiplier = 1.0
            utterance.volume          = 1.0
            self.speechSynthesiser.speak(utterance)
        }
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
