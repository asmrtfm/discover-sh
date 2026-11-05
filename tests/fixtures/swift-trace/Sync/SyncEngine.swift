import Foundation

class SyncEngine {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func merge<T: Syncable>(remote: [T.DTO], local: [T]) async throws {
        for dto in remote {
            let model = T.create(from: dto)
            try await model.resolveRelationships(from: dto, context: context)
        }
    }

    func upsert<T: Syncable>(_ model: T, from dto: T.DTO) async throws {
        model.apply(dto)
        try await model.resolveRelationships(from: dto, context: context)
    }
}
