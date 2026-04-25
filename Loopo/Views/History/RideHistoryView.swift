//
//  RideHistoryView.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//


import SwiftUI

struct RideHistoryView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color("BackgroundDark").ignoresSafeArea()
                
                if appState.savedRides.isEmpty {
                    emptyState
                } else {
                    rideList
                }
            }
            .navigationTitle("My Rides")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bicycle")
                .font(.system(size: 56))
                .foregroundColor(.gray)
            Text("No rides yet")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text("Plan your first loop and get out there.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    private var rideList: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Summary banner
                totalsSummaryBanner
                    .padding(.horizontal)
                
                ForEach(appState.savedRides) { ride in
                    RideHistoryCard(ride: ride)
                        .padding(.horizontal)
                }
                
                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
    }
    
    private var totalsSummaryBanner: some View {
        HStack(spacing: 0) {
            TotalStat(label: "Rides", value: "\(appState.savedRides.count)")
            Divider().background(Color.white.opacity(0.1)).frame(height: 36)
            TotalStat(label: "Total km", value: String(format: "%.0f", appState.savedRides.reduce(0) { $0 + $1.distanceKm }))
            Divider().background(Color.white.opacity(0.1)).frame(height: 36)
            TotalStat(label: "Total climb", value: String(format: "%.0fm", appState.savedRides.reduce(0) { $0 + $1.estimatedClimbM }))
        }
        .padding(.vertical, 14)
        .background(Color("CardBackground"))
        .cornerRadius(14)
    }
}

struct TotalStat: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Color("LoopGreen"))
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

struct RideHistoryCard: View {
    let ride: SavedRide
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ride.routeName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text(ride.formattedDate)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
                Text(ride.terrain.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color("LoopGreen"))
                    .cornerRadius(6)
            }
            
            HStack(spacing: 16) {
                StatPill(icon: "arrow.triangle.2.circlepath", value: String(format: "%.1f km", ride.distanceKm))
                StatPill(icon: "clock", value: ride.formattedDuration)
                StatPill(icon: "speedometer", value: String(format: "%.1f km/h", ride.averageSpeedKph))
            }
        }
        .padding(14)
        .background(Color("CardBackground"))
        .cornerRadius(14)
    }
}