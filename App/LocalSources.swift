import Foundation

struct LocalSources {
    let home: URL

    static let directoryKey = "IntegrationDirectory"
    let integrationDirectory: URL?

    init(home: URL, integrationDirectory: URL? = nil) {
        self.home = home
        self.integrationDirectory = integrationDirectory
    }

    static func configured() -> LocalSources {
        let path = UserDefaults.standard.string(forKey: directoryKey)
        return LocalSources(home: FileManager.default.homeDirectoryForCurrentUser,
                            integrationDirectory: path.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    var isConfigured: Bool { integrationDirectory != nil }
    private var integration: URL {
        integrationDirectory ?? home.appending(path: "Library/Application Support/待办助手/未接入")
    }

    var operations: URL { integration.appending(path: "操作记录") }

    func readMaster() throws -> TodoMaster {
        let file = integration.appending(path: "待办总表.md")
        return try HandoffReader.master(String(contentsOf: file, encoding: .utf8), path: file.path)
    }

    func readPayments() throws -> PublishedPayments {
        let file = integration.appending(path: "请款与付款清单.json")
        let snapshot = try JSONDecoder().decode(PublishedPayments.self, from: Data(contentsOf: file))
        try snapshot.validate()
        return snapshot
    }

    func sync(to store: TodoStore) -> [String] {
        guard isConfigured else { return [] }
        var failures: [String] = []
        let hasMaster = FileManager.default.fileExists(atPath: integration.appending(path: "待办总表.md").path)
        let hasPayments = FileManager.default.fileExists(atPath: integration.appending(path: "请款与付款清单.json").path)
        if !hasMaster && !hasPayments { return ["所选目录没有待办总表.md 或请款与付款清单.json；手动待办仍可正常使用。"] }
        if hasMaster {
            do { try store.merge(readMaster()) }
            catch { failures.append("待办总表读取失败。\(error.localizedDescription)") }
        }
        if hasPayments {
            do { try store.mergePayments(readPayments()) }
            catch { failures.append("请款与付款清单读取失败。\(error.localizedDescription)") }
        }
        return failures
    }
}
