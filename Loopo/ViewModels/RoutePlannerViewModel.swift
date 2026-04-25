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
    @Published var destinationText: String = ""
    @Published var destinationCoordinate: CLLocationCoordinate2D?
    @Published var destinationName: String = ""
    @Published var targetDistanceKm: Double = 60
    @Published var selectedTerrain: TerrainProfile = .mostlyFlat
    
    // MARK: - Generated routes
    @Published var generatedRoutes: [GeneratedRoute] = []
    @Published var selectedRoute: GeneratedRoute?
    
    // MARK: - UI state
    @Published var isGenerating: Bool = false
    @Published var errorMessage: String?
    @Published var searchResults: [MKMapItem] = []
    @Published var isSearching: Bool = false
    
    private var searchTask: Task<Void, Never>?
    
    // MARK: - Destination search
    
    func searchDestination(_ query: String) {
        guard query.count > 2 else {
            searchResults = []
            return
        }
        
        searchTask?.cancel()
        searchTask = Task {
            isSearching = true
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            
            // Bias to Geelong / Victoria region
            let center = CLLocationCoordinate2D(latitude: -38.1499, longitude: 144.3617)
            let span   = MKCoordinateSpan(latitudeDelta: 3.0, longitudeDelta: 3.0)
            request.region = MKCoordinateRegion(center: center, span: span)
            
            let search = MKLocalSearch(request: request)
            if let response = try? await search.start() {
                if !Task.isCancelled {
                    searchResults = response.mapItems
                    isSearching = false
                }
            } else {
                isSearching = false
            }
        }
    }
    
    func selectDestination(_ mapItem: MKMapItem) {
        destinationCoordinate = mapItem.placemark.coordinate
        destinationName = mapItem.name ?? mapItem.placemark.title ?? "Destination"
        destinationText = destinationName
        searchResults = []
    }
    
    // MARK: - Route generation
    
    func generateRoutes(from userLocation: CLLocationCoordinate2D) async {
        guard let destination = destinationCoordinate else {
            errorMessage = "Please select a destination first."
            return
        }
        
        isGenerating = true
        errorMessage = nil
        generatedRoutes = []
        selectedRoute = nil
        
        do {
            let routes = try await RouteGenerationService.shared.generateRoutes(
                from: userLocation,
                destination: destination,
                targetDistanceKm: targetDistanceKm,
                terrain: selectedTerrain
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