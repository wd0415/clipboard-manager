import Foundation

public enum ClipPayload: Codable, Equatable, Sendable {
    case text(String)
    case image(Data)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case text, image }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .image(let value):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .image: self = .image(try container.decode(Data.self, forKey: .value))
        }
    }
}

public struct ClipRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let payload: ClipPayload

    public init(id: UUID = UUID(), createdAt: Date = Date(), payload: ClipPayload) {
        self.id = id
        self.createdAt = createdAt
        self.payload = payload
    }

    public var displayText: String {
        switch payload {
        case .text(let value): return value
        case .image: return "图片"
        }
    }
}

public final class ClipboardStore: @unchecked Sendable {
    private struct Snapshot: Codable { var records: [ClipRecord] }

    private let fileURL: URL
    private(set) public var maxEntries: Int
    private var records: [ClipRecord]

    public init(directory: URL, maxEntries: Int = 500) throws {
        guard maxEntries > 0 else { throw StoreError.invalidLimit }
        self.maxEntries = maxEntries
        self.fileURL = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL) {
            self.records = try JSONDecoder().decode(Snapshot.self, from: data).records
        } else {
            self.records = []
        }
        self.records.sort { $0.createdAt > $1.createdAt }
    }

    public static func temporary(maxEntries: Int = 500) throws -> ClipboardStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-manager-\(UUID().uuidString)", isDirectory: true)
        return try ClipboardStore(directory: directory, maxEntries: maxEntries)
    }

    @discardableResult
    public func insert(_ payload: ClipPayload) throws -> ClipRecord {
        let record = ClipRecord(payload: payload)
        records.insert(record, at: 0)
        records = Array(records.prefix(maxEntries))
        try persist()
        return record
    }

    public func list() -> [ClipRecord] { records }

    public func setMaxEntries(_ limit: Int) throws {
        guard limit > 0 else { throw StoreError.invalidLimit }
        maxEntries = limit
        records = Array(records.prefix(limit))
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(Snapshot(records: records))
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum StoreError: Error, Equatable {
    case invalidLimit
}
