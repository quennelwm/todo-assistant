import AppKit
import SwiftUI
import WidgetKit

@MainActor
final class TodoModel: ObservableObject {
    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var pendingPayments: PendingPaymentList = .notConnected
    @Published private(set) var failures: [String] = []
    @Published private(set) var operationError: String?
    @Published private(set) var lastScan: Date?
    @Published private(set) var syncing = false
    @Published var editError: String?
    @Published var requestedScope: TodoBoardScope?
    @Published private(set) var undo: (item: TodoItem, state: TodoState, eventID: String)?

    private(set) var automaticUpdates = TodoAutomaticUpdateStatus()
    private var automaticTimer: Timer?
    private var operationTimer: Timer?
    private var publishingOperations = false
    private var lastAttempt: Date?

    init() {
        do {
            automaticUpdates = try TodoAutomaticUpdateStatus.load(from: TodoAutomaticUpdateStatus.file)
            lastScan = automaticUpdates.lastSuccessfulUpdate
        } catch {
            failures = [error.localizedDescription]
        }
    }

    func startAutomaticUpdates() {
        if let failure = saveAutomaticUpdateStatus() { failures.append(failure) }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishOperations() }
        }
        operationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        publishOperations()
        scheduleAutomaticUpdate()
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        guard automaticUpdates.enabled != enabled else { return }
        let previous = automaticUpdates
        automaticUpdates.enabled = enabled
        if let failure = saveAutomaticUpdateStatus() {
            automaticUpdates = previous
            failures.append(failure)
            return
        }

        scheduleAutomaticUpdate()
        if enabled { sync() }
    }

    private func scheduleAutomaticUpdate() {
        automaticTimer?.invalidate()
        automaticTimer = nil
        guard LocalSources.configured().isConfigured, let delay = automaticUpdates.delay(after: lastAttempt) else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automaticUpdates.enabled else { return }
                self.sync()
            }
        }
        automaticTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func saveAutomaticUpdateStatus() -> String? {
        do {
            try automaticUpdates.save(to: TodoAutomaticUpdateStatus.file)
            return nil
        } catch {
            return "自动更新状态保存失败。\(error.localizedDescription)"
        }
    }

    func sync() {
        guard !syncing else { return }
        syncing = true
        automaticTimer?.invalidate()
        automaticTimer = nil
        lastAttempt = .now
        Task {
            let outcome = await Task.detached(priority: .utility) {
                do {
                    let store = try TodoStore.shared()
                    let before = try store.load()
                    let payments = store.pendingPayments
                    let failures = LocalSources.configured().sync(to: store)
                    let after = try store.load()
                    return (failures, before != after || payments != store.pendingPayments)
                } catch {
                    return ([error.localizedDescription], false)
                }
            }.value
            refreshView()
            if outcome.1 { reloadWidget() }
            failures = outcome.0
            publishOperations()
            if failures.isEmpty {
                let previous = automaticUpdates
                automaticUpdates.lastSuccessfulUpdate = .now
                if let failure = saveAutomaticUpdateStatus() {
                    automaticUpdates = previous
                    failures.append(failure)
                } else {
                    lastScan = automaticUpdates.lastSuccessfulUpdate
                }
            }
            syncing = false
            scheduleAutomaticUpdate()
        }
    }

    @discardableResult
    func refreshView() -> Bool {
        do {
            let store = try TodoStore.shared()
            let payments = store.pendingPayments
            if payments != pendingPayments { pendingPayments = payments }
            let rows = try store.load()
            if rows != items { items = rows }
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    func changeState(_ state: TodoState, of item: TodoItem) -> Bool {
        var event: String?
        guard update({ event = try $0.setState(state, id: item.id, onlyIfOpen: state != .open) }),
              let event else { return false }
        if state == .open {
            if undo?.item.id == item.id { undo = nil }
        } else {
            undo = (item, state, event)
        }
        return true
    }

    func undoState() {
        guard let undo else { return }
        if update({
            try $0.undoState(id: undo.item.id, eventID: undo.eventID,
                             previous: undo.item.manual, previousState: undo.item.state)
        }) {
            self.undo = nil
        }
    }

    func advancePayment(_ payment: PendingPayment) {
        update { try $0.advancePayment(id: payment.id, expectedToken: payment.actionToken) }
    }

    func removePayment(_ payment: PendingPayment) {
        update { try $0.removePayment(id: payment.id, expectedToken: payment.actionToken) }
    }

    @discardableResult
    func restorePayment(_ payment: PendingPayment) -> Bool {
        update { try $0.restorePayment(id: payment.id, expectedToken: payment.actionToken) }
    }

    func verifyPayment(_ payment: PendingPayment, draft: PaymentDraft) -> Bool {
        update { _ = try $0.verifyPayment(expected: payment, draft: draft) }
    }

    func renamePayment(_ payment: PendingPayment, name: String) -> Bool {
        update { try $0.renamePayment(expected: payment, name: name) }
    }

    func undoPayment(_ payment: PendingPayment, eventID: String) -> Bool {
        update { try $0.undoPayment(expected: payment, eventID: eventID) }
    }

    func setPlanning(for item: TodoItem, pinned: Bool? = nil, priority: TodoPriority? = nil) {
        update { try $0.setPlanning(id: item.id, pinned: pinned, priority: priority) }
    }

    func save(_ draft: TodoDraft, item: TodoItem) -> Bool {
        update {
            try $0.edit(id: item.id, owner: draft.owner == (item.owner ?? "") ? nil : draft.owner,
                        contact: draft.contact == (item.contact ?? "") ? nil : draft.contact,
                        lane: draft.lane == item.lane ? nil : draft.lane,
                        due: draft.deadline, dueEdited: draft.deadline != item.due,
                        state: nil,
                        title: draft.title == item.title ? nil : draft.title,
                        notes: item.locallyCreated == true ? draft.notes : nil)
        }
    }

    func createTask(_ draft: NewTodoDraft) -> TodoItem? {
        var created: TodoItem?
        let success = update { created = try $0.createTask(draft) }
        return success ? created : nil
    }

    @discardableResult
    private func update(_ change: (TodoStore) throws -> Void) -> Bool {
        do {
            try change(TodoStore.shared())
            refreshView()
            reloadWidget()
            publishOperations()
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    private func publishOperations() {
        guard !publishingOperations else { return }
        publishingOperations = true
        let sources = LocalSources.configured()
        guard sources.isConfigured else { publishingOperations = false; return }
        Task {
            let error = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try TodoStore.shared().publishOperations(to: sources.operations)
                    return nil
                } catch {
                    return "操作已保存在本机，回传待重试。\(error.localizedDescription)"
                }
            }.value
            if operationError != error { operationError = error }
            publishingOperations = false
        }
    }

    func setWidgetAppearance(_ appearance: WidgetAppearanceSettings) throws {
        try TodoStore.shared().setWidgetAppearance(appearance)
        reloadWidget()
    }

    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: TodoStore.widgetKind)
    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let model = TodoModel()
    private var boardWindow: NSWindow?
    private var detailWindow: NSPanel?
    private var detailItemID: String?
    private var paymentWindows: [String: NSPanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.refreshView()
        model.startAutomaticUpdates()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "待办助手")
        item.button?.toolTip = "待办助手"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        statusItem = item
        if !UserDefaults.standard.bool(forKey: "HasOpenedAssistant") {
            UserDefaults.standard.set(true, forKey: "HasOpenedAssistant")
            openBoard(application: NSApplication.shared)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openBoard(application: sender)
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item); return item
        }
        _ = add("打开待办助手", #selector(showBoard))
        menu.addItem(.separator())
        let configured = LocalSources.configured().isConfigured
        _ = add(configured ? "已接入信息整合" : "手动模式 · 无需信息整合", nil)
        _ = add("选择信息整合目录…", #selector(selectIntegration))
        if configured {
            let toggle = add("每 30 分钟自动更新", #selector(toggleUpdates))
            toggle.state = model.automaticUpdates.enabled ? .on : .off
            let stamp = model.automaticUpdates.lastSuccessfulUpdate.map { TodoClock.label(TodoClock.timestamp($0)) } ?? "尚未更新"
            _ = add("最近更新：" + stamp, nil)
            _ = add("立即更新", #selector(syncNow))
            _ = add("停止接入（保留现有待办）", #selector(disconnectIntegration))
        }
        menu.addItem(.separator())
        _ = add("退出待办助手", #selector(quit))
    }

    @objc private func showBoard() { openBoard(application: NSApplication.shared) }
    @objc private func syncNow() { model.sync() }
    @objc private func toggleUpdates() { model.setAutomaticUpdates(!model.automaticUpdates.enabled) }
    @objc private func disconnectIntegration() {
        model.setAutomaticUpdates(false)
        UserDefaults.standard.removeObject(forKey: LocalSources.directoryKey)
        model.sync()
    }
    @objc private func selectIntegration() {
        let panel = NSOpenPanel()
        panel.title = "选择包含待办总表或款项清单的目录"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        NSApplication.shared.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: LocalSources.directoryKey)
        if model.automaticUpdates.enabled { model.sync() } else { model.setAutomaticUpdates(true) }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == TodoStore.scheme && url.host == "automatic-update" {
            switch url.path {
            case "/on": model.setAutomaticUpdates(true)
            case "/off": model.setAutomaticUpdates(false)
            case "/sync": model.sync()
            default: break
            }
        }
        guard let route = urls.first(where: { $0.scheme == TodoStore.scheme && ["board", "detail", "payment"].contains($0.host ?? "") })
        else { return }
        let parameters = URLComponents(url: route, resolvingAgainstBaseURL: false)?.queryItems
        if route.host == "payment" {
            if let id = parameters?.first(where: { $0.name == "id" })?.value {
                openPaymentDetail(id: id, application: application)
            }
            return
        }
        if route.host == "detail" {
            if let id = parameters?.first(where: { $0.name == "id" })?.value {
                openDetail(id: id, application: application)
            }
            return
        }

        if let raw = parameters?.first(where: { $0.name == "scope" || $0.name == "expand" })?.value,
           let scope = TodoBoardScope(rawValue: raw) {
            model.requestedScope = scope
        }
        openBoard(application: application)
    }

    private func openBoard(application: NSApplication) {
        let window: NSWindow
        if let boardWindow {
            window = boardWindow
        } else {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 388, height: 565),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "待办助手"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.backgroundColor = NSColor(srgbRed: 0.095, green: 0.105, blue: 0.12, alpha: 1)
            panel.isOpaque = true
            panel.hidesOnDeactivate = false
            panel.level = .normal
            panel.collectionBehavior = [.moveToActiveSpace]
            panel.contentViewController = NSHostingController(rootView: TodoBoard(model: model))
            let maxHeight = min(620, (NSScreen.main?.visibleFrame.height ?? 650) - 30)
            panel.contentMinSize = NSSize(width: 360, height: min(370, maxHeight))
            panel.contentMaxSize = NSSize(width: 400, height: maxHeight)
            panel.setContentSize(NSSize(width: 388, height: min(565, maxHeight)))
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.center()
            panel.setFrameAutosaveName("DesktopTodoCompactPanel")
            boardWindow = panel
            window = panel
        }

        model.refreshView()
        show(window, application: application)
    }

    private func openDetail(id: String, application: NSApplication) {
        guard model.refreshView(),
              let item = model.items.first(where: { $0.id == id || $0.source.aliases.contains(id) }) else {
            application.activate()
            showDetailError(defaultMessage: TodoStore.Failure.itemMissing.localizedDescription)
            return
        }

        if let panel = detailWindow, panel.isVisible, detailItemID == item.id {
            show(panel, application: application)
            return
        }

        let panel = detailWindow ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 355, height: 400),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "事项详情"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false

        let editor = TodoEditor(item: item, save: { [weak self, weak panel] draft in
            guard let self else { return false }
            let saved = model.save(draft, item: item)
            if !saved { showDetailError(in: panel) }
            return saved
        }, changeState: { [weak self, weak panel] state in
            guard let self else { return false }
            let changed = model.changeState(state, of: item)
            if !changed { showDetailError(in: panel, defaultMessage: TodoStore.Failure.staleAction.localizedDescription) }
            return changed
        }, close: { [weak panel] in panel?.close() })
        let hosting = NSHostingController(rootView: editor)
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        if !panel.isVisible { panel.center() }
        detailWindow = panel
        detailItemID = item.id
        show(panel, application: application)
    }

    private func show(_ window: NSWindow, application: NSApplication) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        application.activate()
    }

    private func openPaymentDetail(id: String, application: NSApplication) {
        model.refreshView()
        guard let payment = (model.pendingPayments.rows + model.pendingPayments.removedRows).first(where: { $0.id == id }) else {
            application.activate()
            showDetailError(defaultMessage: "这笔款项已变更，请刷新后重试。")
            return
        }
        if let existing = paymentWindows[id], existing.isVisible {
            show(existing, application: application)
            return
        }
        let panel = paymentWindows[id] ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 388, height: 480),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false
        )
        panel.title = "款项详情"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(srgbRed: 0.095, green: 0.105, blue: 0.12, alpha: 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.contentViewController = NSHostingController(rootView: PaymentDetail(model: model, paymentID: payment.id) { [weak panel] in
            panel?.close()
        })
        panel.setContentSize(NSSize(width: 420, height: min(640, (NSScreen.main?.visibleFrame.height ?? 700) - 60)))
        if !panel.isVisible { panel.center() }
        paymentWindows[id] = panel
        show(panel, application: application)
    }

    private func showDetailError(in panel: NSPanel? = nil, defaultMessage: String = "操作未保存。") {
        let alert = NSAlert()
        alert.messageText = "待办未更新"
        alert.informativeText = model.editError ?? defaultMessage
        model.editError = nil
        alert.addButton(withTitle: "好")
        if let panel {
            alert.beginSheetModal(for: panel)
        } else {
            alert.runModal()
        }
    }
}

@main
enum DesktopTodoApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let lifecycle = AppLifecycle()
        application.delegate = lifecycle
        withExtendedLifetime(lifecycle) { application.run() }
    }
}
