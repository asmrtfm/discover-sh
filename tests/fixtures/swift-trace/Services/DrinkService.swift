import Foundation

class DrinkService {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func synchronizeDrinkData(user: User) async throws {
        let engine = SyncEngine(context: context)
        let remoteDrinks = try await APIService.shared.getDrinksBatch(ids: user.favoriteDrinkIds)
        for dto in remoteDrinks {
            if let recipe = dto.recipe {
                try await engine.upsert(Drink(), from: dto)
            }
        }
    }
}
