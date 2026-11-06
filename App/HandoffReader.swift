import Foundation

enum HandoffReader {
    struct WeChat: Decodable {
        struct Item: Decodable {
            let id: String
            let title: String
            let display_title: String?
            let original_text: String?
            let primary_owner: String?
            let priority: String?
            let owner: String?
            let contact: String?
            let action: String?
            let notes: String?
            let due: String?
            let due_precision: String?
            let status: String
            let evidence_observation_ids: [Int]?
        }
        let as_of: String?
        let items: [Item]
    }

    static func wechat(_ data: Data, path: String) throws -> [SourceTask] {
        try wechat(JSONDecoder().decode(WeChat.self, from: data), path: path)
    }

    static func wechat(_ list: WeChat, path: String) -> [SourceTask] {
        list.items.compactMap { row in
            guard let state = state(row.status), !row.id.isEmpty, !row.title.isEmpty,
                  row.due_precision != "通知日期，参加意愿未确认" else { return nil }
            let id = row.id
            let owner = row.owner ?? ""
            let primary = owner.components(separatedBy: "；").first ?? ""
            let personal = primary.contains("我") || owner.contains("我协调") || id.hasPrefix("F")
            let ids = row.evidence_observation_ids ?? []
            let evidence = Evidence(label: "微信 \(id)" + (ids.isEmpty ? "" : " · " + ids.map(String.init).joined(separator: ", ")), path: path)
            let date = deadline(row.due, kind: row.due_precision)
            return SourceTask(id: id, title: row.title,
                              owner: row.owner, contact: row.contact, due: date,
                              lane: personal ? .personal : (owner.isEmpty ? .unassigned : .team),
                              state: state, notes: [row.action, row.notes].compactMap { $0 }.joined(separator: "\n"),
                              evidence: [evidence], aliases: [], revision: TodoClock.parse(list.as_of),
                              displayTitle: row.display_title.flatMap(value), originalText: row.original_text.flatMap(value),
                              primaryOwner: row.primary_owner.flatMap(value), priority: row.priority.flatMap(TodoPriority.init),
                              needsReview: isUnconfirmed(row.status) ? true : nil)
        }
    }

    static func master(_ text: String, path: String) throws -> TodoMaster {
        let metadata = text.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("版本 ") }?.components(separatedBy: "。")
        guard let versionLine = metadata?.first, let dateLine = metadata?.dropFirst().first,
              dateLine.hasPrefix("发布于 "),
              let publishedAt = TodoClock.parse(String(dateLine.dropFirst("发布于 ".count))) else {
            throw TodoStore.Failure.invalidPublication
        }
        let version = String(versionLine.dropFirst("版本 ".count))
        let table = markdownTable(text)
        var tasks = markdown(text, path: path)
        let keys = tasks.flatMap { [$0.id] + $0.aliases }
        guard !version.isEmpty, table.count >= 3, !tasks.isEmpty, table.count == tasks.count + 2,
              table[0].hasPrefix("| ID |"), table[1].hasPrefix("| --- |"),
              Set(keys).count == keys.count else { throw TodoStore.Failure.invalidPublication }
        for index in tasks.indices { tasks[index].revision = publishedAt }
        return TodoMaster(version: version, publishedAt: publishedAt, tasks: tasks)
    }

    static func markdown(_ text: String, path: String) -> [SourceTask] {
        var rows: [SourceTask] = []
        for line in markdownTable(text) {
            guard line.hasSuffix("|") else { continue }
            let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
            guard cells.count >= 8, !cells[0].isEmpty, !cells[2].isEmpty,
                  let lane = TodoLane(rawValue: cells[1]), let status = state(cells[6]) else { continue }
            let aliases = cells.count > 8 ? cells[8].split(whereSeparator: { ",，、".contains($0) })
                .compactMap { value($0.trimmingCharacters(in: .whitespaces)) } : []
            rows.append(SourceTask(id: cells[0], title: cells[2], owner: value(cells[3]), contact: value(cells[4]),
                                   due: deadline(cells[5], kind: cells.count > 14 ? cells[14] : nil), lane: lane, state: status,
                                   notes: cells.count > 9 ? value(cells[9]) : nil,
                                   evidence: [Evidence(label: value(cells[7]) ?? cells[0], path: path)],
                                   aliases: aliases,
                                   displayTitle: cells.count > 10 ? value(cells[10]) : nil,
                                   originalText: cells.count > 11 ? value(cells[11]) : nil,
                                   primaryOwner: cells.count > 12 ? value(cells[12]) : nil,
                                   priority: cells.count > 13 ? TodoPriority(rawValue: cells[13]) : nil,
                                   needsReview: isUnconfirmed(cells[6]) ? true : nil))
        }
        return rows
    }

    private static func markdownTable(_ text: String) -> [String] {
        var actionSection = false
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                actionSection = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) == "桌面待办"
                return nil
            }
            return actionSection && line.hasPrefix("|") ? line : nil
        }
    }

    private static func deadline(_ raw: String?, kind: String?) -> String? {
        if let kind, kind.contains("活动开始") || kind.contains("活动起始") ||
            kind.contains("活动时间") || kind.contains("通知日期") { return nil }
        return TodoClock.parse(raw) == nil ? nil : raw
    }

    private static func value(_ raw: String) -> String? {
        ["", "-", "—", "待核", "未知", "无"].contains(raw) ? nil : raw
    }

    private static func isUnconfirmed(_ raw: String) -> Bool {
        if raw == "待核实" || raw == "待确认" { return true }
        return (raw.contains("取消") || raw.contains("完成")) &&
            ["疑似", "推测", "待核实", "待确认", "未确认"].contains { raw.contains($0) }
    }

    private static func state(_ raw: String) -> TodoState? {
        raw == "待处理" || isUnconfirmed(raw) ? .open : TodoState(rawValue: raw)
    }
}
