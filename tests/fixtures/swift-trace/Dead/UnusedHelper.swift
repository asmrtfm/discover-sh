import Foundation

// Dead code — nothing calls processLegacyDrinks
class UnusedHelper {
    func processLegacyDrinks() async throws {
        let batch = try await APIService.shared.getDrinksBatch(ids: [1, 2, 3])
        print(batch)
    }
}
