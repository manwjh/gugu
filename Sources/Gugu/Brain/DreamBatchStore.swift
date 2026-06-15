import Foundation

struct DreamBatchState: Codable {
    var batchID: String
    var customID: String
    var status: String
    var createdAt: Date
    var resultURL: String?
}

enum DreamBatchStore {
    static func load() -> DreamBatchState? {
        guard let data = try? Data(contentsOf: Paths.dreamBatchState) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DreamBatchState.self, from: data)
    }

    static func save(_ state: DreamBatchState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: Paths.dreamBatchState)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: Paths.dreamBatchState)
    }
}
