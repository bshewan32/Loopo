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
    /// False when the rider is still approaching the loop from outside.
    @Published var isOnLoop: Bool = false

    /// Distance in metres to the nearest point on the loop polyline.
    @Published var distanceToLoopM: Double = 0

    /// Bearing in degrees (0–360, true north = 0) from the rider's current position
    /// to the nearest point on the loop. Drive the NDB arrow with this value.
    @Published var bearingToLoopDeg: Double = 0

    /// The nearest coordinate on the loop polyline to the rider's current position.
    /// Used by the map to optionally draw a line from the user to the loop.
    @Published var nearestLoopCoordinate: CLLocationCoordinate2D?

    // MARK: - Private state

    private let route: GeneratedRoute
    private let routeCoordinates: [CLLocationCoordinate2D]
    private var currentInstructionIndex: Int = 0

    /// Distance threshold (metres) at which we advance to the next instruction.
    private let advanceThresholdM: Double = 40

    /// Distance threshold (metres) at which we give the "prepare to turn" audio cue.
    private let prepareThresholdM: Double = 200

    /// Whether the "prepare" cue for the current instruction has already been spoken.
    private var prepareCueFired: Bool = false

    /// Distance threshold (metres) within which the rider is considered on the loop.
    /// Below this: turn-by-turn active. Above this: NDB approach arrow shown.
    private let onLoopThresholdM: Double = 80

    /// Tracks whether we were off-route on the previous update, so we can detect the moment of re-join.
    private var wasOffRoute: Bool = false

    /// Tracks whether we were approaching (not on loop) on the previous update.
    private var wasApproaching: Bool = true

    private let speechSynthesiser = AVSpeechSynthesizer()

    // MARK: - Init

    init(route: GeneratedRoute) {
        self.route = route

        // Extract all coordinates from the route polyline once
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: route.polyline.pointCount
        )
        route.polyline.getCoordinates(
            &coords,
            range: NSRange(location: 0, length: route.polyline.pointCount)
        )
        self.routeCoordinates = coords

        // Start in approach mode — the rider may not be on the loop yet
        self.isOnLoop = false
        self.currentInstruction = route.instructions.first
        if let first = route.instructions.first {
            self.distanceToNextM = first.distanceToNextM
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

        // Announce the transition from approach → on-loop
        if wasApproaching && nowOnLoop {
            speak("You're on the loop. Navigation starting.")
            resyncToNearestInstruction(from: location)
        }

        wasApproaching = !nowOnLoop
        DispatchQueue.main.async { self.isOnLoop = nowOnLoop }

        // While approaching, don't run turn-by-turn logic
        if !nowOnLoop { return }

        // --- 2. Off-route detection (only relevant once on the loop) ---
        let nowOffRoute = nearestDist > onLoopThresholdM

        if wasOffRoute && !nowOffRoute {
            resyncToNearestInstruction(from: location)
        }

        wasOffRoute = nowOffRoute
        DispatchQueue.main.async { self.isOffRoute = nowOffRoute }

        if nowOffRoute { return }

        // --- 3. Advance instruction index if close enough to the manoeuvre point ---
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
            let distToManoeuvre = location.distance(from: manoeuvreLocation)

            DispatchQueue.main.async { self.distanceToNextM = distToManoeuvre }

            // "Prepare to turn" cue at ~200 m
            if distToManoeuvre <= prepareThresholdM && !prepareCueFired {
                prepareCueFired = true
                let prepareText = "In \(nextInstruction.formattedDistance), \(nextInstruction.text)"
                speak(prepareText)
            }

            // Advance when within the advance threshold
            if distToManoeuvre <= advanceThresholdM {
                currentInstructionIndex = nextIndex
                prepareCueFired         = false
                speak(nextInstruction.text)

                DispatchQueue.main.async {
                    self.currentInstruction = nextInstruction

                    // Check for arrival (GraphHopper sign 4 = destination reached)
                    if nextInstruction.sign == 4 || nextInstruction.sign == -4 {
                        self.hasArrived = true
                        self.speak("You have arrived. Great ride!")
                    }
                }
            }
        } else {
            // Already on the last instruction — update distance to route end
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
            currentInstructionIndex = newInstructionIndex
            prepareCueFired         = false
            let instruction         = instructions[newInstructionIndex]
            DispatchQueue.main.async { self.currentInstruction = instruction }
            speak("Back on route. \(instruction.text)")
        } else {
            speak("Back on route.")
        }
    }

    // MARK: - Geometry helpers

    /// Returns (distance, index) of the nearest coordinate on the route polyline.
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

    /// Calculates the bearing in degrees (0–360) from `from` to `to`.
    private func bearingFrom(_ from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude  * .pi / 180
        let lat2 = to.latitude    * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
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
