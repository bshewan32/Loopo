//
//  RoutePlannerViewModel.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//

import Foundation
import CoreLocation
import MapKit
import Combine

@MainActor
class RoutePlannerViewModel: ObservableObject {
    
    // MARK: - User inputs
    @Published var targetDistanceKm: Double = 60
    @Published var selectedTerrain: TerrainProfile = .mostlyFlat
    @Published var selectedDirection: RouteDirection = .any
    
    // MARK: - Generated routes
    @Published var generatedRoutes: [GeneratedRoute] = []
    @Published var selectedRoute: GeneratedRoute?
    
    // MARK: - UI state
    @Published var isGenerating: Bool = false
    @Published var errorMessage: String?
    
    // MARK: - Route generation
    
    func generateRoutes(from userLocation: CLLocationCoordinate2D) async {
        isGenerating = true
        errorMessage = nil
        generatedRoutes = []
        selectedRoute = nil
        
        do {
            let routes = try await RouteGenerationService.shared.generateRoutes(
                from: userLocation,
                targetDistanceKm: targetDistanceKm,
                terrain: selectedTerrain,
                heading: selectedDirection.heading
            )
            generatedRoutes = routes
            selectedRoute   = routes.first
        } catch {
            errorMessage = "Couldn't generate routes. Check your connection and try again."
        }
        
        isGenerating = false
    }
    
    // MARK: - Helpers
    
    var distanceLabel: String {
        String(format: "%.0f km", targetDistanceKm)
    }
}

// MARK: - Route Direction

enum RouteDirection: String, CaseIterable, Identifiable {
    case any = "Any"
    case north = "North"
    case east = "East"
    case south = "South"
    case west = "West"
    
    var id: String { self.rawValue }
    
    var heading: Double? {
        switch self {
        case .any: return nil
        case .north: return 0
        case .east: return 90
        case .south: return 180
        case .west: return 270
        }
    }
    
    var icon: String {
        switch self {
        case .any: return "arrow.up.and.down.and.arrow.left.and.right"
        case .north: return "arrow.up"
        case .east: return "arrow.right"
        case .south: return "arrow.down"
        case .west: return "arrow.left"
        }
    }
}

