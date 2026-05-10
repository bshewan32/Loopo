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
                // Stats bar
                rideStatsBar
                    .padding(.top, 60)
                    .padding(.horizontal)

                // Instruction banner
                if !navEngine.hasArrived {
                    instructionBanner
                        .padding(.top, 12)
                        .padding(.horizontal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Off-route warning
                if navEngine.isOffRoute {
                    offRouteBanner
                        .padding(.top, 8)
                        .padding(.horizontal)
                        .transition(.opacity)
                }

                // Arrival banner
                if navEngine.hasArrived {
                    arrivalBanner
                        .padding(.top, 12)
                        .padding(.horizontal)
                        .transition(.scale.combined(with: .opacity))
                }

                Spacer()

                // Bottom controls
                bottomControls
                    .padding(.bottom, 40)
                    .padding(.horizontal)
            }
        }
        .navigationBarHidden(true)
        .animation(.easeInOut(duration: 0.3), value: navEngine.currentInstruction?.id)
        .animation(.easeInOut(duration: 0.3), value: navEngine.isOffRoute)
        .animation(.easeInOut(duration: 0.3), value: navEngine.hasArrived)
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

    // MARK: - Instruction Banner

    private var instructionBanner: some View {
        HStack(spacing: 14) {
            // Direction arrow
            ZStack {
                Circle()
                    .fill(Color("LoopGreen"))
                    .frame(width: 52, height: 52)
                Image(systemName: navEngine.currentInstruction?.symbolName ?? "arrow.up")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.black)
            }

            // Text block
            VStack(alignment: .leading, spacing: 2) {
                Text(distanceLabel)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text(navEngine.currentInstruction?.text ?? "Follow the route")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
                if let street = navEngine.currentInstruction?.streetName, !street.isEmpty {
                    Text(street)
                        .font(.system(size: 11))
                        .foregroundColor(Color("LoopGreen"))
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }

    /// Shows the live distance to the next manoeuvre, pulsing red when imminent.
    private var distanceLabel: String {
        let d = navEngine.distanceToNextM
        if d >= 1000 { return String(format: "%.1f km", d / 1000) }
        return String(format: "%.0f m", d)
    }

    // MARK: - Off-Route Banner

    private var offRouteBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Off route — return to the green line")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.25))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    // MARK: - Arrival Banner

    private var arrivalBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 28))
                .foregroundColor(Color("LoopGreen"))
            VStack(alignment: .leading, spacing: 2) {
                Text("You've arrived!")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text("Great ride. Tap End Ride to save.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }

    // MARK: - Stats Bar

    private var rideStatsBar: some View {
        HStack(spacing: 0) {
            RideStatCell(label: "TIME", value: activeRide.formattedElapsed)
            Divider().background(Color.white.opacity(0.1)).frame(height: 40)
            RideStatCell(label: "KM",   value: String(format: "%.1f", locationService.totalDistanceKm))
            Divider().background(Color.white.opacity(0.1)).frame(height: 40)
            RideStatCell(label: "km/h", value: String(format: "%.1f", activeRide.averageSpeedKph))
        }
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
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
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial)
                    .cornerRadius(26)
            }

            Spacer()

            // End ride
            Button {
                showEndConfirm = true
            } label: {
                HStack {
                    Image(systemName: "stop.circle.fill")
                    Text("End Ride")
                        .fontWeight(.bold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(Color.red.opacity(0.85))
                .cornerRadius(30)
            }
        }
    }

    // MARK: - Ride lifecycle

    private func startRide() {
        locationService.startTracking()
        locationService.onLocationUpdate = { location in
            DispatchQueue.main.async {
                // Feed the navigation engine first
                Task { @MainActor in
                    navEngine.update(location: location)
                }
                // Record the ride track
                activeRide.recordedCoordinates.append(location.coordinate)
                activeRide.distanceCoveredKm = locationService.totalDistanceKm
                activeRide.currentSpeed      = location.speed > 0 ? location.speed * 3.6 : 0

                // Keep map centred on user if follow mode is on
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

// MARK: - Stat Cell (unchanged)

struct RideStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.gray)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
    }
}
