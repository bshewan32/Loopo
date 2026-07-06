//
//  NavigationRideView.swift
//  iLoop
//
//  Two fully distinct full-screen modes:
//
//  NAV MODE  — no map at all. Full black screen. Giant direction arrow fills the
//              top half. Street name and distance in huge type. Running time/km
//              pill in the corner. One small switch-to-map button. Tiny stop button.
//
//  MAP MODE  — full-screen map, nothing on top of it except a thin compact HUD
//              strip at the very top and three small buttons at the bottom:
//              re-centre, zoom-close/zoom-out toggle, and switch-to-nav.
//              Stop button is 1/4 the size of the other buttons.
//

import SwiftUI
import MapKit

// MARK: - Display mode

private enum DisplayMode {
    case nav    // pure navigation — no map
    case map    // pure map — minimal chrome
}

// MARK: - Direction chevron annotation

struct DirectionChevron: Identifiable {
    let id      = UUID()
    let coord:   CLLocationCoordinate2D
    let bearing: Double   // degrees, 0 = north
}

// MARK: - Main View

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
    @State private var headingUp       = true
    @State private var displayMode: DisplayMode = .nav
    @State private var imminentPulse   = false
    @State private var mapZoomedClose  = true    // true = 300 m, false = 2 km

    @State private var chevrons: [DirectionChevron] = []

    @Environment(\.dismiss) var dismiss

    init(route: GeneratedRoute) {
        self.route  = route
        _activeRide = StateObject(wrappedValue: ActiveRide(route: route))
        _navEngine  = StateObject(wrappedValue: NavigationEngine(route: route))
    }

    // MARK: - Body

    var body: some View {
        Group {
            switch displayMode {
            case .nav:
                navScreen
            case .map:
                mapScreen
            }
        }
        .navigationBarHidden(true)
        .animation(.easeInOut(duration: 0.35), value: displayMode)
        .animation(.easeInOut(duration: 0.25), value: navEngine.currentInstruction?.id)
        .animation(.easeInOut(duration: 0.25), value: navEngine.isOnLoop)
        .animation(.easeInOut(duration: 0.25), value: navEngine.hasArrived)
        .onChange(of: navEngine.distanceToNextM) { _, dist in
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
                RideSummaryView(ride: ride).environmentObject(appState)
            }
        }
        .onAppear {
            setupLocationCallback()
            if let loc = locationService.currentLocation {
                updateCameraForLocation(loc)
            } else {
                cameraPosition = .rect(route.polyline.boundingMapRect)
            }
            chevrons = buildChevrons(from: route.polyline)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - NAV SCREEN
    // Full black screen. No map. Giant arrow + text.
    // ─────────────────────────────────────────────────────────────────────────

    private var navScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Running stats pill (top-right corner) ────────────────
                HStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Label(activeRide.formattedElapsed,
                              systemImage: "clock")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                        Label(String(format: "%.1f km", locationService.totalDistanceKm),
                              systemImage: "bicycle")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(20)
                }
                .padding(.top, 56)
                .padding(.horizontal, 20)

                Spacer()

                // ── Main instruction area ─────────────────────────────────
                if navEngine.hasArrived {
                    navArrivalContent
                } else if !navEngine.isOnLoop {
                    navNDBContent
                } else {
                    navTurnContent
                }

                Spacer()

                // ── Off-route warning ─────────────────────────────────────
                if navEngine.isOnLoop && navEngine.isOffRoute {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Off route — return to the green line")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.25))
                    .transition(.opacity)
                }

                // ── Bottom bar: map toggle + stop ─────────────────────────
                HStack(alignment: .center, spacing: 0) {
                    // Switch to map
                    Button {
                        withAnimation { displayMode = .map }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(.white)
                            Text("MAP")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.6))
                                .tracking(1.5)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    }

                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 44)

                    // Stop — deliberately small and unobtrusive
                    Button {
                        showEndConfirm = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.red.opacity(0.7))
                            Text("STOP")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.red.opacity(0.5))
                                .tracking(1.5)
                        }
                        .frame(width: 80)
                        .padding(.vertical, 18)
                    }
                }
                .background(Color.white.opacity(0.06))
                .padding(.bottom, 0)
            }
        }
    }

    // ── Turn instruction content ──────────────────────────────────────────────

    private var navTurnContent: some View {
        VStack(spacing: 0) {

            // Giant direction arrow — fills most of the vertical space
            ZStack {
                // Coloured background circle
                Circle()
                    .fill(imminentPulse
                          ? Color.red.opacity(0.18)
                          : Color("LoopGreen").opacity(0.12))
                    .frame(width: 220, height: 220)

                Image(systemName: navEngine.currentInstruction?.symbolName ?? "arrow.up")
                    .font(.system(size: 110, weight: .black))
                    .foregroundColor(imminentPulse ? .red : Color("LoopGreen"))
                    .scaleEffect(imminentPulse ? 1.06 : 1.0)
            }
            .padding(.bottom, 28)

            // Distance to turn
            Text(distanceLabel)
                .font(.system(size: 72, weight: .black, design: .rounded))
                .foregroundColor(imminentPulse ? .red : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 24)

            // Instruction verb
            Text(navEngine.currentInstruction?.text ?? "Follow the route")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 24)
                .padding(.top, 6)

            // Street name
            if let street = navEngine.currentInstruction?.streetName, !street.isEmpty {
                Text(street)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color("LoopGreen"))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
        }
    }

    // ── NDB approach content ──────────────────────────────────────────────────

    private var navNDBContent: some View {
        VStack(spacing: 0) {

            // Big rotating NDB arrow
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 220, height: 220)

                Image(systemName: "location.north.fill")
                    .font(.system(size: 110, weight: .black))
                    .foregroundColor(.blue)
                    .rotationEffect(.degrees(relativeNDBBearing))
            }
            .padding(.bottom, 28)

            Text(loopDistanceLabel)
                .font(.system(size: 72, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 24)

            Text("Ride toward the loop")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 6)

            Text("Turn-by-turn starts automatically")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.blue.opacity(0.8))
                .padding(.top, 4)
        }
    }

    // ── Arrival content ───────────────────────────────────────────────────────

    private var navArrivalContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 100, weight: .black))
                .foregroundColor(Color("LoopGreen"))

            Text("You've arrived!")
                .font(.system(size: 48, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text("Great ride. Tap Stop to save.")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - MAP SCREEN
    // Full-screen map. Thin HUD strip at top. Three small buttons at bottom.
    // ─────────────────────────────────────────────────────────────────────────

    private var mapScreen: some View {
        ZStack {

            // ── Full-screen map ───────────────────────────────────────────
            Map(position: $cameraPosition) {
                MapPolyline(route.polyline)
                    .stroke(Color("LoopGreen"), lineWidth: 4)

                ForEach(chevrons) { chevron in
                    Annotation("", coordinate: chevron.coord) {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(Color("LoopGreen"))
                            .rotationEffect(.degrees(
                                chevron.bearing - 90 + (navEngine.travellingReversed ? 180 : 0)
                            ))
                            .shadow(color: .black.opacity(0.6), radius: 1)
                    }
                }

                UserAnnotation()
            }
            .ignoresSafeArea()
            .onTapGesture { followsUser = false }

            // ── Compact HUD strip at top ──────────────────────────────────
            VStack {
                mapHUDStrip
                    .padding(.top, 52)
                    .padding(.horizontal, 12)

                Spacer()

                // ── Bottom buttons ────────────────────────────────────────
                mapBottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 36)
            }
        }
    }

    // ── Map HUD strip (minimal — just next turn + stats) ─────────────────────

    private var mapHUDStrip: some View {
        HStack(spacing: 10) {
            // Direction icon
            ZStack {
                Circle()
                    .fill(navEngine.isOnLoop ? Color("LoopGreen") : Color.blue)
                    .frame(width: 40, height: 40)
                Image(systemName: navEngine.isOnLoop
                      ? (navEngine.currentInstruction?.symbolName ?? "arrow.up")
                      : "location.north.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundColor(navEngine.isOnLoop ? .black : .white)
                    .rotationEffect(navEngine.isOnLoop ? .zero : .degrees(relativeNDBBearing))
            }

            // Distance / instruction
            VStack(alignment: .leading, spacing: 1) {
                if navEngine.isOnLoop {
                    Text(distanceLabel)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text(navEngine.currentInstruction?.text ?? "Follow the route")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                } else {
                    Text(loopDistanceLabel)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text("Ride toward the loop")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                }
            }

            Spacer()

            // Time + distance
            VStack(alignment: .trailing, spacing: 1) {
                Text(activeRide.formattedElapsed)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(String(format: "%.1f km", locationService.totalDistanceKm))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.78))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
    }

    // ── Map bottom bar ────────────────────────────────────────────────────────
    // Three equal-size buttons + one tiny stop button

    private var mapBottomBar: some View {
        HStack(spacing: 12) {

            // Re-centre
            mapButton(icon: "location.fill", color: followsUser ? Color("LoopGreen") : .white) {
                followsUser = true
                zoomToUserLocation()
            }

            // Zoom toggle: close (300 m) ↔ overview (~2 km)
            mapButton(icon: mapZoomedClose ? "minus.magnifyingglass" : "plus.magnifyingglass",
                      color: .white) {
                mapZoomedClose.toggle()
                zoomToUserLocation()
            }

            // Heading toggle
            mapButton(icon: headingUp ? "location.north.line.fill" : "arrow.up",
                      color: headingUp ? Color("LoopGreen") : .white) {
                headingUp.toggle()
                zoomToUserLocation()
            }

            // Switch to nav screen
            mapButton(icon: "arrow.turn.up.right", color: .white) {
                withAnimation { displayMode = .nav }
            }

            // Stop — deliberately tiny
            Button {
                showEndConfirm = true
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.70))
                    .cornerRadius(16)
            }
        }
    }

    @ViewBuilder
    private func mapButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 54, height: 54)
                .background(Color.black.opacity(0.75))
                .cornerRadius(27)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ─────────────────────────────────────────────────────────────────────────

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

    private var distanceLabel: String {
        let d = navEngine.distanceToNextM
        if d >= 1000 { return String(format: "%.1f km", d / 1000) }
        return String(format: "%.0f m", d)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Location & Camera
    // ─────────────────────────────────────────────────────────────────────────

    private func setupLocationCallback() {
        if locationService.currentLocation == nil {
            locationService.requestPermission()
        }

        locationService.onLocationUpdate = { location in
            DispatchQueue.main.async {
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

    private func updateCameraForLocation(_ location: CLLocation) {
        // Only update the camera when in map mode — no map in nav mode.
        guard displayMode == .map else { return }

        let heading: Double
        if headingUp {
            heading = location.course >= 0 ? location.course : (locationService.heading?.trueHeading ?? 0)
        } else {
            heading = 0
        }

        // Distance: 300 m when zoomed close, 2000 m for overview
        let distance: Double = mapZoomedClose ? 300 : 2000

        withAnimation(.linear(duration: 0.2)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: location.coordinate,
                distance: distance,
                heading: heading,
                pitch: 0
            ))
        }
    }

    private func zoomToUserLocation() {
        guard let loc = locationService.currentLocation else { return }
        updateCameraForLocation(loc)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Ride lifecycle
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Direction chevron builder
    // ─────────────────────────────────────────────────────────────────────────

    private func buildChevrons(from polyline: MKPolyline) -> [DirectionChevron] {
        let count = polyline.pointCount
        guard count >= 2 else { return [] }

        var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))

        var cumDist = [Double](repeating: 0, count: count)
        for i in 1..<count {
            let a = CLLocation(latitude: coords[i-1].latitude, longitude: coords[i-1].longitude)
            let b = CLLocation(latitude: coords[i].latitude,   longitude: coords[i].longitude)
            cumDist[i] = cumDist[i-1] + a.distance(from: b)
        }

        let totalDist = cumDist.last ?? 0
        guard totalDist > 0 else { return [] }

        let spacing  = max(300.0, totalDist / 20)
        var chevrons = [DirectionChevron]()
        var nextDist = spacing / 2

        while nextDist < totalDist - spacing / 2 {
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

    private func bearingBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude  * .pi / 180
        let lat2 = b.latitude  * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - Stat Cell (kept for any future use)

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
