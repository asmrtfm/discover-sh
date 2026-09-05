import Foundation

class APIService {
    static let shared = APIService()

    func getDrinksBatch(ids: [Int]) async throws -> [DrinkDTO] {
        let url = "\(Constants.baseURL)/api/v1/drinks/batch"
        return try await request(url: url, body: ["ids": ids])
    }

    func getVenues(near location: Location) async throws -> [VenueDTO] {
        let url = "\(Constants.baseURL)/api/v1/venues"
        return try await request(url: url, body: ["lat": location.lat, "lng": location.lng])
    }

    private func request<T: Decodable>(url: String, body: [String: Any]) async throws -> T {
        fatalError("stub")
    }
}
