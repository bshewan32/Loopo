import SwiftUI

struct RideSummaryView: View {
    let ride: SavedRide
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    // Pop all the way back to the plan screen
    @State private var popToRoot = false

    var body: some View {
        ZStack {
            Color("BackgroundDark").ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {

                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(Color("LoopGreen"))
                            .padding(.top, 32)
                        Text("Ride Complete")
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        Text(ride.routeName)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        Text(ride.formattedDate)
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.7))
                    }

                    // Main stats grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        SummaryStatCard(
                            label: "Distance",
                            value: String(format: "%.1f km", ride.distanceKm),
                            icon: "arrow.triangle.2.circlepath"
                        )
                        SummaryStatCard(
                            label: "Time",
                            value: ride.formattedDuration,
                            icon: "clock"
                        )
                        SummaryStatCard(
                            label: "Avg Speed",
                            value: String(format: "%.1f km/h", ride.averageSpeedKph),
                            icon: "speedometer"
                        )
                        SummaryStatCard(
                            label: "Climbing",
                            value: String(format: "%.0f m", ride.estimatedClimbM),
                            icon: "arrow.up"
                        )
                    }
                    .padding(.horizontal)

                    // Previous efforts comparison
                    previousEffortsSection

                    // Done button — goes back to Plan tab
                    Button {
                        // Dismiss twice to clear navigation + ride screen
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            dismiss()
                        }
                    } label: {
                        Text("Back to Plan")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color("LoopGreen"))
                            .cornerRadius(16)
                    }
                    .padding(.horizontal)

                    Spacer(minLength: 40)
                }
            }
        }
        .navigationBarHidden(true)
    }

    private var previousEffortsSection: some View {
        let sameRoute = appState.savedRides
            .filter { $0.routeName == ride.routeName && $0.id != ride.id }
            .prefix(3)

        return Group {
            if !sameRoute.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("PREVIOUS EFFORTS", systemImage: "chart.bar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color("LoopGreen"))
                        .tracking(2)
                        .padding(.horizontal)

                    ForEach(Array(sameRoute), id: \.id) { prev in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prev.formattedDate)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                Text(String(format: "%.1f km/h avg • %.1f km",
                                            prev.averageSpeedKph, prev.distanceKm))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            let delta = ride.averageSpeedKph - prev.averageSpeedKph
                            HStack(spacing: 3) {
                                Image(systemName: delta >= 0 ? "arrow.up" : "arrow.down")
                                Text(String(format: "%.1f km/h", abs(delta)))
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(delta >= 0 ? Color("LoopGreen") : .red)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color("CardBackground"))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct SummaryStatCard: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(Color("LoopGreen"))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color("CardBackground"))
        .cornerRadius(14)
    }
}
