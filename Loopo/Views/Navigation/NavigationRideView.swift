//
//  NavigationRideView.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//

import SwiftUI
import MapKit

struct NavigationRideView: View {
    let route: GeneratedRoute

    @EnvironmentObject var appState: AppState
    @StateObject private var locationService = LocationService.shared
    @StateObject private var activeRide: ActiveRide
    @StateObject private var navEngine: NavigationEngine

    @State private var showEndConfirm = false
    @State private var rideFinished   = false
    @State private var savedRide: SavedRide?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var followsUser = true

    // Pulses the distance label red when a turn is imminent
    @State private var imminentPulse = false

    @Environment(\.dismiss) var dismiss

    init(route: GeneratedRoute) {
        self.route = route
        _activeRide = StateObject(wrappedValue: ActiveRide(route: route))
        _navEngine  = StateObject(wrappedValue: NavigationEngine(route: route))
    }

    var body: some View {
        ZStack {
            // MARK: Map
            Map(position: $cameraPosition) {
                MapPolyline(route.polyline)
                    .stroke(Color("LoopGreen"), lineWidth: 4)
                UserAnnotation()
            }
            .ignoresSafeArea()
            .onAppear {
                startRide()
                zoomToRoute()
            }

            // MARK: Overlays
            VStack(spacing: 0) {

                // ── Instruction banner (full-width, handlebar-optimised) ──
                if !navEngine.hasArrived {
                    instructionBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // ── Off-route warning ──
                if navEngine.isOffRoute {
                    offRouteBanner
                        .padding(.top, 6)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                }

                // ── Arrival banner ──
                if navEngine.hasArrived {
                    arrivalBanner
                        .padding(.top, 12)
                        .padding(.horizontal, 12)
                        .transition(.scale.combined(with: .opacity))
                }

                Spacer()

                // ── Stats bar ──
                rideStatsBar
                    .padding(.horizontal, 12)

                // ── Bottom controls ──
                bottomControls
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                    .padding(.horizontal, 12)
            }
        }
        .navigationBarHidden(true)
        .animation(.easeInOut(duration: 0.25), value: navEngine.currentInstruction?.id)
        .animation(.easeInOut(duration: 0.25), value: navEngine.isOffRoute)
        .animation(.easeInOut(duration: 0.25), value: navEngine.hasArrived)
        .onChange(of: navEngine.distanceToNextM) { dist in
            // Trigger pulse animation when within 50 m of a turn
            let shouldPulse = dist <= 50 && dist > 0
            if shouldPulse != imminentPulse {
                withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                    imminentPulse = shouldPulse
                }
            }
        }
        .alert("End Ride?", isPresented: $showEndConfirm) {
            Button("End & Save", role: .destructive) { endRide() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your ride will be saved to history.")
        }
        .navigationDestination(isPresented: $rideFinished) {
            if let ride = savedRide {
                RideSummaryView(ride: ride)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Instruction Banner (handlebar-optimised)
    //
    // Design principles for handlebar mounting:
    //  • Full screen width — no horizontal padding so it fills edge to edge
    //  • Arrow icon is large (80 pt circle) and sits in its own left column
    //  • Distance is the single most important number — 48 pt black rounded font
    //  • Street name is 22 pt so it's readable at a glance
    //  • Solid dark background (not just blur) for contrast in bright sunlight
    //  • Minimum height of ~120 pt so the block is easy to find without looking hard

    private var instructionBanner: some View {
        HStack(alignment: .center, spacing: 0) {

            // Left column — direction arrow
            ZStack {
                Rectangle()
                    .fill(Color("LoopGreen"))
                    .frame(width: 100)

                Image(systemName: navEngine.currentInstruction?.symbolName ?? "arrow.up")
                    .font(.system(size: 48, weight: .black))
                    .foregroundColor(.black)
            }
            .frame(maxHeight: .infinity)

            // Right column — distance + instruction text
            VStack(alignment: .leading, spacing: 4) {

                // Distance — largest element, changes colour when imminent
                Text(distanceLabel)
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .foregroundColor(imminentPulse ? .red : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                // Instruction verb, e.g. "Turn left"
                Text(navEngine.currentInstruction?.text ?? "Follow the route")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                // Street name
                if let street = navEngine.currentInstruction?.streetName, !street.isEmpty {
                    Text(street)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color("LoopGreen"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120)
        .background(Color.black.opacity(0.82))
        // Subtle bottom shadow so it lifts off the map
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
    }

    private var distanceLabel: String {
        let d = navEngine.distanceToNextM
        if d >= 1000 { return String(format: "%.1f km", d / 1000) }
        return String(format: "%.0f m", d)
    }

    // MARK: - Off-Route Banner

    private var offRouteBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.orange)
            Text("Off route — return to the green line")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.30))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.7), lineWidth: 1.5)
        )
        .cornerRadius(12)
    }

    // MARK: - Arrival Banner

    private var arrivalBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(Color("LoopGreen"))
            VStack(alignment: .leading, spacing: 4) {
                Text("You've arrived!")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text("Great ride. Tap End Ride to save.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
        }
        .padding(18)
        .background(Color.black.opacity(0.82))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
    }

    // MARK: - Stats Bar

    private var rideStatsBar: some View {
        HStack(spacing: 0) {
            RideStatCell(label: "TIME", value: activeRide.formattedElapsed)
            Divider().background(Color.white.opacity(0.15)).frame(height: 44)
            RideStatCell(label: "KM",   value: String(format: "%.1f", locationService.totalDistanceKm))
            Divider().background(Color.white.opacity(0.15)).frame(height: 44)
            RideStatCell(label: "km/h", value: String(format: "%.1f", activeRide.averageSpeedKph))
        }
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.75))
        .cornerRadius(14)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 16) {
            // Re-centre on user
            Button {
                followsUser = true
                zoomToUserLocation()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(28)
            }

            Spacer()

            // End ride
            Button {
                showEndConfirm = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18))
                    Text("End Ride")
                        .font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(Color.red.opacity(0.9))
                .cornerRadius(30)
            }
        }
    }

    // MARK: - Ride lifecycle

    private func startRide() {
        locationService.startTracking()
        locationService.onLocationUpdate = { location in
            DispatchQueue.main.async {
                Task { @MainActor in
                    navEngine.update(location: location)
                }
                activeRide.recordedCoordinates.append(location.coordinate)
                activeRide.distanceCoveredKm = locationService.totalDistanceKm
                activeRide.currentSpeed      = location.speed > 0 ? location.speed * 3.6 : 0

                if followsUser {
                    withAnimation {
                        cameraPosition = .region(MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                        ))
                    }
                }
            }
        }
    }

    private func endRide() {
        locationService.stopTracking()
        activeRide.stop()

        let ride = SavedRide(
            id: UUID(),
            routeName: route.name,
            date: activeRide.startDate,
            durationSeconds: activeRide.elapsedSeconds,
            distanceKm: locationService.totalDistanceKm,
            estimatedClimbM: route.estimatedClimbM,
            terrain: route.terrain,
            coordinates: activeRide.recordedCoordinates.map { CodableCoordinate($0) }
        )
        appState.saveRide(ride)
        savedRide    = ride
        rideFinished = true
    }

    private func zoomToRoute() {
        cameraPosition = .rect(route.polyline.boundingMapRect)
    }

    private func zoomToUserLocation() {
        if let loc = locationService.currentLocation {
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: loc.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                ))
            }
        }
    }
}

// MARK: - Stat Cell

struct RideStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.gray)
                .tracking(1.5)
        }
        .frame(maxWidth: .infinity)
    }
}
