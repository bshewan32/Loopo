import Foundation
import CoreLocation
import MapKit

class RouteGenerationService {

    static let shared = RouteGenerationService()
    
    // TODO: Replace with actual GraphHopper API key
    // Get your free API key from: https://www.graphhopper.com/dashboard/
    private let apiKey = "3a1823c0-7379-418a-8017-df10952ce47e"  // Replace this!
    private let baseURL = "https://graphhopper.com/api/1/route"

    // MARK: - Public entry point

    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        targetDistanceKm: Double,
        terrain: TerrainProfile,
        heading: Double? = nil
    ) async throws -> [GeneratedRoute] {

        var routes: [GeneratedRoute] = []
        var lastError: Error?
        
        // Generate 3 different routes using different seeds
        for i in 0..<3 {
            let seed = Int.random(in: 0...10000)
            
            print("🔄 Attempting route \(i + 1) with seed \(seed)...")
            
            do {
                if let route = try await requestGraphHopperLoop(
                    origin: origin,
                    targetDistanceKm: targetDistanceKm,
                    terrain: terrain,
                    seed: seed,
                    heading: heading,
                    index: i
                ) {
                    routes.append(route)
                    print("✅ Route \(i + 1) generated successfully")
                }
            } catch {
                print("❌ GraphHopper request \(i + 1) failed: \(error.localizedDescription)")
                lastError = error
                
                // Add a small delay before retrying to avoid rate limiting
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }

        guard !routes.isEmpty else {
            let errorMessage = "Could not generate any valid routes. "
            if let lastError = lastError {
                throw NSError(domain: "RouteGeneration", code: 3,
                             userInfo: [NSLocalizedDescriptionKey: errorMessage + "Last error: \(lastError.localizedDescription)"])
            }
            throw NSError(domain: "RouteGeneration", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: errorMessage + "Check your API key and internet connection."])
        }

        print("📍 Total routes generated: \(routes.count)")

        // Score and return routes
        let scored = routes.sorted {
            scoreRoute($0, target: targetDistanceKm, terrain: terrain)
          > scoreRoute($1, target: targetDistanceKm, terrain: terrain)
        }
        
        return scored
    }

    // MARK: - GraphHopper API Request

    private func requestGraphHopperLoop(
        origin: CLLocationCoordinate2D,
        targetDistanceKm: Double,
        terrain: TerrainProfile,
        seed: Int,
        heading: Double?,
        index: Int
    ) async throws -> GeneratedRoute? {
        
        var urlComponents = URLComponents(string: baseURL)!
        
        // Map terrain profile to GraphHopper profile
        let profile: String
        switch terrain {
        case .flat, .mostlyFlat:
            profile = "bike"
        case .hilly, .reallyHilly:
            profile = "bike" 
        }
        
        var queryItems = [
            URLQueryItem(name: "point", value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "algorithm", value: "round_trip"),
            URLQueryItem(name: "round_trip.distance", value: "\(Int(targetDistanceKm * 1000))"),
            URLQueryItem(name: "round_trip.seed", value: "\(seed)"),
            URLQueryItem(name: "points_encoded", value: "true"),  // CRITICAL: Tell API to encode polyline
            URLQueryItem(name: "elevation", value: "true"),
            URLQueryItem(name: "calc_points", value: "true"),
            URLQueryItem(name: "key", value: apiKey)
        ]
        
        // Add heading bias if provided (only works with certain configurations)
        if let heading = heading {
            queryItems.append(URLQueryItem(name: "heading", value: "\(Int(heading))"))
        }
        
        urlComponents.queryItems = queryItems
        
        guard let url = urlComponents.url else {
            throw URLError(.badURL)
        }
        
        print("🌐 GraphHopper URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        print("📡 GraphHopper Response Status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode != 200 {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ GraphHopper API Error (\(httpResponse.statusCode)): \(errorString)")
            
            // Try to decode error response
            if let errorData = try? JSONDecoder().decode(GraphHopperError.self, from: data) {
                print("❌ GraphHopper Error Message: \(errorData.message)")
            }
            
            throw URLError(.badServerResponse)
        }
        
        let decoder = JSONDecoder()
        let ghResponse = try decoder.decode(GraphHopperResponse.self, from: data)
        
        guard let path = ghResponse.paths.first else {
            print("⚠️ No paths returned from GraphHopper")
            return nil
        }
        
        print("✅ GraphHopper route: \(String(format: "%.1f", path.distance/1000))km, \(String(format: "%.0f", path.ascend))m climb")
        
        // Decode polyline
        let coordinates = decodePolyline(path.points, is3D: true)
        
        guard !coordinates.isEmpty else {
            print("⚠️ Polyline decoding failed - no coordinates")
            return nil
        }
        
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        
        let distanceKm = path.distance / 1000.0
        let estimatedClimb = path.ascend
        let durationMin = Double(path.time) / 60000.0
        
        let names = ["Morning Loop", "Scenic Route", "Endurance Ride", "Quick Spin"]
        let name = index < names.count ? names[index] : "Loop \(index + 1)"
        
        return GeneratedRoute(
            name: name,
            polyline: polyline,
            waypoints: [], // Waypoints are handled internally by GraphHopper
            distanceKm: distanceKm,
            estimatedClimbM: estimatedClimb,
            estimatedDurationMin: durationMin,
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
    
    // MARK: - Polyline Decoding
    
    // Decodes GraphHopper's encoded polyline format
    private func decodePolyline(_ encoded: String, is3D: Bool) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        let len = encoded.count
        let chars = Array(encoded)
        var index = 0
        var lat = 0
        var lng = 0
        var ele = 0

        while index < len {
            var b: Int
            var shift = 0
            var result = 0
            repeat {
                b = Int(chars[index].asciiValue!) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20
            let dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
            lat += dlat

            shift = 0
            result = 0
            repeat {
                b = Int(chars[index].asciiValue!) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20
            let dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
            lng += dlng

            if is3D {
                shift = 0
                result = 0
                repeat {
                    b = Int(chars[index].asciiValue!) - 63
                    index += 1
                    result |= (b & 0x1f) << shift
                    shift += 5
                } while b >= 0x20
                let dele = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
                ele += dele
            }

            let latitude = Double(lat) / 1e5
            let longitude = Double(lng) / 1e5
            coordinates.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }

        return coordinates
    }
}

// MARK: - GraphHopper Response Models

struct GraphHopperResponse: Codable {
    let paths: [GraphHopperPath]
}

struct GraphHopperPath: Codable {
    let distance: Double
    let time: Int
    let ascend: Double
    let descend: Double
    let points: String
}

struct GraphHopperError: Codable {
    let message: String
    let hints: [GraphHopperHint]?
}

struct GraphHopperHint: Codable {
    let message: String
    let details: String?
}


