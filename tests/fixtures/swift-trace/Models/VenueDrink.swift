import Foundation

class VenueDrink {
    var drinkId: Int?
}

extension VenueDrink: Syncable {
    @MainActor
    func resolveRelationships(from dto: VenueDrinkDTO, context: ModelContext) async throws {
        guard let dId = dto.drinkId else { return }
        let remoteDTOs = try await APIService.shared.getDrinksBatch(ids: [dId])
        // process remoteDTOs
    }
}
