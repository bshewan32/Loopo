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
    case navigation   // instruction banner + stats bar visible
    case fullMap      // map fills screen, compact HUD only
}

// MARK: - Direction chevron annotation

/// A lightweight annotation placed at regular intervals along the route polyline
/// to indicate direction of travel. Each one stores the bearing of the segment
/// so the chevron icon can be rotated to point the right way.
struct DirectionChevron: Identifiable {
    let id    = UUID()
    let coord: CLLocationCoordinate2D
    let bearing: Double   // degrees, 0 = north
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
    @State private var headingUp       = true     // heading-up vs north-up toggle
    @State private var displayMode: DisplayMode = .navigation
    @State private var imminentPulse   = false

    /// Direction chevrons computed once from the route polyline.
    @State private var chevrons: [DirectionChevron] = []

    @Environment(\.dismiss) var dismiss

    init(route: GeneratedRoute) {
        self.route  = route
        _activeRide = StateObject(wrappedValue: ActiveRide(route: route))
        _navEngine  = StateObject(wrappedValue: NavigationEngine(route: route))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── Full-screen map ──────────────────────────────────────────
            Map(position: $cameraPosition) {

                // Route polyline
                MapPolyline(route.polyline)
                    .stroke(Color("LoopGreen"), lineWidth: 4)

                // Direction-of-travel chevrons
                // When the engine detects the rider is going the opposite way
                // around the loop, travellingReversed flips the bearing by 180°
                // so the arrows always show the actual direction of travel.
                ForEach(chevrons) { chevron in
                    Annotation("", coordinate: chevron.coord) {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(Color("LoopGreen"))
                            .rotationEffect(.degrees(
                                chevron.bearing - 90 + (navEngine.travellingReversed ? 180 : 0)
                            ))
                            .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 0)
                    }
                }

                // User dot
                UserAnnotation()
            }
            .ignoresSafeArea()
            .onAppear {
                setupLocationCallback()
                // Zoom to user location at a comfortable cycling scale rather
                // than fitting the full route bounds. For a 150 km route,
                // fitting the whole polyline loads a huge tile area and makes
                // the initial view useless. The route polyline is still visible
                // as you ride — the re-centre button snaps back to it any time.
                if let loc = locationService.currentLocation {
                    updateCameraForLocation(loc)
                } else {
                    zoomToRoute()   // fallback if location not yet available
                }
                chevrons = buildChevrons(from: route.polyline)
            }
            .onTapGesture {
                followsUser = false
            }

            // ── Overlays ─────────────────────────────────────────────────
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

    // MARK: - Navigation mode overlay

    private var navigationModeOverlay: some View {
        VStack(spacing: 0) {
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

    private var fullMapModeOverlay: some View {
        VStack(spacing: 0) {
            compactHUD
                .padding(.horizontal, 12)
                .padding(.top, 56)

            Spacer()

            HStack(spacing: 12) {
                recentreButton
                Spacer()
                headingToggleButton
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

    private var ndbApproachBanner: some View {
        HStack(alignment: .center, spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(Color.blue.opacity(0.85))
                    .frame(width: 100)
                VStack(spacing: 4) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 44, weight: .black))
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(relativeNDBBearing))
                    Text("TO LOOP")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.white.opacity(0.7))
                        .tracking(1.5)
                }
            }
            .frame(maxHeight: .infinity)

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

    private var relativeNDBBearing: Double {
        let absolute   = navEngine.bearingToLoopDeg
        let deviceTrue = locationService.heading?.trueHeading ?? 0
        return (absolute - deviceTrue + 360).truncatingRemainder(dividingBy: 360)
    }

    private var loopDistanceLabel: String {
        let d = navEngine.distanceToLoopM
        if d >= 1000 { return String(format: "%.1f km", d / 1000) }
        return String(format: "%.0f m", d)
    }

    // MARK: - Instruction Banner

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
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.7), lineWidth: 1.5))
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

    // MARK: - Control Buttons

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

    /// Toggles between heading-up and north-up map orientation.
    private var headingToggleButton: some View {
        Button {
            headingUp.toggle()
            // Re-centre with the new orientation
            zoomToUserLocation()
        } label: {
            Image(systemName: headingUp ? "location.north.line.fill" : "arrow.up")
                .font(.system(size: 22))
                .foregroundColor(headingUp ? Color("LoopGreen") : .white)
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
                Image(systemName: "stop.circle.fill").font(.system(size: 18))
                Text("End Ride").font(.system(size: 17, weight: .bold))
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
            headingToggleButton
            Spacer()
            mapToggleButton
            Spacer()
            endRideButton
        }
    }

    // MARK: - Ride lifecycle

    private func setupLocationCallback() {
        if locationService.currentLocation == nil {
            locationService.requestPermission()
        }

        locationService.onLocationUpdate = { location in
            DispatchQueue.main.async {
                // navEngine.update dispatches its own geometry work to a
                // background queue internally — no need to wrap in Task here.
                navEngine.update(location: location)

                if self.locationService.isTracking {
                    self.activeRide.recordedCoordinates.append(location.coordinate)
                    self.activeRide.distanceCoveredKm = self.locationService.totalDistanceKm
                    self.activeRide.currentSpeed      = location.speed > 0 ? location.speed * 3.6 : 0
                }

                if self.followsUser {
                    self.updateCameraForLocation(location)
                }
            }
        }

        locationService.startTracking()
    }

    /// Updates the map camera position, applying heading-up rotation when enabled.
    ///
    /// SwiftUI's MapKit `MapCameraPosition` does not yet expose a direct heading
    /// property on `.region`. Instead we use `.camera` with `MapCamera` which
    /// accepts a `heading` parameter (degrees, 0 = north).
    private func updateCameraForLocation(_ location: CLLocation) {
        let center = location.coordinate
        let heading: Double

        if headingUp {
            // Prefer the GPS course (direction of movement) over the compass heading.
            // course is -1 when unavailable (stationary), fall back to compass.
            if location.course >= 0 {
                heading = location.course
            } else {
                heading = locationService.heading?.trueHeading ?? 0
            }
        } else {
            heading = 0   // north-up
        }

        withAnimation(.linear(duration: 0.2)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: center,
                distance: 500,          // ~500 m view radius — good for cycling
                heading: heading,
                pitch: 0
            ))
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
        guard let loc = locationService.currentLocation else { return }
        updateCameraForLocation(loc)
    }

    // MARK: - Direction chevron builder

    /// Samples the route polyline at regular intervals and computes the bearing
    /// of each segment, returning a `DirectionChevron` for each sample point.
    ///
    /// Spacing is adaptive: ~every 200 m for short routes, ~every 500 m for long ones.
    private func buildChevrons(from polyline: MKPolyline) -> [DirectionChevron] {
        let count = polyline.pointCount
        guard count >= 2 else { return [] }

        var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))

        // Compute cumulative distances along the polyline
        var cumDist = [Double](repeating: 0, count: count)
        for i in 1..<count {
            let a = CLLocation(latitude: coords[i-1].latitude, longitude: coords[i-1].longitude)
            let b = CLLocation(latitude: coords[i].latitude,   longitude: coords[i].longitude)
            cumDist[i] = cumDist[i-1] + a.distance(from: b)
        }

        let totalDist = cumDist.last ?? 0
        guard totalDist > 0 else { return [] }

        // Place chevrons every ~300 m, but at least 4 and at most 20
        let spacing  = max(300.0, totalDist / 20)
        var chevrons = [DirectionChevron]()
        var nextDist = spacing / 2   // start half a spacing in so first chevron isn't at the very start

        while nextDist < totalDist - spacing / 2 {
            // Find the coordinate at `nextDist` along the polyline
            if let idx = cumDist.firstIndex(where: { $0 >= nextDist }), idx > 0 {
                let coord   = coords[idx]
                let prev    = coords[idx - 1]
                let bearing = bearingBetween(prev, coord)
                chevrons.append(DirectionChevron(coord: coord, bearing: bearing))
            }
            nextDist += spacing
        }

        return chevrons
    }

    /// Bearing in degrees (0–360) from `a` to `b`.
    private func bearingBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude  * .pi / 180
        let lat2 = b.latitude  * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
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
