//
//  NavigationEngine.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//

import Foundation
import CoreLocation
import AVFoundation

/// Drives turn-by-turn navigation for an active ride.
///
/// Feed it GPS updates via `update(location:)` and observe the published
/// properties to drive the instruction banner and audio announcements.
@MainActor
class NavigationEngine: ObservableObject {

    // MARK: - Published state (drives the UI)

    /// The instruction the rider is currently heading towards.
    @Published var currentInstruction: RouteInstruction?

    /// Live distance in metres to the next manoeuvre point.
    @Published var distanceToNextM: Double = 0

    /// True when the rider appears to have left the planned route.
    @Published var isOffRoute: Bool = false

    /// True once the rider has reached the final "Arrive" instruction.
    @Published var hasArrived: Bool = false

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

    /// Distance threshold (metres) beyond which the rider is considered off-route.
    private let offRouteThresholdM: Double = 80

    private let speechSynthesiser = AVSpeechSynthesizer()

    // MARK: - Init

    init(route: GeneratedRoute) {
        self.route = route

        // Extract all coordinates from the route polyline once
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: route.polyline.pointCount
        )
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: route.polyline.pointCount))
        self.routeCoordinates = coords

        // Set the first instruction immediately so the banner is populated before movement
        self.currentInstruction = route.instructions.first
        if let first = route.instructions.first {
            self.distanceToNextM = first.distanceToNextM
        }
    }

    // MARK: - Public update method

    /// Call this on every GPS location update during an active ride.
    func update(location: CLLocation) {
        guard !hasArrived, !route.instructions.isEmpty else { return }

        let instructions = route.instructions

        // --- 1. Check off-route ---
        let distanceToRoute = distanceToNearestRoutePoint(from: location)
        isOffRoute = distanceToRoute > offRouteThresholdM

        // --- 2. Advance instruction index if close enough to the manoeuvre point ---
        let nextIndex = currentInstructionIndex + 1
        if nextIndex < instructions.count {
            let nextInstruction = instructions[nextIndex]
            let manoeuvreCoord  = routeCoordinates[safe: nextInstruction.pointIndex]
                                  ?? routeCoordinates.last!
            let manoeuvreLocation = CLLocation(
                latitude:  manoeuvreCoord.latitude,
                longitude: manoeuvreCoord.longitude
            )
            let distToManoeuvre = location.distance(from: manoeuvreLocation)

            // Update the live distance counter
            distanceToNextM = distToManoeuvre

            // "Prepare to turn" cue at ~200 m
            if distToManoeuvre <= prepareThresholdM && !prepareCueFired {
                prepareCueFired = true
                let prepareText = "In \(instructions[nextIndex].formattedDistance), \(instructions[nextIndex].text)"
                speak(prepareText)
            }

            // Advance when within the advance threshold
            if distToManoeuvre <= advanceThresholdM {
                currentInstructionIndex = nextIndex
                currentInstruction      = instructions[nextIndex]
                prepareCueFired         = false

                // Speak the instruction immediately on arrival at the manoeuvre
                speak(instructions[nextIndex].text)

                // Check for arrival (GraphHopper sign 4 = destination reached)
                if instructions[nextIndex].sign == 4 || instructions[nextIndex].sign == -4 {
                    hasArrived = true
                    speak("You have arrived. Great ride!")
                }
            }
        } else {
            // Already on the last instruction — just update distance to end
            if let last = routeCoordinates.last {
                let endLocation = CLLocation(latitude: last.latitude, longitude: last.longitude)
                distanceToNextM = location.distance(from: endLocation)
            }
        }
    }

    // MARK: - Private helpers

    /// Returns the distance in metres from `location` to the nearest point on the route polyline.
    private func distanceToNearestRoutePoint(from location: CLLocation) -> Double {
        guard !routeCoordinates.isEmpty else { return 0 }
        return routeCoordinates
            .map { coord -> Double in
                let pt = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                return location.distance(from: pt)
            }
            .min() ?? 0
    }

    /// Speaks `text` aloud using AVSpeechSynthesizer, interrupting any current speech.
    private func speak(_ text: String) {
        speechSynthesiser.stopSpeaking(at: .immediate)
        let utterance          = AVSpeechUtterance(string: text)
        utterance.voice        = AVSpeechSynthesisVoice(language: "en-AU")
        utterance.rate         = 0.52   // Slightly slower than default for clarity at speed
        utterance.pitchMultiplier = 1.0
        utterance.volume       = 1.0
        speechSynthesiser.speak(utterance)
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
