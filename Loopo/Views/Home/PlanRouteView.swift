//
//  PlanRouteView.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//


import SwiftUI
import MapKit

struct PlanRouteView: View {
    @StateObject private var vm = RoutePlannerViewModel()
    @StateObject private var locationService = LocationService.shared
    @EnvironmentObject var appState: AppState
    
    @State private var showRouteResults = false
    @State private var showNavigation = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color("BackgroundDark").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        headerSection
                        
                        // Destination
                        destinationSection
                        
                        // Search results dropdown
                        if !vm.searchResults.isEmpty {
                            searchResultsList
                        }
                        
                        // Distance slider
                        distanceSection
                        
                        // Terrain picker
                        terrainSection
                        
                        // Generate button
                        generateButton
                        
                        // Error
                        if let err = vm.errorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal)
                        }
                        
                        // Route cards
                        if !vm.generatedRoutes.isEmpty {
                            routeResultsSection
                        }
                        
                        // Start ride button
                        if vm.selectedRoute != nil {
                            startRideButton
                        }
                        
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationDestination(isPresented: $showNavigation) {
                if let route = vm.selectedRoute {
                    NavigationRideView(route: route)
                        .environmentObject(appState)
                }
            }
        }
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("LOOPO")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .tracking(4)
                Text("plan your loop")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color("LoopGreen"))
                    .tracking(2)
            }
            Spacer()
            Image(systemName: "bicycle")
                .font(.system(size: 28))
                .foregroundColor(Color("LoopGreen"))
        }
        .padding(.top, 8)
    }
    
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("DESTINATION", systemImage: "mappin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color("LoopGreen"))
                .tracking(2)
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("e.g. Torquay", text: $vm.destinationText)
                    .foregroundColor(.white)
                    .onChange(of: vm.destinationText) { _, newValue in
                        vm.searchDestination(newValue)
                    }
                if vm.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(14)
            .background(Color("CardBackground"))
            .cornerRadius(12)
        }
    }
    
    private var searchResultsList: some View {
        VStack(spacing: 0) {
            ForEach(vm.searchResults.prefix(5), id: \.self) { item in
                Button {
                    vm.selectDestination(item)
                } label: {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(Color("LoopGreen"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "")
                                .foregroundColor(.white)
                                .font(.subheadline)
                            Text(item.placemark.title ?? "")
                                .foregroundColor(.gray)
                                .font(.caption)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                Divider().background(Color.gray.opacity(0.2))
            }
        }
        .background(Color("CardBackground"))
        .cornerRadius(12)
    }
    
    private var distanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("DISTANCE", systemImage: "ruler")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color("LoopGreen"))
                    .tracking(2)
                Spacer()
                Text(vm.distanceLabel)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            
            Slider(value: $vm.targetDistanceKm, in: 10...150, step: 5)
                .accentColor(Color("LoopGreen"))
            
            HStack {
                Text("10 km").font(.caption).foregroundColor(.gray)
                Spacer()
                Text("150 km").font(.caption).foregroundColor(.gray)
            }
        }
        .padding(16)
        .background(Color("CardBackground"))
        .cornerRadius(12)
    }
    
    private var terrainSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("TERRAIN", systemImage: "mountain.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color("LoopGreen"))
                .tracking(2)
            
            HStack(spacing: 8) {
                ForEach(TerrainProfile.allCases, id: \.self) { profile in
                    TerrainChip(profile: profile, isSelected: vm.selectedTerrain == profile) {
                        vm.selectedTerrain = profile
                    }
                }
            }
        }
        .padding(16)
        .background(Color("CardBackground"))
        .cornerRadius(12)
    }
    
    private var generateButton: some View {
        Button {
            Task {
                guard let loc = locationService.currentLocation?.coordinate else {
                    vm.errorMessage = "No location yet. GPS: \(locationService.authorizationStatus.rawValue)"
                    return
                }
                await vm.generateRoutes(from: loc)
            }
            
        } label: {
            HStack {
                if vm.isGenerating {
                    ProgressView().tint(.black)
                    Text("Generating loops...")
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Generate Loops")
                }
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(vm.isGenerating ? Color("LoopGreen").opacity(0.5) : Color("LoopGreen"))
            .cornerRadius(14)
        }
        .disabled(vm.isGenerating || vm.destinationCoordinate == nil)
    }
    
    private var routeResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SUGGESTED LOOPS", systemImage: "map")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color("LoopGreen"))
                .tracking(2)
            
            ForEach(vm.generatedRoutes) { route in
                RouteCard(
                    route: route,
                    isSelected: vm.selectedRoute?.id == route.id
                ) {
                    vm.selectedRoute = route
                }
            }
        }
    }
    
    private var startRideButton: some View {
        Button {
            showNavigation = true
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Start Ride")
            }
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                LinearGradient(
                    colors: [Color("LoopGreen"), Color("LoopGreen").opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(16)
        }
    }
}

// MARK: - Terrain Chip

struct TerrainChip: View {
    let profile: TerrainProfile
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: profile.icon)
                    .font(.system(size: 14))
                Text(profile.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .multilineTextAlignment(.center)
                Text(profile.description)
                    .font(.system(size: 8))
                    .foregroundColor(isSelected ? .black.opacity(0.6) : .gray)
            }
            .foregroundColor(isSelected ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? Color("LoopGreen") : Color.gray.opacity(0.15))
            .cornerRadius(10)
        }
    }
}

// MARK: - Route Card

struct RouteCard: View {
    let route: GeneratedRoute
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(route.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color("LoopGreen"))
                    }
                }
                
                HStack(spacing: 16) {
                    StatPill(icon: "arrow.triangle.2.circlepath", value: route.formattedDistance)
                    StatPill(icon: "arrow.up", value: route.formattedClimb)
                    StatPill(icon: "clock", value: route.formattedDuration)
                }
                
                // Mini map placeholder — replaced by MapKit snapshot in production
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 80)
                    .overlay(
                        Text("Map preview")
                            .font(.caption)
                            .foregroundColor(.gray)
                    )
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color("CardBackground"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? Color("LoopGreen") : Color.clear, lineWidth: 1.5)
                    )
            )
        }
    }
}

struct StatPill: View {
    let icon: String
    let value: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Color("LoopGreen"))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }
}
