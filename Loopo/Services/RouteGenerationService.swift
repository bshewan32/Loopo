import Foundation
import CoreLocation
import MapKit

class RouteGenerationService {

    static let shared = RouteGenerationService()

    // MARK: - Public entry point

    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        targetDistanceKm: Double,
        terrain: TerrainProfile
    ) async throws -> [GeneratedRoute] {

        let candidateSets = buildCandidateWaypoints(
            origin: origin,
            destination: destination,
            targetDistanceKm: targetDistanceKm
        )

        var routes: [GeneratedRoute] = []
        
        // Try all candidates, not just until we get 3
        for (idx, waypointSet) in candidateSets.enumerated() {
            print("🔄 Trying candidate set \(idx) with \(waypointSet.count) waypoints...")
            
            do {
                if let route = try await requestLoop(
                    origin: origin,
                    waypoints: waypointSet,
                    targetDistanceKm: targetDistanceKm,
                    terrain: terrain,
                    index: routes.count
                ) {
                    let distanceDiff = abs(route.distanceKm - targetDistanceKm)
                    let percentOff = (distanceDiff / targetDistanceKm) * 100
                    print("✅ Candidate \(idx) produced route: \(String(format: "%.1f", route.distanceKm))km (\(String(format: "%.0f", percentOff))% off target)")
                    routes.append(route)
                }
            } catch {
                print("❌ Candidate \(idx) failed: \(error.localizedDescription)")
            }
        }

        print("📍 Total routes generated: \(routes.count)")
        
        guard !routes.isEmpty else {
            throw NSError(domain: "RouteGeneration", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Could not generate any valid routes. Try a different destination or shorter distance."])
        }

        // Score and return top 3 routes that best match the target
        let scored = routes.sorted {
            scoreRoute($0, target: targetDistanceKm, terrain: terrain)
          > scoreRoute($1, target: targetDistanceKm, terrain: terrain)
        }
        
        return Array(scored.prefix(min(3, scored.count)))
    }

    // MARK: - Waypoint generation

    private func buildCandidateWaypoints(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        targetDistanceKm: Double
    ) -> [[CLLocationCoordinate2D]] {

        let bearing = bearingBetween(origin, destination)
        let directDist = distanceBetween(origin, destination) / 1000.0 // one-way distance in km
        let loopDist = directDist * 2 // there-and-back distance
        
        print("📐 Origin: \(origin.latitude),\(origin.longitude)")
        print("📐 Destination: \(destination.latitude),\(destination.longitude)")
        print("📐 Target Distance: \(String(format: "%.1f", targetDistanceKm))km")
        print("📐 Direct there-and-back: \(String(format: "%.1f", loopDist))km")
        
        // Calculate the "reasonableness ratio"
        // 1.0 = perfect match, <0.5 = dest too close, >2.0 = dest too far
        let ratio = loopDist / targetDistanceKm
        
        print("📐 Loop ratio: \(String(format: "%.2f", ratio)) (\(getLoopStrategy(ratio: ratio)))")
        
        // Choose strategy based on ratio
        if ratio >= 0.7 && ratio <= 1.3 {
            // IDEAL: Destination is perfect for target distance
            return buildDestinationFocusedLoops(origin: origin, destination: destination, 
                                                bearing: bearing, targetDistanceKm: targetDistanceKm,
                                                loopDist: loopDist)
        } else if ratio < 0.7 {
            // TOO CLOSE: Need to create wider loops that happen to pass near destination
            return buildWideLoops(origin: origin, destination: destination,
                                 bearing: bearing, targetDistanceKm: targetDistanceKm)
        } else {
            // TOO FAR: Create natural loops in the general direction, don't force destination
            return buildDirectionalLoops(origin: origin, destination: destination,
                                        bearing: bearing, targetDistanceKm: targetDistanceKm,
                                        directDist: directDist)
        }
    }
    
    // MARK: - Loop Generation Strategies
    
    private func getLoopStrategy(ratio: Double) -> String {
        if ratio >= 0.7 && ratio <= 1.3 { return "Destination-focused" }
        else if ratio < 0.7 { return "Wide loops" }
        else { return "Directional loops" }
    }
    
    /// Strategy 1: Destination is the right distance - build loops around it
    private func buildDestinationFocusedLoops(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        bearing: Double,
        targetDistanceKm: Double,
        loopDist: Double
    ) -> [[CLLocationCoordinate2D]] {
        
        let midLat = (origin.latitude + destination.latitude) / 2
        let midLon = (origin.longitude + destination.longitude) / 2
        let midpoint = CLLocationCoordinate2D(latitude: midLat, longitude: midLon)
        
        let extraNeeded = max(0, targetDistanceKm - loopDist)
        let detourSize = extraNeeded / 3.0
        
        var candidates: [[CLLocationCoordinate2D]] = []
        
        // Direct loop
        candidates.append([destination])
        
        // Slight variations
        let left = coordinateOffset(from: midpoint, bearingDeg: bearing + 90, distanceKm: detourSize)
        let right = coordinateOffset(from: midpoint, bearingDeg: bearing - 90, distanceKm: detourSize)
        
        candidates.append([left, destination])
        candidates.append([destination, right])
        candidates.append([left, destination, right])
        
        return candidates
    }
    
    /// Strategy 2: Destination too close - create proper loops that ignore it
    private func buildWideLoops(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        bearing: Double,
        targetDistanceKm: Double
    ) -> [[CLLocationCoordinate2D]] {
        
        // Create circular/elliptical loops of the right size
        let loopRadius = targetDistanceKm / 6.28  // Circumference = 2πr, so r = distance/(2π)
        
        var candidates: [[CLLocationCoordinate2D]] = []
        
        // Classic "petal" loops in different directions
        // These ignore the destination and create natural round trips
        
        // North loop
        let north1 = coordinateOffset(from: origin, bearingDeg: 0, distanceKm: loopRadius * 0.7)
        let north2 = coordinateOffset(from: origin, bearingDeg: 90, distanceKm: loopRadius * 0.5)
        candidates.append([north1, north2])
        
        // East loop
        let east1 = coordinateOffset(from: origin, bearingDeg: 90, distanceKm: loopRadius * 0.7)
        let east2 = coordinateOffset(from: origin, bearingDeg: 180, distanceKm: loopRadius * 0.5)
        candidates.append([east1, east2])
        
        // South loop
        let south1 = coordinateOffset(from: origin, bearingDeg: 180, distanceKm: loopRadius * 0.7)
        let south2 = coordinateOffset(from: origin, bearingDeg: 270, distanceKm: loopRadius * 0.5)
        candidates.append([south1, south2])
        
        // West loop
        let west1 = coordinateOffset(from: origin, bearingDeg: 270, distanceKm: loopRadius * 0.7)
        let west2 = coordinateOffset(from: origin, bearingDeg: 0, distanceKm: loopRadius * 0.5)
        candidates.append([west1, west2])
        
        // Figure-8 pattern in direction of destination
        let fig8_1 = coordinateOffset(from: origin, bearingDeg: bearing + 45, distanceKm: loopRadius * 0.8)
        let fig8_2 = coordinateOffset(from: origin, bearingDeg: bearing - 45, distanceKm: loopRadius * 0.8)
        candidates.append([fig8_1, fig8_2])
        
        // Longer ellipse toward destination (but not reaching it)
        let toward = coordinateOffset(from: origin, bearingDeg: bearing, distanceKm: loopRadius * 1.2)
        let perpLeft = coordinateOffset(from: toward, bearingDeg: bearing + 90, distanceKm: loopRadius * 0.6)
        let perpRight = coordinateOffset(from: toward, bearingDeg: bearing - 90, distanceKm: loopRadius * 0.6)
        candidates.append([perpLeft, toward, perpRight])
        
        return candidates
    }
    
    /// Strategy 3: Destination too far - create loops in general direction
    private func buildDirectionalLoops(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        bearing: Double,
        targetDistanceKm: Double,
        directDist: Double
    ) -> [[CLLocationCoordinate2D]] {
        
        // Go partway toward destination, create loops, come back
        let reasonableReach = targetDistanceKm / 3.0  // Go 1/3 of target distance out
        let loopSize = targetDistanceKm / 5.0
        
        var candidates: [[CLLocationCoordinate2D]] = []
        
        // Simple out-and-back in destination direction
        let outpoint = coordinateOffset(from: origin, bearingDeg: bearing, distanceKm: reasonableReach)
        candidates.append([outpoint])
        
        // Out with a loop to the side
        let outLeft = coordinateOffset(from: outpoint, bearingDeg: bearing + 90, distanceKm: loopSize)
        let outRight = coordinateOffset(from: outpoint, bearingDeg: bearing - 90, distanceKm: loopSize)
        candidates.append([outLeft, outpoint])
        candidates.append([outpoint, outRight])
        candidates.append([outLeft, outpoint, outRight])
        
        // Angled approach
        let angle1 = coordinateOffset(from: origin, bearingDeg: bearing + 60, distanceKm: reasonableReach * 0.8)
        let angle2 = coordinateOffset(from: origin, bearingDeg: bearing - 60, distanceKm: reasonableReach * 0.8)
        candidates.append([angle1, angle2])
        
        // Multi-point scenic route in general direction
        let wp1 = coordinateOffset(from: origin, bearingDeg: bearing + 30, distanceKm: reasonableReach * 0.6)
        let wp2 = coordinateOffset(from: origin, bearingDeg: bearing, distanceKm: reasonableReach * 1.1)
        let wp3 = coordinateOffset(from: origin, bearingDeg: bearing - 30, distanceKm: reasonableReach * 0.6)
        candidates.append([wp1, wp2, wp3])
        
        return candidates
    }

    // MARK: - MapKit directions

    private func requestLoop(
        origin: CLLocationCoordinate2D,
        waypoints: [CLLocationCoordinate2D],
        targetDistanceKm: Double,
        terrain: TerrainProfile,
        index: Int
    ) async throws -> GeneratedRoute? {

        var allPolylineCoords: [CLLocationCoordinate2D] = []
        var totalDistance: Double = 0
        let stops = [origin] + waypoints + [origin]

        for i in 0..<(stops.count - 1) {
            let req = MKDirections.Request()
            req.source        = MKMapItem(placemark: MKPlacemark(coordinate: stops[i]))
            req.destination   = MKMapItem(placemark: MKPlacemark(coordinate: stops[i + 1]))
            
            // Use walking for safer, bike-friendly routes (avoids highways/freeways)
            // Also request alternate routes to get more variety
            req.transportType = .walking
            req.requestsAlternateRoutes = true

            do {
                let directions = MKDirections(request: req)
                let response   = try await directions.calculate()

                guard let route = response.routes.first else {
                    print("⚠️ No route returned for leg \(i)")
                    // If walking fails, try automobile as fallback (but flag it)
                    print("⚠️ Trying automobile directions as fallback...")
                    req.transportType = .automobile
                    let altDirections = MKDirections(request: req)
                    let altResponse = try await altDirections.calculate()
                    
                    guard let altRoute = altResponse.routes.first else {
                        throw NSError(domain: "RouteGeneration", code: 1, 
                                     userInfo: [NSLocalizedDescriptionKey: "No route available for leg \(i)"])
                    }
                    
                    // Use the automobile route but warn about it
                    var coords = [CLLocationCoordinate2D](
                        repeating: kCLLocationCoordinate2DInvalid,
                        count: altRoute.polyline.pointCount
                    )
                    altRoute.polyline.getCoordinates(
                        &coords,
                        range: NSRange(location: 0, length: altRoute.polyline.pointCount)
                    )
                    allPolylineCoords.append(contentsOf: coords)
                    totalDistance += altRoute.distance
                    print("⚠️ Leg \(i): \(String(format: "%.1f", altRoute.distance/1000))km (auto route)")
                    continue
                }

                var coords = [CLLocationCoordinate2D](
                    repeating: kCLLocationCoordinate2DInvalid,
                    count: route.polyline.pointCount
                )
                route.polyline.getCoordinates(
                    &coords,
                    range: NSRange(location: 0, length: route.polyline.pointCount)
                )
                allPolylineCoords.append(contentsOf: coords)
                totalDistance += route.distance
                print("✅ Leg \(i): \(String(format: "%.1f", route.distance/1000))km")

            } catch {
                print("❌ Leg \(i) error: \(error.localizedDescription)")
                // Try automobile as last resort
                do {
                    req.transportType = .automobile
                    let altDirections = MKDirections(request: req)
                    let altResponse = try await altDirections.calculate()
                    
                    if let altRoute = altResponse.routes.first {
                        var coords = [CLLocationCoordinate2D](
                            repeating: kCLLocationCoordinate2DInvalid,
                            count: altRoute.polyline.pointCount
                        )
                        altRoute.polyline.getCoordinates(
                            &coords,
                            range: NSRange(location: 0, length: altRoute.polyline.pointCount)
                        )
                        allPolylineCoords.append(contentsOf: coords)
                        totalDistance += altRoute.distance
                        print("⚠️ Leg \(i): \(String(format: "%.1f", altRoute.distance/1000))km (fallback auto)")
                    } else {
                        throw error
                    }
                } catch {
                    print("❌ Leg \(i) failed completely")
                    throw error
                }
            }
        }

        guard !allPolylineCoords.isEmpty else { 
            throw NSError(domain: "RouteGeneration", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "No polyline coordinates generated"])
        }

        let distanceKm       = totalDistance / 1000.0
        let targetClimbM     = terrain.climbPerKm.lowerBound
                             + (terrain.climbPerKm.upperBound - terrain.climbPerKm.lowerBound) * 0.5
        let estimatedClimb   = targetClimbM * distanceKm
        let climbPenaltyMin  = estimatedClimb / 100.0 * 3
        let baseDurationMin  = (distanceKm / 20.0) * 60
        let totalDurationMin = baseDurationMin + climbPenaltyMin

        let polyline = MKPolyline(coordinates: allPolylineCoords, count: allPolylineCoords.count)

        let names = ["Direct Loop", "Northern Arc", "Southern Arc",
                     "Scenic Loop", "Extended Loop", "Wide Loop", 
                     "Challenge Route", "Alternative Loop"]
        let name = index < names.count ? names[index] : "Loop \(index + 1)"

        return GeneratedRoute(
            name: name,
            polyline: polyline,
            waypoints: waypoints,
            distanceKm: distanceKm,
            estimatedClimbM: estimatedClimb,
            estimatedDurationMin: totalDurationMin,
            terrain: terrain
        )
    }

    // MARK: - Scoring

    private func scoreRoute(_ route: GeneratedRoute, target: Double, terrain: TerrainProfile) -> Double {
        let distanceDelta = abs(route.distanceKm - target) / target
        let distanceScore = max(0, 1 - distanceDelta * 2)
        let targetMid     = (terrain.climbPerKm.lowerBound + terrain.climbPerKm.upperBound) / 2
        let climbDelta    = abs(route.climbPerKm - targetMid) / max(targetMid, 1)
        let terrainScore  = max(0, 1 - climbDelta)
        return distanceScore * 0.7 + terrainScore * 0.3
    }

    // MARK: - Geometry helpers

    private func bearingBetween(_ from: CLLocationCoordinate2D,
                                 _ to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude  * .pi / 180
        let lat2 = to.latitude    * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y    = sin(dLon) * cos(lat2)
        let x    = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }
    
    private func distanceBetween(_ from: CLLocationCoordinate2D,
                                  _ to: CLLocationCoordinate2D) -> Double {
        let fromLocation = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let toLocation = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return fromLocation.distance(from: toLocation)  // in meters
    }

    private func coordinateOffset(from coord: CLLocationCoordinate2D,
                                   bearingDeg: Double,
                                   distanceKm: Double) -> CLLocationCoordinate2D {
        let R    = 6371.0
        let d    = distanceKm / R
        let b    = bearingDeg * .pi / 180
        let lat1 = coord.latitude  * .pi / 180
        let lon1 = coord.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
        let lon2 = lon1 + atan2(sin(b) * sin(d) * cos(lat1),
                                cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi,
                                      longitude: lon2 * 180 / .pi)
    }
}
