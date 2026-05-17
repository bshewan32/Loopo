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

/// Drives turn-by-turn navigation for an active ride.
///
/// Feed it GPS updates via `update(location:)` and observe the published
/// properties to drive the instruction banner, NDB arrow, and audio announcements.
class NavigationEngine: ObservableObject {

    // MARK: - Published state (drives the UI)

    /// The instruction the rider is currently heading towards (nil when approaching the loop).
    @Published var currentInstruction: RouteInstruction?

    /// Live distance in metres to the next manoeuvre point.
    @Published var distanceToNextM: Double = 0

    /// True when the rider appears to have left the planned route.
    @Published var isOffRoute: Bool = false

    /// True once the rider has reached the final "Arrive" instruction.
    @Published var hasArrived: Bool = false

    // MARK: - Approach mode (NDB arrow)

    /// True when the rider is within the on-route threshold and turn-by-turn is active.
    @Published var isOnLoop: Bool = false

    /// Distance in metres to the nearest point on the loop polyline.
    @Published var distanceToLoopM: Double = 0

    /// Bearing in degrees (0–360, true north = 0) from the rider's current position
    /// to the nearest point on the loop. Drive the NDB arrow with this value.
    @Published var bearingToLoopDeg: Double = 0

    /// The nearest coordinate on the loop polyline to the rider's current position.
    @Published var nearestLoopCoordinate: CLLocationCoordinate2D?

    // MARK: - Private state

    private let route: GeneratedRoute
    private let routeCoordinates: [CLLocationCoordinate2D]
    private var currentInstructionIndex: Int = 0

    // ── Timing thresholds ──────────────────────────────────────────────────
    // These are tuned for cycling speeds (20–35 km/h).
    // At 25 km/h:  60 m advance threshold = ~8.6 s warning
    //              300 m prepare threshold = ~43 s "prepare" audio cue
    //
    // The previous values (40 m / 200 m) were fine on foot but felt late
    // at cycling speed. Increasing both gives the rider more reaction time.

    /// Distance threshold (metres) at which we advance to the next instruction.
    private let advanceThresholdM: Double = 60

    /// Distance threshold (metres) at which we give the "prepare to turn" audio cue.
    private let prepareThresholdM: Double = 300

    /// Whether the "prepare" cue for the current instruction has already been spoken.
    private var prepareCueFired: Bool = false

    /// Distance threshold (metres) within which the rider is considered on the loop.
    private let onLoopThresholdM: Double = 80

    /// Tracks whether we were off-route on the previous update.
    private var wasOffRoute: Bool = false

    /// Tracks whether we were approaching (not on loop) on the previous update.
    private var wasApproaching: Bool = true

    // ── GPS smoothing ──────────────────────────────────────────────────────
    // Raw GPS can jump 10–20 m between fixes, causing jittery distance readings.
    // We apply a simple exponential moving average to smooth the distance value
    // shown in the banner. The underlying advance logic still uses raw distance
    // so it doesn't introduce artificial lag.

    private var smoothedDistanceToNextM: Double = 0
    private let smoothingFactor: Double = 0.25   // 0 = no smoothing, 1 = instant

    private let speechSynthesiser = AVSpeechSynthesizer()

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

        self.isOnLoop = false
        self.currentInstruction = route.instructions.first
        if let first = route.instructions.first {
            self.distanceToNextM      = first.distanceToNextM
            self.smoothedDistanceToNextM = first.distanceToNextM
        }
    }

    // MARK: - Public update method

    /// Call this on every GPS location update during an active ride.
    func update(location: CLLocation) {
        guard !hasArrived else { return }

        // --- 1. Find nearest loop point and update approach state ---
        let (nearestDist, nearestIndex) = nearestRoutePoint(from: location)
        let nearestCoord = routeCoordinates[safe: nearestIndex]
        let bearing = nearestCoord.map { bearingFrom(location.coordinate, to: $0) } ?? 0

        DispatchQueue.main.async {
            self.distanceToLoopM       = nearestDist
            self.bearingToLoopDeg      = bearing
            self.nearestLoopCoordinate = nearestCoord
        }

        let nowOnLoop = nearestDist <= onLoopThresholdM

        if wasApproaching && nowOnLoop {
            speak("You're on the loop. Navigation starting.")
            resyncToNearestInstruction(from: location)
        }

        wasApproaching = !nowOnLoop
        DispatchQueue.main.async { self.isOnLoop = nowOnLoop }

        if !nowOnLoop { return }

        // --- 2. Off-route detection ---
        let nowOffRoute = nearestDist > onLoopThresholdM

        if wasOffRoute && !nowOffRoute {
            resyncToNearestInstruction(from: location)
        }

        wasOffRoute = nowOffRoute
        DispatchQueue.main.async { self.isOffRoute = nowOffRoute }

        if nowOffRoute { return }

        // --- 3. Advance instruction index ---
        guard !route.instructions.isEmpty else { return }
        let instructions = route.instructions
        let nextIndex    = currentInstructionIndex + 1

        if nextIndex < instructions.count {
            let nextInstruction   = instructions[nextIndex]
            let manoeuvreCoord    = routeCoordinates[safe: nextInstruction.pointIndex]
                                    ?? routeCoordinates[routeCoordinates.count - 1]
            let manoeuvreLocation = CLLocation(
                latitude:  manoeuvreCoord.latitude,
                longitude: manoeuvreCoord.longitude
            )
            let rawDist = location.distance(from: manoeuvreLocation)

            // Smooth the displayed distance to avoid jitter in the banner
            smoothedDistanceToNextM = smoothedDistanceToNextM * (1 - smoothingFactor)
                                    + rawDist * smoothingFactor

            DispatchQueue.main.async { self.distanceToNextM = self.smoothedDistanceToNextM }

            // "Prepare to turn" cue — use raw distance for accuracy
            if rawDist <= prepareThresholdM && !prepareCueFired {
                prepareCueFired = true
                let prepareText = "In \(nextInstruction.formattedDistance), \(nextInstruction.text)"
                speak(prepareText)
            }

            // Advance when within the advance threshold — use raw distance
            if rawDist <= advanceThresholdM {
                currentInstructionIndex  = nextIndex
                prepareCueFired          = false
                smoothedDistanceToNextM  = 0
                speak(nextInstruction.text)

                DispatchQueue.main.async {
                    self.currentInstruction = nextInstruction

                    if nextInstruction.sign == 4 || nextInstruction.sign == -4 {
                        self.hasArrived = true
                        self.speak("You have arrived. Great ride!")
                    }
                }
            }
        } else {
            if let last = routeCoordinates.last {
                let endLocation = CLLocation(latitude: last.latitude, longitude: last.longitude)
                let d = location.distance(from: endLocation)
                DispatchQueue.main.async { self.distanceToNextM = d }
            }
        }
    }

    // MARK: - Route re-sync

    private func resyncToNearestInstruction(from location: CLLocation) {
        guard !routeCoordinates.isEmpty, !route.instructions.isEmpty else { return }

        let (_, nearestIndex) = nearestRoutePoint(from: location)
        let instructions      = route.instructions
        var newInstructionIndex = currentInstructionIndex

        for i in (currentInstructionIndex + 1)..<instructions.count {
            if instructions[i].pointIndex <= nearestIndex {
                newInstructionIndex = i
            } else {
                break
            }
        }

        if newInstructionIndex > currentInstructionIndex {
            currentInstructionIndex  = newInstructionIndex
            prepareCueFired          = false
            smoothedDistanceToNextM  = 0
            let instruction          = instructions[newInstructionIndex]
            DispatchQueue.main.async { self.currentInstruction = instruction }
            speak("Back on route. \(instruction.text)")
        } else {
            speak("Back on route.")
        }
    }

    // MARK: - Geometry helpers

    private func nearestRoutePoint(from location: CLLocation) -> (Double, Int) {
        guard !routeCoordinates.isEmpty else { return (0, 0) }
        var nearestDist  = Double.greatestFiniteMagnitude
        var nearestIndex = 0
        for (i, coord) in routeCoordinates.enumerated() {
            let d = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                        .distance(from: location)
            if d < nearestDist {
                nearestDist  = d
                nearestIndex = i
            }
        }
        return (nearestDist, nearestIndex)
    }

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
        speechSynthesiser.stopSpeaking(at: .immediate)
        let utterance             = AVSpeechUtterance(string: text)
        utterance.voice           = AVSpeechSynthesisVoice(language: "en-AU")
        utterance.rate            = 0.52
        utterance.pitchMultiplier = 1.0
        utterance.volume          = 1.0
        speechSynthesiser.speak(utterance)
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
