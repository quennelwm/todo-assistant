import Foundation

struct TodoAutomaticUpdateStatus: Codable, Equatable {
    var enabled = false
    var lastSuccessfulUpdate: Date?
    private(set) var intervalMinutes = 30

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/待办助手/自动更新.json")
    }

    func delay(after lastAttempt: Date?, now: Date = .now) -> TimeInterval? {
        guard enabled else { return nil }
        let lastUpdate = max(lastSuccessfulUpdate ?? .distantPast, lastAttempt ?? .distantPast)
        return max(0, TimeInterval(intervalMinutes * 60) - now.timeIntervalSince(lastUpdate))
    }

    static func load(from file: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return Self()
        }
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
