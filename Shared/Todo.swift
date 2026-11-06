import Foundation

enum TodoLane: String, Codable, CaseIterable, Identifiable {
    case personal = "本人", team = "团队", unassigned = "待确认"
    var id: Self { self }
}

enum TodoState: String, Codable, CaseIterable, Identifiable {
    case open = "待办", done = "已完成", cancelled = "已取消", information = "仅记录"
    var id: Self { self }
}

enum Urgency: Int, CaseIterable {
    case overdue, today, tomorrow, later, undated, done, cancelled
    var label: String {
        switch self {
        case .overdue: "逾期"
        case .today: "今天"
        case .tomorrow: "明天"
        case .later: "近期"
        case .undated: "未定"
        case .done: "已完成"
        case .cancelled: "已取消"
        }
    }
}

enum TodoClock {
    static let zone = TimeZone(identifier: "Asia/Shanghai")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        if value.count == 10 {
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let date = calendar.date(from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2]
            )), day(date) == value else { return nil }
            return date
        }
        return (try? Date.ISO8601FormatStyle().parse(value))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
    }

    static func label(_ due: String?) -> String {
        guard let date = parse(due), let due else { return "待定" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = zone
        formatter.dateFormat = due.count == 10 ? "M月d日" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

struct Evidence: Codable, Hashable {
    var label: String
    var path: String
}

enum TodoPriority: String, Codable {
    case normal = "普通", high = "高"
}

struct SourceTask: Codable, Equatable {
    var id: String
    var title: String
    var owner: String?
    var contact: String?
    var due: String?
    var lane: TodoLane
    var state: TodoState
    var notes: String?
    var evidence: [Evidence]
    var aliases: [String]
    var revision: Date? = nil
    var displayTitle: String?
    var originalText: String?
    var primaryOwner: String?
    var priority: TodoPriority?
    var needsReview: Bool?
}

struct TodoItem: Codable, Equatable, Identifiable {
    var source: SourceTask
    var manual = Manual()
    var masterID: String?
    var masterVersion: String?
    var inMaster: Bool?
    var conflicts: [String]?
    var outbox: [TodoOperation]?
    var locallyCreated: Bool? = nil
    struct Manual: Codable, Equatable {
        var title: String?
        var notes: String?
        var owner: String?
        var contact: String?
        var lane: TodoLane?
        var state: TodoState?
        var stateChangedAt: Date?
        var stateEventID: String?
        var due: String?
        var dueEdited = false
        var pinned: Bool?
        var priority: TodoPriority?
    }
    var id: String { source.id }
    var title: String { manual.title ?? source.displayTitle ?? source.title }
    var notes: String? { manual.notes ?? source.notes }
    var isPinned: Bool { manual.pinned == true }
    var priority: TodoPriority { manual.priority ?? source.priority ?? .normal }
    var needsReview: Bool { state == .open && (source.needsReview == true || lane == .unassigned) }
    var leadOwner: String? {
        if manual.owner == nil, let primary = source.primaryOwner, !primary.isEmpty { return primary }
        guard let owner else { return nil }
        return owner.split(whereSeparator: { "/／、，,；;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "待确认" && $0 != "待核" && $0 != "未知" }
    }
    var owner: String? { manual.owner ?? source.owner }
    var contact: String? { manual.contact ?? source.contact }
    var due: String? { manual.dueEdited ? manual.due : source.due }
    var lane: TodoLane { manual.lane ?? source.lane }
    var state: TodoState { manual.state ?? source.state }

    func summaryStatus(at now: Date) -> String {
        TodoBoardGroup(item: self, now: now).title
    }

    var summaryFields: [String] {
        let sources = sourceNames.joined(separator: "／")
        return [
            due.map(TodoClock.label),
            sources.isEmpty ? nil : sources,
            leadOwner,
            contact.flatMap {
                let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return ["", "—", "待确认", "未知"].contains(name) ? nil : name
            },
            conflicts?.isEmpty == false ? "同步待确认" : nil
        ].compactMap { $0 }
    }

    private var sourceNames: [String] {
        var names: [String] = locallyCreated == true ? ["手动"] : []
        let pattern = "企业微信|企微|WeCom|WeChat|微信|iMessage|短信|截图|截屏|screenshot|照片|相册|photo|文档|文件|PDF|Word|Excel|邮件|Outlook|Mail|日历|Calendar"
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        func category(_ token: String) -> String {
            switch token.lowercased() {
            case "企业微信", "企微", "wecom": "企微"
            case "wechat", "微信": "微信"
            case "imessage", "短信": "短信"
            case "截图", "截屏", "screenshot": "截图"
            case "照片", "相册", "photo": "照片"
            case "邮件", "outlook", "mail": "邮件"
            case "日历", "calendar": "日历"
            default: "文档"
            }
        }
        for evidence in source.evidence {
            let label = evidence.label as NSString
            var channels = regex.matches(in: evidence.label, range: NSRange(location: 0, length: label.length))
                .map { category(label.substring(with: $0.range)) }
            if channels.isEmpty {
                let ext = URL(fileURLWithPath: evidence.path).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "heic", "webp", "tiff"].contains(ext) {
                    channels = ["照片"]
                } else if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv"].contains(ext) {
                    channels = ["文档"]
                }
            }
            for name in channels where !names.contains(name) { names.append(name) }
        }
        return names
    }

    func urgency(at now: Date) -> Urgency {
        switch state {
        case .done: return .done
        case .cancelled: return .cancelled
        case .information: return .undated
        case .open: break
        }
        guard let due, let date = TodoClock.parse(due) else { return .undated }
        let calendar = TodoClock.calendar
        if (due.count == 10 ? date < calendar.startOfDay(for: now) : date <= now) { return .overdue }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return .tomorrow }
        return .later
    }

    static func sorted(_ items: [TodoItem], at now: Date) -> [TodoItem] {
        let ranks = items.filter { $0.state != .information }.map { ($0, $0.urgency(at: now).rawValue, TodoClock.parse($0.due) ?? .distantFuture) }
        return ranks.sorted { ($0.1, $0.2, $0.0.id) < ($1.1, $1.2, $1.0.id) }.map(\.0)
    }
}


enum TodoBoardScope: String, CaseIterable, Identifiable {
    case all = "全部", personal = "个人", team = "团队", payment = "付款"
    var id: Self { self }

    func includes(_ lane: TodoLane) -> Bool {
        switch self {
        case .all: true
        case .personal: lane == .personal
        case .team: lane == .team
        case .payment: false
        }
    }
}

private enum TodoBoardGroup: Int {
    case overdue, today, tomorrow, week, month, later, undated, done, cancelled

    var title: String {
        switch self {
        case .overdue: "逾期"
        case .today: "今日"
        case .tomorrow: "明日"
        case .week: "本周"
        case .month: "本月"
        case .later: "以后"
        case .undated: "待定"
        case .done: "已完成"
        case .cancelled: "已取消"
        }
    }

    init(item: TodoItem, now: Date) {
        switch item.urgency(at: now) {
        case .overdue: self = .overdue
        case .today: self = .today
        case .tomorrow: self = .tomorrow
        case .undated: self = .undated
        case .done: self = .done
        case .cancelled: self = .cancelled
        case .later:
            guard let date = TodoClock.parse(item.due) else { self = .undated; return }
            var weekCalendar = Calendar(identifier: .iso8601)
            weekCalendar.timeZone = TodoClock.zone
            if weekCalendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                self = .week
            } else {
                self = TodoClock.calendar.isDate(date, equalTo: now, toGranularity: .month) ? .month : .later
            }
        }
    }
}

struct TodoBoardSnapshot {
    let rows: [TodoItem]
    let activeCount: Int

    init(items: [TodoItem], scope: TodoBoardScope, now: Date) {
        let scoped = items.filter { ($0.inMaster != false || $0.locallyCreated == true) && $0.state != .information && scope.includes($0.lane) }
        let ranked = scoped.map { item in
            let group = TodoBoardGroup(item: item, now: now).rawValue
            let rank: (Int, Int, Int, Double, String)
            if item.state == .open {
                let deadline = TodoClock.parse(item.due) ?? .distantFuture
                rank = (group, item.isPinned ? 0 : 1, item.priority == .high ? 0 : 1,
                        deadline.timeIntervalSinceReferenceDate, item.id)
            } else {
                let updated = item.manual.stateChangedAt ?? item.source.revision ?? .distantPast
                rank = (group, 0, 0, -updated.timeIntervalSinceReferenceDate, item.id)
            }
            return (item, rank)
        }
        rows = ranked.sorted { $0.1 < $1.1 }.map(\.0)
        activeCount = scoped.count { $0.state == .open }
    }
}

struct NewTodoDraft: Identifiable {
    let id: String
    var title = ""
    var notes = ""
    var lane: TodoLane
    var owner: String
    var contact = ""
    var hasDeadline = false
    var includesTime = false
    var date = Date.now
    var priority: TodoPriority = .normal

    init(lane: TodoLane = .personal) {
        id = "manual-" + UUID().uuidString.lowercased()
        self.lane = lane
        owner = lane == .personal ? "我" : ""
    }

    var deadline: String? {
        hasDeadline ? (includesTime ? TodoClock.timestamp(date) : TodoClock.day(date)) : nil
    }

    func source(at now: Date = .now) throws -> SourceTask {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TodoInputError(message: "请填写事项内容。") }
        guard lane == .personal || lane == .team else { throw TodoInputError(message: "请选择个人或团队。") }
        func optional(_ value: String) -> String? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return SourceTask(id: id, title: text, owner: optional(owner), contact: optional(contact), due: deadline,
                          lane: lane, state: .open, notes: optional(notes), evidence: [], aliases: [], revision: now,
                          originalText: text, priority: priority)
    }
}

struct TodoInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct WidgetNavigation: Codable, Equatable {
    var scope: String
    var paymentScope: String?
    var page: Int = 0
    var revision = "initial"
}

struct TodoPagination {
    let starts: [Int]
    let page: Int
    let range: Range<Int>
    var hasPrevious: Bool { page > 0 }
    var hasNext: Bool { page + 1 < starts.count }

    init(heights: [Double], available: Double, spacing: Double, requestedPage: Int) {
        let available = max(1, available)
        var starts = [0], start = 0
        while start < heights.count {
            var used = 0.0, end = start
            while end < heights.count {
                let next = max(1, heights[end]) + (end == start ? 0 : spacing)
                if used + next > available { break }
                used += next; end += 1
            }
            if end == heights.count { break }
            // Repeat the last complete row as context; the clipped row can never be skipped.
            let next = max(start + 1, end - 1)
            guard next < heights.count else { break }
            starts.append(next); start = next
        }
        self.starts = starts
        page = min(max(0, requestedPage), starts.count - 1)
        start = starts[page]
        var used = 0.0, end = start
        while end < heights.count {
            used += max(1, heights[end]) + (end == start ? 0 : spacing)
            end += 1
            if used >= available { break }
        }
        // SwiftUI's fallback fonts can be shorter than the conservative measurements.
        // Render a small clipped buffer so pages still fill the available column.
        range = start..<min(heights.count, end + 2)
    }
}
