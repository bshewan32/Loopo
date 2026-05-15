//
//  NavigationRideView.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//

import SwiftUI
import MapKit

// MARK: - Display mode

private enum DisplayMode {
    /// Full instruction banner + stats bar visible. Map takes remaining space.
    case navigation
    /// Map fills the entire screen. Only a compact floating HUD is shown.
    case fullMap
}

struct NavigationRideView: View {
    let route: GeneratedRoute

    @EnvironmentObject var appState: AppState
    @StateObject private var locationService = LocationService.shared
    @StateObject private var activeRide: ActiveRide
    @StateObject private var navEngine: NavigationEngine

    @State private var showEndConfirm  = false
    @State private var rideFinished    = false
    @State private var savedRide: SavedRide?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var followsUser     = true
    @State private var displayMode: DisplayMode = .navigation
    @State private var imminentPulse   = false

    @Environment(\.dismiss) var dismiss

    init(route: GeneratedRoute) {
        self.route  = route
        _activeRide = StateObject(wrappedValue: ActiveRide(route: route))
        _navEngine  = StateObject(wrappedValue: NavigationEngine(route: route))
    }

    var body: some View {
        ZStack {
            // ── Full-screen map ──────────────────────────────────────────
            Map(position: $cameraPosition) {
                MapPolyline(route.polyline)
                    .stroke(Color("LoopGreen"), lineWidth: 4)
                UserAnnotation()
            }
            .ignoresSafeArea()
            .onAppear {
                setupLocationCallback()
                zoomToRoute()
            }
            .onTapGesture {
                // Tapping the map disables auto-follow so the user can pan freely
                followsUser = false
            }

            // ── Overlays (mode-dependent) ────────────────────────────────
            switch displayMode {
            case .navigation:
                navigationModeOverlay
            case .fullMap:
                fullMapModeOverlay
            }
        }
        .navigationBarHidden(true)
        .animation(.easeInOut(duration: 0.3), value: navEngine.currentInstruction?.id)
        .animation(.easeInOut(duration: 0.3), value: navEngine.isOffRoute)
        .animation(.easeInOut(duration: 0.3), value: navEngine.hasArrived)
        .animation(.easeInOut(duration: 0.3), value: navEngine.isOnLoop)
        .animation(.easeInOut(duration: 0.3), value: displayMode == .navigation)
        .onChange(of: navEngine.distanceToNextM) { dist in
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

    // MARK: - Navigation mode overlay (default)
    // Top: instruction banner (or NDB arrow when approaching)
    // Bottom: stats bar + controls

    private var navigationModeOverlay: some View {
        VStack(spacing: 0) {

            // Top banner — switches between NDB approach and turn-by-turn
            if navEngine.hasArrived {
                arrivalBanner
                    .transition(.scale.combined(with: .opacity))
            } else if !navEngine.isOnLoop {
                ndbApproachBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                instructionBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Off-route warning (only relevant once on the loop)
            if navEngine.isOnLoop && navEngine.isOffRoute {
                offRouteBanner
                    .padding(.top, 6)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }

            Spacer()

            rideStatsBar
                .padding(.horizontal, 12)

            bottomControls
                .padding(.top, 10)
                .padding(.bottom, 40)
                .padding(.horizontal, 12)
        }
    }

    // MARK: - Full-map mode overlay
    // Compact floating HUD at top + minimal controls at bottom

    private var fullMapModeOverlay: some View {
        VStack(spacing: 0) {
            // Compact HUD — always shows next turn info or NDB distance
            compactHUD
                .padding(.horizontal, 12)
                .padding(.top, 56)

            Spacer()

            // Minimal bottom bar: re-centre + toggle + end
            HStack(spacing: 12) {
                recentreButton
                Spacer()
                mapToggleButton
                Spacer()
                endRideButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 40)
        }
    }

    // MARK: - NDB Approach Banner
    //
    // Shown when the rider is not yet on the loop.
    // A large rotating arrow points toward the nearest point on the loop.
    // The bearing is relative to the rider's current heading so the arrow
    // acts like a compass needle — point yourself at it and ride.

    private var ndbApproachBanner: some View {
        HStack(alignment: .center, spacing: 0) {

            // Left column — rotating NDB arrow
            ZStack {
                Rectangle()
                    .fill(Color.blue.opacity(0.85))
                    .frame(width: 100)

                VStack(spacing: 4) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 44, weight: .black))
                        .foregroundColor(.white)
                        // Rotate the arrow: bearing to loop minus current device heading
                        .rotationEffect(.degrees(relativeNDBBearing))

                    Text("TO LOOP")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.white.opacity(0.7))
                        .tracking(1.5)
                }
            }
            .frame(maxHeight: .infinity)

            // Right column — distance to loop
            VStack(alignment: .leading, spacing: 4) {
                Text(loopDistanceLabel)
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text("Ride toward the loop")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))

                Text("Turn-by-turn starts automatically")
                    .font(.system(size: 14))
                    .foregroundColor(.blue.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120)
        .background(Color.black.opacity(0.82))
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
    }

    /// Bearing of the loop relative to the rider's current heading.
    /// This makes the arrow behave like a compass — it points at the loop
    /// regardless of which direction the rider is facing.
    private var relativeNDBBearing: Double {
        let absolute   = navEngine.bearingToLoopDeg
        let deviceTrue = locationService.heading?.trueHeading ?? 0
        let relative   = (absolute - deviceTrue + 360).truncatingRemainder(dividingBy: 360)
        return relative
    }

    private var loopDistanceLabel: String {
        let d = navEngine.distanceToLoopM
        if d >= 1000 { return String(format: "%.1f km", d / 1000) }
        return String(format: "%.0f m", d)
    }

    // MARK: - Instruction Banner (handlebar-optimised, shown when on loop)

    private var instructionBanner: some View {
        HStack(alignment: .center, spacing: 0) {

            ZStack {
                Rectangle()
                    .fill(Color("LoopGreen"))
                    .frame(width: 100)
                Image(systemName: navEngine.currentInstruction?.symbolName ?? "arrow.up")
                    .font(.system(size: 48, weight: .black))
                    .foregroundColor(.black)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(distanceLabel)
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .foregroundColor(imminentPulse ? .red : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(navEngine.currentInstruction?.text ?? "Follow the route")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

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
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
    }

    private var distanceLabel: String {
        let d = navEngine.distanceToNextM
        if d >= 1000 { return String(format: "%.1f km", d / 1000) }
        return String(format: "%.0f m", d)
    }

    // MARK: - Compact HUD (full-map mode)

    private var compactHUD: some View {
        HStack(spacing: 12) {
            // Arrow or NDB indicator
            ZStack {
                Circle()
                    .fill(navEngine.isOnLoop ? Color("LoopGreen") : Color.blue)
                    .frame(width: 44, height: 44)
                Image(systemName: navEngine.isOnLoop
                      ? (navEngine.currentInstruction?.symbolName ?? "arrow.up")
                      : "location.north.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundColor(navEngine.isOnLoop ? .black : .white)
                    .rotationEffect(navEngine.isOnLoop ? .zero : .degrees(relativeNDBBearing))
            }

            VStack(alignment: .leading, spacing: 2) {
                if navEngine.isOnLoop {
                    Text(distanceLabel)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text(navEngine.currentInstruction?.text ?? "Follow the route")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                } else {
                    Text(loopDistanceLabel)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text("Ride toward the loop")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Spacer()

            // Stats pill
            HStack(spacing: 8) {
                Text(String(format: "%.1f km", locationService.totalDistanceKm))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Text(activeRide.formattedElapsed)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.80))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
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

    // MARK: - Control buttons

    private var recentreButton: some View {
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
    }

    private var mapToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                displayMode = displayMode == .navigation ? .fullMap : .navigation
            }
        } label: {
            Image(systemName: displayMode == .navigation ? "map.fill" : "list.bullet.rectangle")
                .font(.system(size: 22))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(Color.black.opacity(0.75))
                .cornerRadius(28)
        }
    }

    private var endRideButton: some View {
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

    // MARK: - Bottom Controls (navigation mode)

    private var bottomControls: some View {
        HStack(spacing: 12) {
            recentreButton
            Spacer()
            mapToggleButton
            Spacer()
            endRideButton
        }
    }

    // MARK: - Ride lifecycle

    private func setupLocationCallback() {
        // Start location updates (heading already running from LocationService init)
        manager_startIfNeeded()

        locationService.onLocationUpdate = { location in
            DispatchQueue.main.async {
                // Feed the navigation engine
                Task { @MainActor in
                    navEngine.update(location: location)
                }

                // Record ride track and stats only while tracking
                if self.locationService.isTracking {
                    self.activeRide.recordedCoordinates.append(location.coordinate)
                    self.activeRide.distanceCoveredKm = self.locationService.totalDistanceKm
                    self.activeRide.currentSpeed      = location.speed > 0 ? location.speed * 3.6 : 0
                }

                // Keep map centred on user if follow mode is on
                if self.followsUser {
                    withAnimation {
                        self.cameraPosition = .region(MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                        ))
                    }
                }
            }
        }

        // Start the ride tracking
        locationService.startTracking()
    }

    /// Ensures location updates are running even if startTracking hasn't been called yet.
    private func manager_startIfNeeded() {
        // LocationService.shared already calls startUpdatingLocation on auth,
        // but we call it again here to be safe after view appears.
        if locationService.currentLocation == nil {
            locationService.requestPermission()
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
