import Foundation
import CryptoKit

struct TodoMaster {
    let version: String
    let publishedAt: Date
    let tasks: [SourceTask]
}

struct TodoOperation: Codable, Equatable {
    enum Kind: String, Codable { case task, payment }
    enum Action: String, Codable {
        case complete, cancel, restore, reschedule, undo
        case changeOwner = "change_owner"
        case changeContact = "change_contact"
        case changeLane = "change_lane"
        case changePriority = "change_priority"
        case changePin = "change_pin"
        case changePaymentStage = "change_payment_stage"
        case verifyPayment = "verify_payment"
        case removePayment = "remove_payment"
        case createTask = "create_task"
        case changeTitle = "change_title"
        case changeNotes = "change_notes"
    }

    var schema_version = 1
    let event_id: String
    let item_id: String
    let item_type: Kind
    let action: Action
    let before: [String: String?]
    let after: [String: String?]
    let occurred_at: String
    let recorded_at: String
    let actor: String
    let base_version: String?
    let reverts_event_id: String?
    var note: String? = nil

    init(itemID: String, kind: Kind = .task, action: Action, field: String,
         before: String?, after: String?, version: String?, reverts: String? = nil, at date: Date = .now) {
        event_id = UUID().uuidString.lowercased()
        item_id = itemID
        item_type = kind
        self.action = action
        self.before = [field: before]
        self.after = [field: after]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TodoClock.zone
        occurred_at = formatter.string(from: date)
        recorded_at = occurred_at
        actor = "我"
        base_version = version
        reverts_event_id = reverts
    }

    private enum CodingKeys: String, CodingKey {
        case schema_version, event_id, item_id, item_type, action, before, after
        case occurred_at, recorded_at, actor, base_version, reverts_event_id, note
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(schema_version, forKey: .schema_version)
        try fields.encode(event_id, forKey: .event_id)
        try fields.encode(item_id, forKey: .item_id)
        try fields.encode(item_type, forKey: .item_type)
        try fields.encode(action, forKey: .action)
        try fields.encode(before, forKey: .before)
        try fields.encode(after, forKey: .after)
        try fields.encode(occurred_at, forKey: .occurred_at)
        try fields.encode(recorded_at, forKey: .recorded_at)
        try fields.encode(actor, forKey: .actor)
        try fields.encode(base_version, forKey: .base_version)
        try fields.encodeIfPresent(reverts_event_id, forKey: .reverts_event_id)
        try fields.encodeIfPresent(note, forKey: .note)
    }

    init(paymentID: String, action: Action, before: [String: String?], after: [String: String?],
         note: String?, version: String, reverts: String? = nil) {
        event_id = UUID().uuidString.lowercased()
        item_id = paymentID; item_type = .payment; self.action = action
        self.before = before; self.after = after; self.note = note
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TodoClock.zone
        occurred_at = formatter.string(from: .now); recorded_at = occurred_at
        actor = "我"; base_version = version; reverts_event_id = reverts
    }

    init(task: TodoItem, version: String?) {
        event_id = UUID().uuidString.lowercased()
        item_id = task.id; item_type = .task; action = .createTask
        before = [:]
        after = ["title": task.title, "notes": task.notes, "owner": task.owner, "contact": task.contact,
                 "lane": task.lane.rawValue, "due": task.due, "state": task.state.rawValue,
                 "priority": task.priority.rawValue, "source": "手动"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TodoClock.zone
        occurred_at = formatter.string(from: .now); recorded_at = occurred_at
        actor = "我"; base_version = version; reverts_event_id = nil
    }
}

enum PaymentStage: String, Codable, CaseIterable {
    case verify = "待核实", apply = "待申请", submitted = "已提交", approving = "审批中"
    case pay = "待付款", paid = "已付款", returned = "已退回", withdrawn = "已撤销"

    // Legacy values remain decodable for source records and the audit log.
    static var selectableCases: [Self] { [.apply, .pay, .paid, .verify] }

    var editorStage: Self {
        switch self {
        case .apply, .returned: .apply
        case .submitted, .approving, .pay: .pay
        case .paid: .paid
        case .verify, .withdrawn: .verify
        }
    }

    var title: String {
        switch editorStage {
        case .apply: "待请款"
        case .pay: "待付款"
        case .paid: "已付款"
        default: "待核实"
        }
    }

    var scope: PaymentScope {
        switch self {
        case .apply, .returned: .application
        case .submitted, .approving, .pay: .payment
        case .verify: .verification
        case .paid, .withdrawn: .history
        }
    }

    var userNextStage: Self? {
        switch self {
        case .apply, .returned: .submitted
        case .pay: .paid
        default: nil
        }
    }
}

enum PaymentScope: String, CaseIterable, Identifiable {
    case application = "待请款", payment = "待付款", history = "历史", verification = "待核实"
    var id: Self { self }
    var title: String { self == .history ? "已付款" : rawValue }
    func countLabel(_ count: Int) -> String {
        let label: String
        switch self {
        case .application: label = "待请"
        case .payment: label = "待付"
        case .history: label = "已付"
        case .verification: label = "待审"
        }
        return "\(count) 项\(label)"
    }

}

struct PaymentValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PaymentDraft {
    var project: String
    var stage: PaymentStage
    var counterparty: String
    var amount: String
    var currency: String
    var applicationID: String
    var due: String
    var paidAmount: String
    var remainingAmount: String
    var note = ""

    init(_ item: PendingPayment) {
        project = item.project
        stage = item.stage.editorStage; counterparty = item.counterparty ?? ""
        amount = item.amount ?? ""; currency = item.currency ?? ""
        applicationID = item.application_id ?? ""; due = item.due ?? ""
        paidAmount = item.paid_amount ?? ""; remainingAmount = item.remaining_amount ?? ""
    }

    static func decimal(_ value: String?) -> Decimal? {
        guard let value, value.range(of: #"^\d{1,20}(\.\d{1,6})?$"#, options: .regularExpression) != nil
        else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func validatedFields() throws -> [String: String?] {
        func fail(_ message: String) throws -> Never { throw PaymentValidationError(message: message) }
        guard let project = Self.clean(project) else { try fail("请填写款项名称。") }
        let totalText = Self.clean(amount), paidText = Self.clean(paidAmount), remainingText = Self.clean(remainingAmount)
        for (label, value) in [("金额", totalText), ("已付金额", paidText), ("未付金额", remainingText)] {
            if let value, Self.decimal(value) == nil { try fail("\(label)请填写非负数字，不含货币符号或千位逗号。") }
        }
        let total = Self.decimal(totalText)
        let currencyText = Self.clean(currency)?.uppercased()
        if let currencyText, currencyText.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) == nil {
            try fail("币种请填写三个字母，例如 CNY。")
        }
        if stage != .verify && stage != .withdrawn {
            guard let total, total > 0, currencyText != nil, Self.clean(counterparty) != nil else {
                try fail("离开待核实前，请补齐收款方、正数金额和币种；仍不清楚可保留待核实。")
            }
        }
        if let due = Self.clean(due), TodoClock.parse(due) == nil {
            try fail("日期请填写 YYYY-MM-DD，或带时区的完整时间。")
        }
        var paid = Self.decimal(paidText), remaining = Self.decimal(remainingText)
        var normalizedPaid = paidText, normalizedRemaining = remainingText
        if stage == .paid {
            // The explicit all-paid confirmation is the authority, not a guessed settlement.
            normalizedPaid = totalText; normalizedRemaining = "0"
            paid = total; remaining = 0
        } else if let total, let paid, remaining == nil {
            remaining = total - paid
            normalizedRemaining = NSDecimalNumber(decimal: total - paid).stringValue
        } else if let total, paid == nil, let remaining {
            paid = total - remaining
            normalizedPaid = NSDecimalNumber(decimal: total - remaining).stringValue
        }
        if let paid, paid < 0 { try fail("已付金额不能小于零。") }
        if let remaining, remaining < 0 { try fail("已付金额不能超过总金额。") }
        if let total, let paid, paid > total { try fail("已付金额不能超过总金额。") }
        if let total, let remaining, remaining > total { try fail("未付金额不能超过总金额。") }
        if let total, let paid, let remaining, paid + remaining != total {
            try fail("已付金额与未付金额之和必须等于总金额。")
        }
        if let paid, paid > 0, ![PaymentStage.verify, .pay, .paid, .withdrawn].contains(stage) {
            try fail("已有付款时请选择待付款（部分付款）、已付款或待核实。")
        }
        if stage == .pay, let total, paid == total { try fail("金额已全部付清，请确认后选择已付款。") }
        return ["project": project, "stage": stage.rawValue, "counterparty": Self.clean(counterparty), "amount": totalText,
                "currency": currencyText, "application_id": Self.clean(applicationID), "due": Self.clean(due),
                "paid_amount": normalizedPaid, "remaining_amount": normalizedRemaining]
    }
}

extension PaymentStage {
    var confirmationText: String {
        switch self {
        case .verify: "我确认目前仍有信息未核实"
        case .apply: "我确认本笔需要请款，尚未提交"
        case .submitted: "我确认本笔请款已提交成功"
        case .approving: "我确认本笔申请正在审批"
        case .pay: "本笔尚未付清，记录为待付款"
        case .paid: "我确认本笔款项已实际全部付清"
        case .returned: "我确认本笔申请已被退回，需重新处理"
        case .withdrawn: "我确认本笔已撤销，不再继续申请或付款"
        }
    }
}

struct PublishedPayments: Codable, Equatable {
    let schema_version: Int
    let version: String
    let updated_at: String
    let coverage: String
    let items: [PendingPayment]

    func validate() throws {
        guard schema_version == 1, !version.isEmpty, TodoClock.parse(updated_at) != nil,
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ !$0.id.isEmpty && !$0.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw TodoStore.Failure.invalidPublication }
    }
}

struct PendingPayment: Codable, Equatable, Identifiable {
    struct Evidence: Codable, Equatable {
        let source: String
        let refs: [String]
        let summary: String
    }

    let id: String
    var project: String
    var originalProject: String? = nil
    var counterparty: String?
    var amount: String?
    var currency: String?
    var stage: PaymentStage
    var application_id: String?
    var due: String?
    let evidence: [Evidence]
    let next_action: String?
    let linked_task_id: String?
    let updated_at: String
    var paid_amount: String?
    var remaining_amount: String?
    let shared_uncertainty_group: String?
    var conflict: Bool? = nil
    var sourceConflicts: [String: String?]? = nil
    var confirmationNote: String? = nil
    var confirmedAt: String? = nil
    var lastOperationID: String? = nil
    var removedAt: String? = nil
    var removalEventID: String? = nil
    var isRemoved: Bool { removedAt != nil }

    var scope: PaymentScope { conflict == true ? .verification : stage.scope }

    var quickNextStage: PaymentStage? {
        guard conflict != true, !isRemoved else { return nil }
        switch stage {
        case .apply, .returned: return .pay
        case .submitted, .approving, .pay: return .paid
        default: return nil
        }
    }

    var actionToken: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var displayStage: String {
        if conflict == true { return "待核实" }
        return stage.title
    }

    var editableFields: [String: String?] {
        ["project": project, "stage": stage.rawValue, "counterparty": counterparty, "amount": amount, "currency": currency,
         "application_id": application_id, "due": due, "paid_amount": paid_amount, "remaining_amount": remaining_amount]
    }

    func applying(_ fields: [String: String?]) -> Self {
        var row = self
        if let name = fields["project"] ?? nil { row.project = name }
        if let raw = fields["stage"] ?? nil, let stage = PaymentStage(rawValue: raw) { row.stage = stage }
        if fields.keys.contains("counterparty") { row.counterparty = fields["counterparty"] ?? nil }
        if fields.keys.contains("amount") { row.amount = fields["amount"] ?? nil }
        if fields.keys.contains("currency") { row.currency = fields["currency"] ?? nil }
        if fields.keys.contains("application_id") { row.application_id = fields["application_id"] ?? nil }
        if fields.keys.contains("due") { row.due = fields["due"] ?? nil }
        if fields.keys.contains("paid_amount") { row.paid_amount = fields["paid_amount"] ?? nil }
        if fields.keys.contains("remaining_amount") { row.remaining_amount = fields["remaining_amount"] ?? nil }
        return row
    }

    var formattedAmount: String {
        guard let amount, !amount.isEmpty else { return "金额待确认" }
        // Decimal keeps source precision; never round a payment through Double.
        guard amount.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else {
            return [currency, amount].compactMap { $0 }.joined(separator: " ")
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        let precision = amount.split(separator: ".").dropFirst().first?.count ?? 0
        formatter.minimumFractionDigits = min(precision, 2)
        formatter.maximumFractionDigits = max(2, precision)
        let value = formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? amount
        let prefix = currency == "CNY" ? "¥" : currency.map { $0 + " " } ?? ""
        return prefix + value
    }

    var summary: String {
        let amountText = amount.map { [currency, $0].compactMap { $0 }.joined(separator: " ") }
        return [displayStage, counterparty, amountText, due.map(TodoClock.label)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct PaymentCache: Codable, Equatable {
    struct Removal: Codable, Equatable {
        let eventID: String
        let date: String
    }
    struct UndoSnapshot: Codable, Equatable {
        let previousOverride: Override?
        let sourceFields: [String: String?]
    }
    struct Override: Codable, Equatable {
        let stage: PaymentStage
        let sourceStage: PaymentStage
        var conflict = false
        var fields: [String: String?]? = nil
        var sourceFields: [String: String?]? = nil
        var conflictingFields: [String]? = nil

        var values: [String: String?] { fields ?? ["stage": stage.rawValue] }
        var baseline: [String: String?] { sourceFields ?? ["stage": sourceStage.rawValue] }
    }

    var source: PublishedPayments
    var overrides: [String: Override] = [:]
    var outbox: [TodoOperation] = []
    var history: [TodoOperation]? = nil
    var retained: [PendingPayment]? = nil
    var undoSnapshots: [String: UndoSnapshot]? = nil
    var removals: [String: Removal]? = nil

    var originals: [PendingPayment] {
        source.items + (retained ?? []).filter { old in !source.items.contains { $0.id == old.id } }
    }

    var rows: [PendingPayment] {
        originals.map { item in
            var row = item
            row.removedAt = removals?[item.id]?.date
            row.removalEventID = removals?[item.id]?.eventID
            if let change = overrides[item.id] {
                row = row.applying(change.values)
                row.originalProject = row.project == item.project ? nil : item.project
                row.conflict = change.conflict
                if change.conflict {
                    let names = change.conflictingFields ?? ["stage"]
                    row.sourceConflicts = item.editableFields.filter { names.contains($0.key) }
                }
            }
            if let event = (history ?? []).last(where: { $0.item_id == item.id }) {
                row.confirmationNote = event.note
                row.confirmedAt = event.occurred_at
                row.lastOperationID = event.event_id
            }
            return row
        }
    }
}

enum PendingPaymentList: Equatable {
    case notConnected, unavailable, ready([PendingPayment])

    var rows: [PendingPayment] {
        if case let .ready(rows) = self { return rows.filter { !$0.isRemoved } }
        return []
    }

    var removedRows: [PendingPayment] {
        guard case let .ready(rows) = self else { return [] }
        return rows.filter(\.isRemoved).sorted {
            if $0.removedAt == $1.removedAt { return $0.id < $1.id }
            return ($0.removedAt ?? "") > ($1.removedAt ?? "")
        }
    }

    func rows(in scope: PaymentScope, withdrawn: Bool = false) -> [PendingPayment] {
        rows.filter { row in
            row.scope == scope && (scope != .history || row.stage == (withdrawn ? .withdrawn : .paid))
        }
    }

    var initialScope: PaymentScope {
        [PaymentScope.application, .payment, .verification, .history].first { scope in rows.contains { $0.scope == scope } } ?? .application
    }

    func emptyMessage(for scope: PaymentScope) -> String {
        switch self {
        case .notConnected: "待接入付款清单"
        case .unavailable: "暂时无法读取付款清单"
        case .ready: "暂无\(scope.title)记录"
        }
    }
}
