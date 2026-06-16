import Foundation

struct DreamBatchState: Codable {
    var batchID: String
    var customID: String
    var memoryDay: String
    var status: String
    var createdAt: Date
    var resultURL: String?

    enum CodingKeys: String, CodingKey {
        case batchID
        case customID
        case memoryDay
        case status
        case createdAt
        case resultURL
    }

    init(batchID: String, customID: String, memoryDay: String = Memory.dayString(for: Date()),
         status: String, createdAt: Date, resultURL: String?) {
        self.batchID = batchID
        self.customID = customID
        self.memoryDay = memoryDay
        self.status = status
        self.createdAt = createdAt
        self.resultURL = resultURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batchID = try c.decode(String.self, forKey: .batchID)
        customID = try c.decode(String.self, forKey: .customID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        memoryDay = try c.decodeIfPresent(String.self, forKey: .memoryDay) ?? Memory.dayString(for: createdAt)
        status = try c.decode(String.self, forKey: .status)
        resultURL = try c.decodeIfPresent(String.self, forKey: .resultURL)
    }

    var memoryDate: Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: memoryDay) ?? createdAt
    }
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
