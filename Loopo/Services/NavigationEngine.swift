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
private struct SpatialGrid {

    struct Cell: Hashable {
        let row: Int
        let col: Int
    }

    private var buckets: [Cell: [Int]] = [:]
    private let coords: [CLLocationCoordinate2D]
    private let cellSizeDeg: Double

    init(coords: [CLLocationCoordinate2D], cellSizeDeg: Double = 0.01) {
        self.coords      = coords
        self.cellSizeDeg = cellSizeDeg
        for i in 0..<(coords.count - 1) {
            let cells = Set([cell(for: coords[i]), cell(for: coords[i + 1])])
            for c in cells { buckets[c, default: []].append(i) }
        }
    }

    private func cell(for coord: CLLocationCoordinate2D) -> Cell {
        Cell(
            row: Int(floor(coord.latitude  / cellSizeDeg)),
            col: Int(floor(coord.longitude / cellSizeDeg))
        )
    }

    func nearestSegment(to location: CLLocation) -> (segmentIndex: Int, distanceM: Double, closestPoint: CLLocationCoordinate2D) {
        let c = cell(for: location.coordinate)
        var candidates = Set<Int>()
        for dr in -1...1 {
            for dc in -1...1 {
                if let segs = buckets[Cell(row: c.row + dr, col: c.col + dc)] {
                    candidates.formUnion(segs)
                }
            }
        }
        if candidates.isEmpty { candidates = Set(0..<(coords.count - 1)) }

        var bestDist  = Double.greatestFiniteMagnitude
        var bestIndex = 0
        var bestPoint = coords[0]

        for i in candidates {
            let (dist, pt) = distanceToSegment(point: location.coordinate, segA: coords[i], segB: coords[i + 1])
            if dist < bestDist { bestDist = dist; bestIndex = i; bestPoint = pt }
        }
        return (bestIndex, bestDist, bestPoint)
    }

    private func distanceToSegment(
        point: CLLocationCoordinate2D,
        segA:  CLLocationCoordinate2D,
        segB:  CLLocationCoordinate2D
    ) -> (Double, CLLocationCoordinate2D) {
        let cosLat = cos(segA.latitude * .pi / 180)
        let ax = segA.longitude * cosLat, ay = segA.latitude
        let bx = segB.longitude * cosLat, by = segB.latitude
        let px = point.longitude * cosLat, py = point.latitude
        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        var t = 0.0
        if lenSq > 0 { t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq)) }
        let closestLon = (ax + t * dx) / cosLat
        let closestLat =  ay + t * dy
        let closest    = CLLocationCoordinate2D(latitude: closestLat, longitude: closestLon)
        let dist = CLLocation(latitude: point.latitude, longitude: point.longitude)
                       .distance(from: CLLocation(latitude: closestLat, longitude: closestLon))
        return (dist, closest)
    }
}

// MARK: - Navigation Engine

class NavigationEngine: ObservableObject {

    // MARK: - Published state

    @Published var currentInstruction: RouteInstruction?
    @Published var distanceToNextM: Double = 0
    @Published var isOffRoute: Bool = false
    @Published var hasArrived: Bool = false

    /// True once direction has been determined and chevrons should be flipped.
    /// The view observes this to reverse its chevron bearing offsets.
    @Published var travellingReversed: Bool = false

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
    private var activeInstructions: [RouteInstruction]   // may be reversed

    // Thresholds
    private let advanceThresholdM: Double  = 60
    private let prepareThresholdM: Double  = 300
    private let onLoopThresholdM: Double   = 100

    private var prepareCueFired: Bool  = false
    private var wasOffRoute: Bool      = false
    private var wasApproaching: Bool   = true

    // GPS smoothing
    private var smoothedDistanceToNextM: Double = 0
    private let smoothingFactor: Double = 0.25

    // ── Direction detection ────────────────────────────────────────────────
    // We observe the first few GPS fixes after joining the loop and compare
    // the rider's course against the bearing of the nearest route segment.
    // If they're going the opposite way (angle difference > 120°) we reverse
    // the instruction list and signal the view to flip the chevrons.

    private var directionDetected: Bool    = false
    private var directionSampleCount: Int  = 0
    private let directionSamplesNeeded: Int = 3   // fixes to average before deciding
    private var directionAngleSum: Double  = 0

    // ── Arrival guard ─────────────────────────────────────────────────────
    // Arrival is only triggered when the rider has covered at least this
    // fraction of the route distance. Prevents false arrival at ride start
    // when the loop end coordinate is near the start coordinate.
    private let minArrivalFraction: Double = 0.80
    private var distanceCoveredKm: Double  = 0
    private var lastLocation: CLLocation?

    // ── Audio ─────────────────────────────────────────────────────────────
    private let speechSynthesiser = AVSpeechSynthesizer()
    /// Pending speech text; the audio timer fires it after a short debounce
    /// to avoid rapid-fire calls from consecutive GPS fixes.
    private var pendingSpeech: String?
    private var speechDebounceTimer: DispatchSourceTimer?

    // Background queue for geometry work
    private let geometryQueue = DispatchQueue(label: "com.loopo.navigation.geometry", qos: .userInteractive)

    // MARK: - Init

    init(route: GeneratedRoute) {
        self.route = route

        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: route.polyline.pointCount
        )
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: route.polyline.pointCount))
        self.routeCoordinates = coords
        self.grid             = SpatialGrid(coords: coords)
        self.activeInstructions = route.instructions

        // Configure audio session so speech works even when the phone is on silent
        // and doesn't interrupt music/podcasts (uses ducking instead).
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ AVAudioSession setup failed: \(error.localizedDescription)")
        }

        self.currentInstruction = route.instructions.first
        if let first = route.instructions.first {
            self.distanceToNextM         = first.distanceToNextM
            self.smoothedDistanceToNextM = first.distanceToNextM
        }
    }

    // MARK: - Public update

    func update(location: CLLocation) {
        guard !hasArrived else { return }
        geometryQueue.async { [weak self] in
            self?.processLocation(location)
        }
    }

    // MARK: - Core processing (runs on geometryQueue)

    private func processLocation(_ location: CLLocation) {

        // Track distance covered for arrival guard
        if let last = lastLocation {
            distanceCoveredKm += last.distance(from: location) / 1000.0
        }
        lastLocation = location

        // ── 1. Nearest segment ───────────────────────────────────────────
        let (nearestSegIdx, nearestDist, nearestPt) = grid.nearestSegment(to: location)
        let bearing = bearingFrom(location.coordinate, to: nearestPt)

        DispatchQueue.main.async { [weak self] in
            self?.distanceToLoopM       = nearestDist
            self?.bearingToLoopDeg      = bearing
            self?.nearestLoopCoordinate = nearestPt
        }

        let nowOnLoop = nearestDist <= onLoopThresholdM

        if wasApproaching && nowOnLoop {
            speak("You're on the loop. Navigation starting.")
            // Direction detection starts now; don't resync until we know direction
        }
        wasApproaching = !nowOnLoop
        DispatchQueue.main.async { [weak self] in self?.isOnLoop = nowOnLoop }
        guard nowOnLoop else { return }

        // ── 2. Direction detection (first few fixes after joining loop) ───
        if !directionDetected {
            detectDirection(location: location, nearestSegIdx: nearestSegIdx)
            // Don't process instructions until direction is known
            if !directionDetected { return }
        }

        // ── 3. Off-route detection ───────────────────────────────────────
        let nowOffRoute = nearestDist > onLoopThresholdM
        if wasOffRoute && !nowOffRoute {
            resyncToNearestInstruction(from: location)
        }
        wasOffRoute = nowOffRoute
        DispatchQueue.main.async { [weak self] in self?.isOffRoute = nowOffRoute }
        guard !nowOffRoute else { return }

        // ── 4. Instruction advancement ───────────────────────────────────
        let instructions = activeInstructions
        guard !instructions.isEmpty else { return }
        let nextIndex = currentInstructionIndex + 1
        guard nextIndex < instructions.count else {
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

        smoothedDistanceToNextM = smoothedDistanceToNextM * (1 - smoothingFactor)
                                + rawDist * smoothingFactor
        DispatchQueue.main.async { [weak self] in self?.distanceToNextM = self?.smoothedDistanceToNextM ?? rawDist }

        if rawDist <= prepareThresholdM && !prepareCueFired {
            prepareCueFired = true
            speak("In \(nextInstruction.formattedDistance), \(nextInstruction.text)")
        }

        if rawDist <= advanceThresholdM {
            currentInstructionIndex  = nextIndex
            prepareCueFired          = false
            smoothedDistanceToNextM  = 0
            speak(nextInstruction.text)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.currentInstruction = nextInstruction

                // ── Arrival guard ─────────────────────────────────────────
                // Only trigger arrival if the rider has covered ≥80% of the
                // route distance. This prevents false arrival at ride start
                // when the loop end coordinate is near the start coordinate.
                let isArriveSign = nextInstruction.sign == 4 || nextInstruction.sign == -4
                let coveredEnough = self.distanceCoveredKm >= self.route.distanceKm * self.minArrivalFraction
                if isArriveSign && coveredEnough {
                    self.hasArrived = true
                    self.speak("You have arrived. Great ride!")
                }
            }
        }
    }

    // MARK: - Direction detection

    /// Accumulates GPS course readings for the first few fixes after joining
    /// the loop. Once enough samples are collected, compares the average course
    /// against the bearing of the nearest route segment. If the rider is going
    /// the wrong way (angle difference > 120°), reverses the instruction list
    /// and signals the view to flip the chevron arrows.
    private func detectDirection(location: CLLocation, nearestSegIdx: Int) {
        // We need a valid GPS course (not -1, which means stationary)
        guard location.course >= 0 else { return }

        directionAngleSum  += location.course
        directionSampleCount += 1

        guard directionSampleCount >= directionSamplesNeeded else { return }

        // Average course over the sample window
        let avgCourse = directionAngleSum / Double(directionSampleCount)

        // Bearing of the nearest route segment in the forward direction
        let segCoords = routeCoordinates
        let segBearing: Double
        if nearestSegIdx + 1 < segCoords.count {
            segBearing = bearingFrom(segCoords[nearestSegIdx], to: segCoords[nearestSegIdx + 1])
        } else {
            segBearing = bearingFrom(segCoords[nearestSegIdx - 1], to: segCoords[nearestSegIdx])
        }

        // Angular difference (0–180°)
        var diff = abs(avgCourse - segBearing)
        if diff > 180 { diff = 360 - diff }

        let isReversed = diff > 120   // rider is going opposite to the route direction

        directionDetected = true

        if isReversed {
            // Reverse the instruction list so turn-by-turn matches the actual
            // direction of travel. The chevron bearing offset is handled in the view.
            activeInstructions = route.instructions.reversed()
            currentInstructionIndex = 0
            DispatchQueue.main.async { [weak self] in
                self?.travellingReversed = true
                self?.currentInstruction = self?.activeInstructions.first
            }
            speak("Travelling in reverse direction. Instructions updated.")
        } else {
            resyncToNearestInstruction(from: location)
        }
    }

    // MARK: - Route re-sync

    private func resyncToNearestInstruction(from location: CLLocation) {
        guard !routeCoordinates.isEmpty, !activeInstructions.isEmpty else { return }
        let (nearestSegIdx, _, _) = grid.nearestSegment(to: location)
        let instructions          = activeInstructions
        var newIndex              = currentInstructionIndex

        for i in (currentInstructionIndex + 1)..<instructions.count {
            if instructions[i].pointIndex <= nearestSegIdx { newIndex = i } else { break }
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

    // MARK: - Audio (debounced to prevent rapid-fire calls)

    func speak(_ text: String) {
        // Cancel any pending speech and schedule new text after a short debounce.
        // This prevents multiple consecutive GPS fixes from queueing up speech
        // that arrives out of order or cuts off mid-sentence.
        speechDebounceTimer?.cancel()
        pendingSpeech = text

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self, let text = self.pendingSpeech else { return }
            self.pendingSpeech = nil
            self.speechSynthesiser.stopSpeaking(at: .word)   // finish current word, then stop
            let utterance             = AVSpeechUtterance(string: text)
            utterance.voice           = AVSpeechSynthesisVoice(language: "en-AU")
            utterance.rate            = 0.52
            utterance.pitchMultiplier = 1.0
            utterance.volume          = 1.0
            self.speechSynthesiser.speak(utterance)
        }
        timer.resume()
        speechDebounceTimer = timer
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
