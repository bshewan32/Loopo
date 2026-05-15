//
//  LocationService.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//

import CoreLocation
import Combine

class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let manager = CLLocationManager()

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var heading: CLHeading?

    // Ride tracking
    @Published var isTracking = false
    private var lastLocation: CLLocation?
    private(set) var totalDistanceKm: Double = 0

    /// Called on every location update regardless of tracking state.
    /// Used by NavigationRideView to keep the map camera following the user.
    var onLocationUpdate: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter  = 5   // update every 5 m
        manager.headingFilter   = 5   // update every 5 degrees
        manager.activityType    = .fitness
        manager.allowsBackgroundLocationUpdates    = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startTracking() {
        isTracking      = true
        totalDistanceKm = 0
        lastLocation    = nil
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopTracking() {
        isTracking = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Always update currentLocation so the map UserAnnotation and camera
        // follow the user even before a ride has been formally started.
        currentLocation = location

        // Always fire the callback — the view decides what to do with it.
        // Previously this was guarded by isTracking, which meant the map
        // camera never updated until startTracking() was called.
        onLocationUpdate?(location)

        // Accumulate distance only while a ride is in progress
        if isTracking {
            if let last = lastLocation {
                let delta = location.distance(from: last) / 1000.0
                if delta < 0.5 { // ignore GPS jumps > 500 m
                    totalDistanceKm += delta
                }
            }
            lastLocation = location
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }
}
