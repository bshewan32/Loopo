//
//  AppState.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//


import SwiftUI
import Combine
import CoreLocation

class AppState: ObservableObject {
    @Published var savedRides: [SavedRide] = []
    @Published var activeRide: ActiveRide?
    @Published var isNavigating: Bool = false
    
    init() {
        loadRides()
    }
    
    func saveRide(_ ride: SavedRide) {
        savedRides.insert(ride, at: 0)
        persistRides()
    }
    
    private func persistRides() {
        if let encoded = try? JSONEncoder().encode(savedRides) {
            UserDefaults.standard.set(encoded, forKey: "saved_rides")
        }
    }
    
    private func loadRides() {
        if let data = UserDefaults.standard.data(forKey: "saved_rides"),
           let decoded = try? JSONDecoder().decode([SavedRide].self, from: data) {
            savedRides = decoded
        }
    }
}
