import Foundation

class Recipe {
    var drinkId: Int?
    var name: String = ""
}

extension Recipe: Syncable {
    typealias DTO = RecipeDTO

    @MainActor
    static func create(from dto: RecipeDTO) -> Recipe {
        let r = Recipe()
        r.name = dto.name
        return r
    }

    @MainActor
    func apply(_ dto: RecipeDTO) -> Bool {
        self.name = dto.name
        return true
    }

    @MainActor
    func resolveRelationships(from dto: RecipeDTO, context: ModelContext) async throws {
        guard let dId = dto.drinkId else { return }
        let remoteDTOs = try await APIService.shared.getDrinksBatch(ids: [dId])
        // process remoteDTOs
    }
}
