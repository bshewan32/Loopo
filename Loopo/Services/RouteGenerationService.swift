//
//  RouteGenerationService.swift
//  Loopo
//
//  Created by Bill Shewan on 19/4/2026.
//

import Foundation
import CoreLocation
import MapKit

class RouteGenerationService {

    static let shared = RouteGenerationService()

    // Get your free API key from: https://www.graphhopper.com/dashboard/
    private let apiKey  = "3a1823c0-7379-418a-8017-df10952ce47e"
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

        // Request 3 different loops using different random seeds
        for i in 0..<3 {
            let seed = Int.random(in: 0...10000)

            print("🔄 Attempting route \(i + 1) with seed \(seed)...")

            // Apply direction bias by nudging the origin a fixed 400 m in the
            // chosen compass direction. This is enough to steer GraphHopper's
            // round_trip algorithm without moving the route start away from the
            // user's actual position.
            //
            // A percentage of targetDistanceKm was used previously but caused
            // the loop start to appear several km away on longer rides.
            let biasedOrigin = heading.map { offsetOrigin(origin, heading: $0, distanceKm: 0.4) }
                               ?? origin

            do {
                if let route = try await requestGraphHopperLoop(
                    origin: biasedOrigin,
                    targetDistanceKm: targetDistanceKm,
                    terrain: terrain,
                    seed: seed,
                    index: i
                ) {
                    print("✅ Route \(i + 1) generated successfully")
                    routes.append(route)
                }
            } catch {
                print("❌ GraphHopper request \(i + 1) failed: \(error.localizedDescription)")
                lastError = error

                // Small delay before next attempt to avoid rate limiting
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        guard !routes.isEmpty else {
            let base = "Could not generate any valid routes. "
            if let lastError = lastError {
                throw NSError(
                    domain: "RouteGeneration", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: base + lastError.localizedDescription]
                )
            } else {
                throw NSError(
                    domain: "RouteGeneration", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: base + "Try adjusting the distance or location."]
                )
            }
        }

        return routes.sorted {
            scoreRoute($0, target: targetDistanceKm, terrain: terrain)
          > scoreRoute($1, target: targetDistanceKm, terrain: terrain)
        }
    }

    // MARK: - Direction Bias Helper

    /// Offsets a coordinate by `distanceKm` in the given compass `heading` (degrees, 0 = north).
    /// This nudges GraphHopper's round_trip algorithm to extend the loop in the chosen direction
    /// without using the `heading` query parameter, which is unsupported for round_trip routes.
    private func offsetOrigin(
        _ origin: CLLocationCoordinate2D,
        heading: Double,
        distanceKm: Double
    ) -> CLLocationCoordinate2D {
        let earthRadiusKm = 6371.0
        let headingRad    = heading * .pi / 180
        let distRad       = distanceKm / earthRadiusKm
        let latRad        = origin.latitude  * .pi / 180
        let lonRad        = origin.longitude * .pi / 180

        let newLatRad = asin(
            sin(latRad) * cos(distRad) +
            cos(latRad) * sin(distRad) * cos(headingRad)
        )
        let newLonRad = lonRad + atan2(
            sin(headingRad) * sin(distRad) * cos(latRad),
            cos(distRad) - sin(latRad) * sin(newLatRad)
        )

        return CLLocationCoordinate2D(
            latitude:  newLatRad * 180 / .pi,
            longitude: newLonRad * 180 / .pi
        )
    }

    // MARK: - GraphHopper API Request

    private func requestGraphHopperLoop(
        origin: CLLocationCoordinate2D,
        targetDistanceKm: Double,
        terrain: TerrainProfile,
        seed: Int,
        index: Int
    ) async throws -> GeneratedRoute? {

        var urlComponents = URLComponents(string: baseURL)!

        // All terrain profiles use the `bike` profile on the free tier.
        // The `mtb` profile is a paid-tier feature and will return a 400/403.
        // Terrain preference (hilly vs flat) is expressed through the scoring
        // function which ranks returned routes by climb-per-km against the
        // target terrain band.
        let profile = "bike"

        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "point",               value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "profile",             value: profile),
            URLQueryItem(name: "algorithm",           value: "round_trip"),
            URLQueryItem(name: "round_trip.distance", value: "\(Int(targetDistanceKm * 1000))"),
            URLQueryItem(name: "round_trip.seed",     value: "\(seed)"),
            URLQueryItem(name: "elevation",           value: "true"),
            URLQueryItem(name: "instructions",        value: "true"),
            URLQueryItem(name: "locale",              value: "en"),
            URLQueryItem(name: "key",                 value: apiKey),
        ]

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("📡 GraphHopper Response Status: \(httpResponse.statusCode)")

        if httpResponse.statusCode != 200 {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ GraphHopper API Error (\(httpResponse.statusCode)): \(errorString)")
            if let errorData = try? JSONDecoder().decode(GraphHopperError.self, from: data) {
                print("❌ GraphHopper Error Message: \(errorData.message)")
            }
            throw URLError(.badServerResponse)
        }

        let ghResponse = try JSONDecoder().decode(GraphHopperResponse.self, from: data)

        guard let path = ghResponse.paths.first else {
            print("⚠️ No paths returned from GraphHopper")
            return nil
        }

        print("✅ GraphHopper route: \(String(format: "%.1f", path.distance/1000))km, \(String(format: "%.0f", path.ascend))m climb, \(path.instructions?.count ?? 0) instructions")

        // Decode the encoded polyline into MapKit coordinates
        let coordinates = decodePolyline(path.points, is3D: true)

        guard !coordinates.isEmpty else {
            print("⚠️ Polyline decoding failed — no coordinates")
            return nil
        }

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)

        // Convert GraphHopper instructions into RouteInstruction values
        let instructions: [RouteInstruction] = (path.instructions ?? []).map { raw in
            RouteInstruction(
                text:            raw.text,
                streetName:      raw.street_name ?? "",
                distanceToNextM: raw.distance,
                pointIndex:      raw.interval.first ?? 0,
                sign:            raw.sign
            )
        }

        let names = ["Morning Loop", "Scenic Route", "Endurance Ride"]
        let name  = index < names.count ? names[index] : "Loop \(index + 1)"

        return GeneratedRoute(
            name:                 name,
            polyline:             polyline,
            waypoints:            [],
            distanceKm:           path.distance / 1000.0,
            estimatedClimbM:      path.ascend,
            estimatedDurationMin: Double(path.time) / 60_000.0,
            terrain:              terrain,
            instructions:         instructions
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

    // MARK: - Encoded Polyline Decoder

    /// Decodes GraphHopper's encoded polyline format (Google Polyline Algorithm, optionally 3D).
    private func decodePolyline(_ encoded: String, is3D: Bool) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        let chars = Array(encoded)
        var index = 0
        var lat = 0, lng = 0, ele = 0

        while index < chars.count {
            var b: Int
            var shift = 0, result = 0
            repeat {
                b = Int(chars[index].asciiValue!) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20
            lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

            shift = 0; result = 0
            repeat {
                b = Int(chars[index].asciiValue!) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20
            lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

            if is3D {
                shift = 0; result = 0
                repeat {
                    b = Int(chars[index].asciiValue!) - 63
                    index += 1
                    result |= (b & 0x1f) << shift
                    shift += 5
                } while b >= 0x20
                ele += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            }

            coordinates.append(CLLocationCoordinate2D(
                latitude:  Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            ))
        }
        return coordinates
    }
}

// MARK: - GraphHopper Codable Response Models

struct GraphHopperResponse: Codable {
    let paths: [GraphHopperPath]
}

struct GraphHopperPath: Codable {
    let distance: Double
    let time: Int
    let ascend: Double
    let descend: Double
    let points: String
    let instructions: [GraphHopperInstruction]?
}

struct GraphHopperInstruction: Codable {
    /// Instruction text, e.g. "Turn left onto High Street"
    let text: String
    /// Street name for the following segment
    let street_name: String?
    /// Distance in metres until the next manoeuvre
    let distance: Double
    /// GraphHopper sign integer (negative = left, positive = right, 0 = straight)
    let sign: Int
    /// [startIndex, endIndex] into the points array
    let interval: [Int]
}

struct GraphHopperError: Codable {
    let message: String
    let hints: [GraphHopperHint]?
}

struct GraphHopperHint: Codable {
    let message: String
    let details: String?
}
