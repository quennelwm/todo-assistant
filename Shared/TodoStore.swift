import Foundation
import Darwin

struct WidgetAppearanceSettings: Codable {
    var backingTransparency = 45
    var cardTransparency = 0

    var backingOpacity: Double { Self.opacity(for: backingTransparency) }
    var cardOpacity: Double { Self.opacity(for: cardTransparency) }

    private static func opacity(for transparency: Int) -> Double {
        1 - Double(min(100, max(0, transparency))) / 100
    }
}

struct TodoStore {
    let directory: URL

    private var appearancePreference: URL { directory.appending(path: "WidgetAppearance.json") }

    func widgetAppearance() -> WidgetAppearanceSettings {
        if let data = try? Data(contentsOf: appearancePreference),
           let appearance = try? JSONDecoder().decode(WidgetAppearanceSettings.self, from: data),
           (0...100).contains(appearance.backingTransparency),
           (0...100).contains(appearance.cardTransparency) {
            return appearance
        }
        var appearance = WidgetAppearanceSettings()
        let legacy = directory.appending(path: "WidgetTransparency.txt")
        if let value = try? String(contentsOf: legacy, encoding: .utf8),
           let percent = Int(value), (0...100).contains(percent) {
            appearance.backingTransparency = percent
        }
        return appearance
    }

    func setWidgetAppearance(_ appearance: WidgetAppearanceSettings) throws {
        try withLock {
            let data = try JSONEncoder().encode(appearance)
            try data.write(to: appearancePreference, options: .atomic)
        }
    }
    static let widgetKind = "LocalDesktopTodo"
    static let scheme = "todo-assistant"

    static var boardURL: URL { URL(string: "\(scheme)://board")! }

    static func boardURL(scope: TodoBoardScope) -> URL {
        var components = URLComponents(url: boardURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "scope", value: scope.rawValue)]
        return components.url!
    }

    static func detailURL(id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "detail"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }

    static func paymentDetailURL(id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "payment"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }

    enum Failure: LocalizedError {
        case groupUnavailable, itemMissing, invalidPublication, olderPublication, staleAction, eventCollision
        var errorDescription: String? {
            switch self {
            case .groupUnavailable: "无法打开 App 与桌面小组件共用的本地存储。"
            case .itemMissing: "这条记录已变更，请刷新后重试。"
            case .invalidPublication: "发布文件格式不完整或有重复 ID。"
            case .olderPublication: "读到较早的版本，保留现有数据。"
            case .staleAction: "当前状态已变更，请刷新后重试。"
            case .eventCollision: "操作记录有同名但内容不同的事件，原件已保留。"
            }
        }
    }

    static func shared() throws -> Self {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TodoAppGroup") as? String,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw Failure.groupUnavailable }
        return Self(directory: url)
    }

    private var snapshot: URL { directory.appending(path: "Todos.json") }

    private var paymentFile: URL { directory.appending(path: "IntegratedPayments.json") }

    private func loadPayments() throws -> PaymentCache? {
        do {
            return try JSONDecoder().decode(PaymentCache.self, from: Data(contentsOf: paymentFile))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    var pendingPayments: PendingPaymentList {
        do {
            guard let cache = try loadPayments() else { return .notConnected }
            return .ready(cache.rows)
        } catch { return .unavailable }
    }

    func paymentScope() -> PaymentScope? {
        let file = directory.appending(path: "PaymentScope.txt")
        return (try? String(contentsOf: file, encoding: .utf8)).flatMap(PaymentScope.init)
    }

    func setPaymentScope(_ scope: PaymentScope) throws {
        try withLock {
            try resetWidgetNavigation(scope: widgetScope(), paymentScope: scope)
            try Data(scope.rawValue.utf8).write(to: directory.appending(path: "PaymentScope.txt"), options: .atomic)
        }
    }

    func widgetScope() -> TodoBoardScope {
        let file = directory.appending(path: "WidgetScope.txt")
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let scope = TodoBoardScope(rawValue: raw) else { return .all }
        return scope
    }

    func setWidgetScope(_ scope: TodoBoardScope) throws {
        try withLock {
            try resetWidgetNavigation(scope: scope, paymentScope: paymentScope() ?? pendingPayments.initialScope)
            try Data(scope.rawValue.utf8).write(to: directory.appending(path: "WidgetScope.txt"), options: .atomic)
        }
    }

    func widgetNavigation() -> WidgetNavigation {
        let scope = widgetScope()
        let payment = scope == .payment ? (paymentScope() ?? pendingPayments.initialScope).rawValue : nil
        if let data = try? Data(contentsOf: directory.appending(path: "WidgetNavigation.json")),
           let value = try? JSONDecoder().decode(WidgetNavigation.self, from: data),
           value.scope == scope.rawValue, value.paymentScope == payment {
            return value
        }
        return WidgetNavigation(scope: scope.rawValue, paymentScope: payment)
    }

    private func resetWidgetNavigation(scope: TodoBoardScope, paymentScope: PaymentScope) throws {
        let value = WidgetNavigation(scope: scope.rawValue, paymentScope: scope == .payment ? paymentScope.rawValue : nil,
                                     revision: UUID().uuidString)
        try JSONEncoder().encode(value).write(to: directory.appending(path: "WidgetNavigation.json"), options: .atomic)
    }

    func setWidgetPage(_ page: Int, expected: WidgetNavigation) throws {
        try withLock {
            guard widgetNavigation() == expected else { return }
            var value = expected
            value.page = max(0, page)
            value.revision = UUID().uuidString
            try JSONEncoder().encode(value).write(to: directory.appending(path: "WidgetNavigation.json"), options: .atomic)
        }
    }

    func load() throws -> [TodoItem] {
        do { return try JSONDecoder().decode([TodoItem].self, from: Data(contentsOf: snapshot)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
    }

    private func withLock<T>(_ update: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appending(path: "Todos.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        defer { flock(lock, LOCK_UN) }
        return try update()
    }

    private func transaction<T>(_ update: (inout [TodoItem]) throws -> T) throws -> T {
        try withLock {
            let previous = try load()
            var items = previous
            let result = try update(&items)
            if items != previous {
                try JSONEncoder().encode(items).write(to: snapshot, options: .atomic)
            }
            return result
        }
    }

    func merge(_ incoming: [SourceTask]) throws {
        try merge(incoming, master: nil)
    }

    func merge(_ master: TodoMaster) throws {
        try merge(master.tasks, master: master)
    }

    private func merge(_ incoming: [SourceTask], master: TodoMaster?) throws {
        try transaction { items in
            if let master, let current = items.first(where: { $0.inMaster == true }),
               let version = current.masterVersion, let date = current.source.revision,
               Self.isOlder(date: master.publishedAt, version: master.version, than: date, version: version) {
                throw Failure.olderPublication
            }
            // Once connected, only the master can update the list.
            if master == nil && items.contains(where: { $0.masterVersion != nil }) { return }
            if master != nil {
                for index in items.indices { items[index].inMaster = false }
            }
            for task in incoming {
                let keys = Set([task.id] + task.aliases)
                let matches = items.indices.filter {
                    !keys.isDisjoint(with: [items[$0].id] + items[$0].source.aliases)
                }
                guard let index = matches.first else {
                    var item = TodoItem(source: task)
                    item.masterID = master.map { _ in task.id }
                    item.masterVersion = master?.version
                    item.inMaster = master.map { _ in true }
                    items.append(item)
                    continue
                }
                var row = items[index]
                let existing = row.source
                let older = master == nil && (task.revision ?? .distantPast) < (existing.revision ?? .distantPast)
                var source = older ? existing : task
                source.id = row.id
                source.originalText = source.originalText ?? existing.originalText
                source.aliases = Set([task.id] + task.aliases + matches.flatMap {
                    [items[$0].id] + items[$0].source.aliases
                }).subtracting([row.id]).sorted()
                source.evidence = (task.evidence + matches.flatMap { items[$0].source.evidence })
                    .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                row.source = source
                for duplicate in matches.dropFirst() {
                    let other = items[duplicate].manual
                    row.locallyCreated = (row.locallyCreated == true || items[duplicate].locallyCreated == true) ? true : row.locallyCreated
                    row.manual.title = row.manual.title ?? other.title
                    row.manual.notes = row.manual.notes ?? other.notes
                    row.manual.owner = row.manual.owner ?? other.owner
                    row.manual.contact = row.manual.contact ?? other.contact
                    row.manual.lane = row.manual.lane ?? other.lane
                    row.manual.pinned = row.manual.pinned ?? other.pinned
                    row.manual.priority = row.manual.priority ?? other.priority
                    if row.manual.state == nil {
                        row.manual.state = other.state
                        row.manual.stateChangedAt = other.stateChangedAt
                        row.manual.stateEventID = other.stateEventID
                    }
                    if let queued = items[duplicate].outbox {
                        let retained = Set((row.outbox ?? []).map(\.event_id))
                        row.outbox = (row.outbox ?? []) + queued.filter { !retained.contains($0.event_id) }
                    }
                    if !row.manual.dueEdited && other.dueEdited {
                        row.manual.dueEdited = true
                        row.manual.due = other.due
                    }
                }
                if let master {
                    row.masterID = task.id
                    row.masterVersion = master.version
                    row.inMaster = true
                    row.trackConflicts(previous: existing)
                }
                items[index] = row
                for duplicate in matches.dropFirst().reversed() { items.remove(at: duplicate) }
            }
        }
    }

    @discardableResult
    func createTask(_ draft: NewTodoDraft) throws -> TodoItem {
        let source = try draft.source()
        return try transaction { items in
            if let existing = items.first(where: { $0.id == draft.id }) {
                guard existing.locallyCreated == true else { throw Failure.staleAction }
                return existing
            }
            var item = TodoItem(source: source)
            item.locallyCreated = true
            item.manual.title = source.title
            item.manual.notes = source.notes ?? ""
            item.manual.owner = source.owner ?? ""
            item.manual.contact = source.contact ?? ""
            item.manual.lane = source.lane
            item.manual.state = .open
            item.manual.due = source.due; item.manual.dueEdited = true
            item.manual.priority = source.priority
            let event = TodoOperation(task: item, version: items.first(where: { $0.inMaster == true })?.masterVersion)
            item.outbox = [event]
            items.append(item)
            return item
        }
    }

    @discardableResult
    func setState(_ state: TodoState, id: String, onlyIfOpen: Bool = false) throws -> String? {
        try changeItem(id) { row in
            if onlyIfOpen && row.state != .open { return }
            if row.state != state {
                row.manual.state = state
                row.manual.stateChangedAt = .now
            }
        }
    }

    func setPlanning(id: String, pinned: Bool? = nil, priority: TodoPriority? = nil) throws {
        _ = try changeItem(id) { row in
            if let pinned { row.manual.pinned = pinned }
            if let priority { row.manual.priority = priority }
        }
    }

    func undoState(id: String, eventID: String, previous: TodoItem.Manual, previousState: TodoState) throws {
        _ = try changeItem(id, reverts: eventID) { row in
            guard row.manual.stateEventID == eventID else { throw Failure.staleAction }
            row.manual.state = row.source.state == previousState ? previous.state : previousState
            row.manual.stateChangedAt = previous.stateChangedAt
        }
    }

    func edit(id: String, owner: String?, contact: String?, lane: TodoLane?, due: String?,
              dueEdited: Bool = true, state: TodoState?, title: String? = nil, notes: String? = nil) throws {
        _ = try changeItem(id) { row in
            if let title {
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { throw TodoInputError(message: "事项内容不能为空。") }
                row.manual.title = title
            }
            if let notes { row.manual.notes = notes }
            if let owner { row.manual.owner = owner }
            if let contact { row.manual.contact = contact }
            if let lane { row.manual.lane = lane }
            if let state, row.state != state {
                row.manual.state = state
                row.manual.stateChangedAt = .now
            }
            if dueEdited {
                row.manual.due = due
                row.manual.dueEdited = true
            }
        }
    }

    private func changeItem(_ id: String, reverts: String? = nil,
                            _ edit: (inout TodoItem) throws -> Void) throws -> String? {
        try transaction { items in
            guard let index = items.firstIndex(where: { $0.id == id || $0.source.aliases.contains(id) })
            else { throw Failure.itemMissing }
            let before = items[index]
            var row = before
            try edit(&row)
            let stateAction: TodoOperation.Action = switch row.state {
            case .done: .complete
            case .cancelled: .cancel
            default: .restore
            }
            let fields: [(String, TodoOperation.Action, String?, String?)] = [
                ("title", .changeTitle, before.title, row.title),
                ("notes", .changeNotes, before.notes, row.notes),
                ("state", reverts == nil ? stateAction : .undo, before.state.rawValue, row.state.rawValue),
                ("due", .reschedule, before.due, row.due),
                ("owner", .changeOwner, before.owner, row.owner),
                ("contact", .changeContact, before.contact, row.contact),
                ("lane", .changeLane, before.lane.rawValue, row.lane.rawValue),
                ("priority", .changePriority, before.priority.rawValue, row.priority.rawValue),
                ("pinned", .changePin, String(before.isPinned), String(row.isPinned))
            ]
            var stateEventID: String?
            for (field, action, old, new) in fields where old != new {
                let event = TodoOperation(itemID: row.masterID ?? row.id, action: action, field: field,
                                          before: old, after: new, version: row.masterVersion, reverts: reverts)
                row.outbox = (row.outbox ?? []) + [event]
                row.conflicts?.removeAll { $0 == field }
                if field == "state" {
                    stateEventID = event.event_id
                    row.manual.stateEventID = event.event_id
                }
            }
            items[index] = row
            return stateEventID
        }
    }

    func mergePayments(_ publication: PublishedPayments) throws {
        try publication.validate()
        try withLock {
            var cache = try loadPayments() ?? PaymentCache(source: publication)
            if let previous = TodoClock.parse(cache.source.updated_at), let incoming = TodoClock.parse(publication.updated_at),
               Self.isOlder(date: incoming, version: publication.version, than: previous, version: cache.source.version) {
                throw Failure.olderPublication
            }
            let before = cache
            cache.retained = cache.originals.filter { old in
                !publication.items.contains { $0.id == old.id } &&
                    (cache.overrides[old.id] != nil || (cache.history ?? []).contains { $0.item_id == old.id })
            }
            cache.source = publication
            for item in publication.items {
                guard var change = cache.overrides[item.id] else { continue }
                var baseline = change.baseline
                var conflicts = Set(change.conflictingFields ?? (change.conflict ? ["stage"] : []))
                for key in change.values.keys {
                    if key == "project" { conflicts.remove(key); continue }
                    let incoming = item.editableFields[key] ?? nil
                    let manual = change.values[key] ?? nil
                    let previous = baseline[key] ?? nil
                    if incoming == manual {
                        conflicts.remove(key)
                    } else if incoming != previous {
                        conflicts.insert(key)
                    }
                    baseline.updateValue(incoming, forKey: key)
                }
                // Keep confirmed fields even after the source acknowledges them.
                change.sourceFields = baseline
                change.conflictingFields = conflicts.sorted()
                change.conflict = !conflicts.isEmpty
                cache.overrides[item.id] = change
            }
            if cache != before || !FileManager.default.fileExists(atPath: paymentFile.path) {
                try JSONEncoder().encode(cache).write(to: paymentFile, options: .atomic)
            }
        }
    }

    func confirmPaymentStage(id: String, expected: PaymentStage, next: PaymentStage) throws {
        try withLock {
            guard var cache = try loadPayments(), let source = cache.source.items.first(where: { $0.id == id })
            else { throw Failure.itemMissing }
            let change = cache.overrides[id]
            let stage = change?.stage ?? source.stage
            guard change?.conflict != true, stage == expected, stage.userNextStage == next
            else { throw Failure.staleAction }
            let event = TodoOperation(itemID: id, kind: .payment, action: .changePaymentStage, field: "stage",
                                      before: stage.rawValue, after: next.rawValue, version: cache.source.version)
            var fields = change?.values ?? [:]
            fields["stage"] = next.rawValue
            cache.overrides[id] = PaymentCache.Override(stage: next, sourceStage: source.stage,
                                                       fields: fields, sourceFields: source.editableFields)
            cache.history = (cache.history ?? []) + [event]
            cache.outbox.append(event)
            try JSONEncoder().encode(cache).write(to: paymentFile, options: .atomic)
        }
    }

    func paymentHistory(id: String) throws -> [TodoOperation] {
        (try loadPayments()?.history ?? []).filter { $0.item_id == id }
    }

    func removePayment(id: String, expectedToken: String) throws {
        try setPaymentExcluded(id: id, expectedToken: expectedToken, excluded: true)
    }

    func restorePayment(id: String, expectedToken: String) throws {
        try setPaymentExcluded(id: id, expectedToken: expectedToken, excluded: false)
    }

    private func setPaymentExcluded(id: String, expectedToken: String, excluded: Bool) throws {
        try withLock {
            guard var cache = try loadPayments(), let current = cache.rows.first(where: { $0.id == id })
            else { throw Failure.itemMissing }
            guard !expectedToken.isEmpty, current.actionToken == expectedToken,
                  excluded ? (!current.isRemoved && current.scope == .verification) : current.isRemoved
            else { throw Failure.staleAction }
            let event = TodoOperation(paymentID: id, action: excluded ? .removePayment : .restore,
                                      before: ["excluded": excluded ? "false" : "true"],
                                      after: ["excluded": excluded ? "true" : "false"],
                                      note: nil, version: cache.source.version,
                                      reverts: excluded ? nil : current.removalEventID)
            var removals = cache.removals ?? [:]
            if excluded {
                removals[id] = PaymentCache.Removal(eventID: event.event_id, date: event.occurred_at)
            } else {
                removals.removeValue(forKey: id)
            }
            cache.removals = removals
            cache.history = (cache.history ?? []) + [event]
            cache.outbox.append(event)
            try JSONEncoder().encode(cache).write(to: paymentFile, options: .atomic)
        }
    }

    func advancePayment(id: String, expectedToken: String) throws {
        try withLock {
            guard var cache = try loadPayments(),
                  let current = cache.rows.first(where: { $0.id == id }),
                  let source = cache.originals.first(where: { $0.id == id }) else { throw Failure.itemMissing }
            guard !expectedToken.isEmpty, current.actionToken == expectedToken,
                  let next = current.quickNextStage else { throw Failure.staleAction }
            var fields = cache.overrides[id]?.values ?? [:]
            fields["stage"] = next.rawValue
            if next == .paid {
                if let total = PaymentDraft.decimal(current.amount), total > 0 {
                    fields.updateValue(current.amount, forKey: "paid_amount")
                } else {
                    fields.updateValue(nil, forKey: "paid_amount")
                }
                fields["remaining_amount"] = "0"
            }
            _ = recordPayment(in: &cache, source: source, current: current, fields: fields,
                              note: nil, action: .changePaymentStage)
            try JSONEncoder().encode(cache).write(to: paymentFile, options: .atomic)
        }
    }

    func renamePayment(expected: PendingPayment, name: String) throws {
        guard let name = PaymentDraft.clean(name) else { throw TodoInputError(message: "请填写款项名称。") }
        try withLock {
            guard var cache = try loadPayments(),
                  let current = cache.rows.first(where: { $0.id == expected.id }),
                  let source = cache.originals.first(where: { $0.id == expected.id }) else { throw Failure.itemMissing }
            guard current == expected, !current.isRemoved else { throw Failure.staleAction }
            guard current.project != name else { return }
            let previous = cache.overrides[current.id]
            var fields = previous?.values ?? [:]
            fields["project"] = name
            _ = recordPayment(in: &cache, source: source, current: current, fields: fields, note: nil, action: .changeTitle)
            // A display-name edit must not acknowledge any financial discrepancy.
            if let previous, var updated = cache.overrides[current.id] {
                updated.conflict = previous.conflict
                updated.conflictingFields = previous.conflictingFields
                updated.sourceFields = previous.baseline
                updated.sourceFields?["project"] = source.project
                cache.overrides[current.id] = updated
            }
            try JSONEncoder().encode(cache).write(to: paymentFile, options: .atomic)
        }
    }

    @discardableResult
    func verifyPayment(expected: PendingPayment, draft: PaymentDraft) throws -> String {
        let fields = try draft.validatedFields()
        return try withLock {
            guard var cache = try loadPayments(),
                  let current = cache.rows.first(where: { $0.id == expected.id }),
                  let source = cache.originals.first(where: { $0.id == expected.id }) else { throw Failure.itemMissing }
            guard current == expected, !current.isRemoved else { throw Failure.staleAction }
            let event = recordPayment(in: &cache, source: source, current: current, fields: fields,
                                      note: PaymentDraft.clean(draft.note), action: .verifyPayment)
            try JSONEncoder().encode(cache).write(to: paymentFile, options: .atomic)
            return event
        }
    }

    func undoPayment(expected: PendingPayment, eventID: String) throws {
        try withLock {
            guard var cache = try loadPayments(),
                  let current = cache.rows.first(where: { $0.id == expected.id }),
                  let source = cache.originals.first(where: { $0.id == expected.id }) else { throw Failure.itemMissing }
            guard current == expected, current.conflict != true, !current.isRemoved,
                  let event = (cache.history ?? []).last(where: { $0.item_id == expected.id }),
                  event.event_id == eventID, [.verifyPayment, .changePaymentStage, .changeTitle].contains(event.action),
                  event.after.allSatisfy({ (current.editableFields[$0.key] ?? nil) == $0.value })
            else { throw Failure.staleAction }
            let snapshot = cache.undoSnapshots?[eventID]
            if let snapshot, snapshot.sourceFields != source.editableFields { throw Failure.staleAction }
            var fields = current.editableFields
            for (key, value) in event.before { fields.updateValue(value, forKey: key) }
            _ = recordPayment(in: &cache, source: source, current: current, fields: fields,
                              note: "撤销上次记录：" + (event.note ?? "款项阶段变更"), action: .undo, reverts: eventID)
            if let snapshot {
                cache.overrides[current.id] = snapshot.previousOverride
            }
            try JSONEncoder().encode(cache).write(to: paymentFile, options: .atomic)
        }
    }

    private func recordPayment(in cache: inout PaymentCache, source: PendingPayment, current: PendingPayment,
                               fields: [String: String?], note: String?, action: TodoOperation.Action,
                               reverts: String? = nil) -> String {
        var before: [String: String?] = [:], after: [String: String?] = [:]
        for (key, value) in fields where (current.editableFields[key] ?? nil) != value {
            before.updateValue(current.editableFields[key] ?? nil, forKey: key)
            after.updateValue(value, forKey: key)
        }
        let event = TodoOperation(paymentID: current.id, action: action, before: before, after: after,
                                  note: note, version: cache.source.version, reverts: reverts)
        var undoSnapshots = cache.undoSnapshots ?? [:]
        undoSnapshots[event.event_id] = PaymentCache.UndoSnapshot(previousOverride: cache.overrides[current.id],
                                                                 sourceFields: source.editableFields)
        cache.undoSnapshots = undoSnapshots
        let stage = PaymentStage(rawValue: (fields["stage"] ?? nil) ?? "") ?? current.stage
        cache.overrides[current.id] = PaymentCache.Override(stage: stage, sourceStage: source.stage,
                                                            fields: fields, sourceFields: source.editableFields)
        cache.history = (cache.history ?? []) + [event]
        cache.outbox.append(event)
        return event.event_id
    }

    func publishOperations(to destination: URL) throws {
        try withLock {
            var items = try load()
            let previousItems = items
            var failure: Error?
            var payments: PaymentCache?
            do { payments = try loadPayments() }
            catch { failure = error }
            let previousPayments = payments
            func undelivered(_ events: [TodoOperation]) -> [TodoOperation] {
                events.filter { event in
                    do {
                        try publish(event, to: destination)
                        return false
                    } catch {
                        failure = failure ?? error
                        return true
                    }
                }
            }
            for index in items.indices {
                guard let events = items[index].outbox, !events.isEmpty else { continue }
                let pending = undelivered(events)
                items[index].outbox = pending.isEmpty ? nil : pending
            }
            if let events = payments?.outbox, !events.isEmpty {
                payments?.outbox = undelivered(events)
            }
            if items != previousItems {
                try JSONEncoder().encode(items).write(to: snapshot, options: .atomic)
            }
            if let payments, payments != previousPayments {
                try JSONEncoder().encode(payments).write(to: paymentFile, options: .atomic)
            }
            if let failure { throw failure }
        }
    }

    private static func isOlder(date: Date, version: String, than currentDate: Date, version currentVersion: String) -> Bool {
        date < currentDate || (date == currentDate && version.compare(currentVersion, options: .numeric) == .orderedAscending)
    }

    private func publish(_ event: TodoOperation, to destination: URL) throws {
        // The integration owns the directory. A missing directory is retried as a delivery failure.
        let file = destination.appending(path: "\(event.event_id).json")
        do {
            let existing = try JSONDecoder().decode(TodoOperation.self, from: Data(contentsOf: file))
            guard existing == event else { throw Failure.eventCollision }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            try JSONEncoder().encode(event).write(to: file, options: .atomic)
        }
    }
}

private extension TodoItem {
    mutating func trackConflicts(previous: SourceTask) {
        var pending = Set(conflicts ?? [])
        let compared: [(String, Bool, String?, String?, String?)] = [
            ("title", manual.title != nil, previous.displayTitle ?? previous.title, source.displayTitle ?? source.title, title),
            ("notes", manual.notes != nil, previous.notes, source.notes, notes),
            ("state", manual.state != nil, previous.state.rawValue, source.state.rawValue, state.rawValue),
            ("due", manual.dueEdited, previous.due, source.due, due),
            ("owner", manual.owner != nil, previous.owner, source.owner, owner),
            ("contact", manual.contact != nil, previous.contact, source.contact, contact),
            ("lane", manual.lane != nil, previous.lane.rawValue, source.lane.rawValue, lane.rawValue),
            ("priority", manual.priority != nil, (previous.priority ?? .normal).rawValue,
             (source.priority ?? .normal).rawValue, priority.rawValue)
        ]
        for (field, overridden, old, new, local) in compared {
            if !overridden || new == local {
                pending.remove(field)
            } else if old != new {
                pending.insert(field)
            }
        }
        conflicts = pending.isEmpty ? nil : pending.sorted()
    }
}
