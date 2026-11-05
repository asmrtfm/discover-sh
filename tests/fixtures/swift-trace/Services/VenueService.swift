import Foundation

class VenueService {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func synchronizeVenueData(venue: Venue, user: User) async throws {
        try await synchronizeVenueDrinks(venue: venue, user: user)
    }

    func synchronizeVenueDrinks(venue: Venue, user: User) async throws {
        let engine = SyncEngine(context: context)
        let remoteDrinks = try await APIService.shared.getDrinksBatch(ids: venue.drinkIds)
        try await engine.merge(remote: remoteDrinks, local: venue.drinks)
    }
}
