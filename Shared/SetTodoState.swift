import AppIntents
import WidgetKit

struct SetWidgetPage: AppIntent {
    static let title: LocalizedStringResource = "翻阅待办列表"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    @Parameter(title: "目标页") var page: Int
    @Parameter(title: "当前显示") var navigation: String

    init() {}
    init(page: Int, navigation: WidgetNavigation) {
        self.page = page
        self.navigation = String(data: (try? JSONEncoder().encode(navigation)) ?? Data(), encoding: .utf8) ?? ""
    }

    func perform() async throws -> some IntentResult {
        if let expected = try? JSONDecoder().decode(WidgetNavigation.self, from: Data(navigation.utf8)) {
            try TodoStore.shared().setWidgetPage(page, expected: expected)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TodoStore.widgetKind)
        return .result()
    }
}

struct SetPaymentExcluded: AppIntent {
    static let title: LocalizedStringResource = "移除或恢复款项"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "款项 ID") var paymentID: String
    @Parameter(title: "显示版本") var expectedToken: String
    @Parameter(title: "移除") var excluded: Bool

    init() {}
    init(_ payment: PendingPayment, excluded: Bool) {
        paymentID = payment.id; expectedToken = payment.actionToken; self.excluded = excluded
    }

    func perform() async throws -> some IntentResult {
        let store = try TodoStore.shared()
        do {
            if excluded { try store.removePayment(id: paymentID, expectedToken: expectedToken) }
            else { try store.restorePayment(id: paymentID, expectedToken: expectedToken) }
        } catch TodoStore.Failure.staleAction {
            // Refresh old buttons without applying an action to changed data.
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TodoStore.widgetKind)
        return .result()
    }
}

struct AdvancePayment: AppIntent {
    static let title: LocalizedStringResource = "推进款项进度"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "款项 ID") var paymentID: String
    @Parameter(title: "显示版本") var expectedToken: String

    init() {}
    init(_ payment: PendingPayment) {
        paymentID = payment.id
        expectedToken = payment.actionToken
    }

    func perform() async throws -> some IntentResult {
        do {
            try TodoStore.shared().advancePayment(id: paymentID, expectedToken: expectedToken)
        } catch TodoStore.Failure.staleAction {
            // A repeated click on the old timeline must never advance twice.
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TodoStore.widgetKind)
        return .result()
    }
}

struct SetTodoState: AppIntent {
    static let title: LocalizedStringResource = "更新待办"
    static let description = IntentDescription("从桌面标记待办完成或取消。")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "待办 ID") var taskID: String
    @Parameter(title: "已完成") var completed: Bool

    init() {}
    init(id: String, completed: Bool) {
        taskID = id
        self.completed = completed
    }

    func perform() async throws -> some IntentResult {
        try TodoStore.shared().setState(completed ? .done : .cancelled, id: taskID, onlyIfOpen: true)
        WidgetCenter.shared.reloadTimelines(ofKind: TodoStore.widgetKind)
        return .result()
    }
}


struct SetTodoScope: AppIntent {
    static let title: LocalizedStringResource = "筛选桌面待办"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "显示范围") var scope: String

    init() {}
    init(_ scope: TodoBoardScope) { self.scope = scope.rawValue }

    func perform() async throws -> some IntentResult {
        if let value = TodoBoardScope(rawValue: scope) {
            try TodoStore.shared().setWidgetScope(value)
            WidgetCenter.shared.reloadTimelines(ofKind: TodoStore.widgetKind)
        }
        return .result()
    }
}


struct SetPaymentScope: AppIntent {
    static let title: LocalizedStringResource = "筛选请款与付款"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "款项阶段") var scope: String

    init() {}
    init(_ scope: PaymentScope) { self.scope = scope.rawValue }

    func perform() async throws -> some IntentResult {
        if let value = PaymentScope(rawValue: scope) {
            try TodoStore.shared().setPaymentScope(value)
            WidgetCenter.shared.reloadTimelines(ofKind: TodoStore.widgetKind)
        }
        return .result()
    }
}
