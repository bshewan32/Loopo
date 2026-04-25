import SwiftUI
import MapKit

struct NavigationRideView: View {
    let route: GeneratedRoute
    @EnvironmentObject var appState: AppState
    @StateObject private var locationService = LocationService.shared
    @StateObject private var activeRide: ActiveRide

    @State private var showEndConfirm = false
    @State private var rideFinished = false
    @State private var savedRide: SavedRide?
    @State private var cameraPosition: MapCameraPosition = .automatic

    @Environment(\.dismiss) var dismiss

    init(route: GeneratedRoute) {
        self.route = route
        _activeRide = StateObject(wrappedValue: ActiveRide(route: route))
    }

    var body: some View {
        ZStack {
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

            VStack {
                rideStatsBar
                    .padding(.top, 60)
                    .padding(.horizontal)
                Spacer()
                bottomControls
                    .padding(.bottom, 40)
                    .padding(.horizontal)
            }
        }
        .navigationBarHidden(true)
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

    private var rideStatsBar: some View {
        HStack(spacing: 0) {
            RideStatCell(label: "TIME", value: activeRide.formattedElapsed)
            Divider().background(Color.white.opacity(0.1)).frame(height: 40)
            RideStatCell(label: "KM", value: String(format: "%.1f", locationService.totalDistanceKm))
            Divider().background(Color.white.opacity(0.1)).frame(height: 40)
            RideStatCell(label: "km/h", value: String(format: "%.1f", activeRide.averageSpeedKph))
        }
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }

    private var bottomControls: some View {
        HStack(spacing: 16) {
            Button {
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

    private func startRide() {
        locationService.startTracking()
        locationService.onLocationUpdate = { location in
            DispatchQueue.main.async {
                activeRide.recordedCoordinates.append(location.coordinate)
                activeRide.distanceCoveredKm = locationService.totalDistanceKm
                activeRide.currentSpeed = location.speed > 0 ? location.speed * 3.6 : 0
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
        savedRide = ride
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
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
    }
}

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
