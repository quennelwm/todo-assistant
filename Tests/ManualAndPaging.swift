import Foundation

func testManualAndPaging(in scratch: URL) throws {
    let store = TodoStore(directory: scratch.appending(path: "ManualAndPaging"))
    do { _ = try store.createTask(NewTodoDraft()); expect(false, "blank manual titles are rejected") }
    catch is TodoInputError {}
    var draft = NewTodoDraft(lane: .team)
    draft.title = "  手动联系供应商\n确认交付  "
    draft.notes = "先核对数量，再确认交付"
    draft.owner = "张甲"; draft.contact = "测试客户"
    let item = try store.createTask(draft)
    expect(item.title == "手动联系供应商\n确认交付" && item.notes == draft.notes && item.locallyCreated == true,
           "manual entry retains title and notes")
    expect(item.summaryFields.contains("手动") && item.due == nil && item.owner == "张甲", "new entry supports optional fields and a human source name")
    _ = try store.createTask(draft)
    expect(try store.load().count == 1, "repeated submission of the same draft cannot duplicate it")
    let master = TodoMaster(version: "v1", publishedAt: .now, tasks: [task("imported", nil)])
    try store.merge(master)
    let visible = TodoBoardSnapshot(items: try store.load(), scope: .team, now: .now)
    expect(visible.rows.contains { $0.id == item.id }, "source refresh cannot hide an unabsorbed manual task")
    var imported = task("canonical", nil)
    imported.aliases = [item.id]; imported.title = "自动来源的改写"
    try store.merge(TodoMaster(version: "v2", publishedAt: master.publishedAt, tasks: [imported]))
    let joined = try store.load().first { $0.id == item.id }!
    expect(joined.title == item.title && joined.notes == item.notes && joined.owner == "张甲", "source adoption preserves manually entered content")
    try store.setState(.done, id: item.id)
    try store.merge(TodoMaster(version: "v3", publishedAt: master.publishedAt, tasks: [imported]))
    expect(try store.load().first { $0.id == item.id }?.state == .done, "manual completion survives later source sync")
    try store.edit(id: item.id, owner: nil, contact: nil, lane: nil, due: nil, dueEdited: false, state: nil,
                   title: "更正后的事项", notes: "更正后的说明")
    expect(try store.load().first { $0.id == item.id }?.title == "更正后的事项", "manual task content can be corrected")
    let destination = scratch.appending(path: "ManualEvents")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try store.publishOperations(to: destination)
    let events = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        .map { try JSONDecoder().decode(TodoOperation.self, from: Data(contentsOf: $0)) }
    let creation = events.first { $0.action == .createTask }!
    expect(creation.item_type == .task && creation.after["title"] == item.title && creation.after.keys.contains("due"),
           "creation is atomically queued with complete fields and explicit unknown deadline")
    expect(TodoBoardSnapshot(items: try TodoStore(directory: store.directory).load(), scope: .team, now: .now).rows.count == 1,
           "manual task survives app relaunch")

    let heights = [45.0, 80, 50, 78, 100, 45, 45, 70, 85]
    let first = TodoPagination(heights: heights, available: 200, spacing: 4, requestedPage: 0)
    var covered = Set<Int>()
    for index in first.starts.indices {
        let page = TodoPagination(heights: heights, available: 200, spacing: 4, requestedPage: index)
        covered.formUnion(page.range)
        expect(page.range.count > 0, "every page has content")
    }
    expect(covered == Set(heights.indices), "variable-height pages cannot skip clipped rows")
    expect(TodoPagination(heights: heights, available: 200, spacing: 4, requestedPage: 999).page == first.starts.count - 1,
           "old page indices clamp when list size changes")
    expect(TodoPagination(heights: [], available: 1, spacing: 4, requestedPage: 99).range.isEmpty, "empty pagination is safe")
    try store.setWidgetScope(.team)
    let navigation = store.widgetNavigation()
    try store.setWidgetPage(2, expected: navigation)
    expect(store.widgetNavigation().page == 2, "widget page persists across reads")
    try store.setWidgetPage(3, expected: navigation)
    expect(store.widgetNavigation().page == 2, "replayed navigation cannot skip another page")
    try store.setWidgetScope(.team)
    expect(store.widgetNavigation().page == 0, "clicking the current bottom tab returns to the top")
    try store.setWidgetScope(.payment)
    try store.setWidgetPage(3, expected: store.widgetNavigation())
    try store.setPaymentScope(.verification)
    expect(store.widgetNavigation().page == 0, "payment filter selection resets the page")
}

func testNameEditing(in scratch: URL, publication: PublishedPayments) throws {
    let store = TodoStore(directory: scratch.appending(path: "NameEditing"))
    try store.merge(TodoMaster(version: "v1", publishedAt: .now, tasks: [task("rename", nil)]))
    let old = try store.load()[0]
    try store.edit(id: old.id, owner: nil, contact: nil, lane: nil, due: nil, dueEdited: false, state: nil, title: "  自定义待办名称  ")
    try store.merge(TodoMaster(version: "v2", publishedAt: .now, tasks: [task("rename", nil)]))
    expect(try store.load()[0].title == "自定义待办名称" && store.load()[0].source.title == old.source.title,
           "imported task rename survives sync and retains original")
    try store.mergePayments(publication)
    func row() -> PendingPayment { store.pendingPayments.rows.first { $0.id == "P02" }! }
    let before = row()
    do { try store.renamePayment(expected: before, name: "  \n "); expect(false, "blank payment name rejected") }
    catch is TodoInputError {}
    try store.renamePayment(expected: before, name: "自定义款项名称")
    expect(row().project == "自定义款项名称" && row().stage == before.stage && row().amount == before.amount,
           "rename only changes payment name even with incomplete verification fields")
    expect(row().originalProject == before.project, "original payment name remains available")
    do { try store.renamePayment(expected: before, name: "旧窗口修改"); expect(false, "stale rename rejected") }
    catch TodoStore.Failure.staleAction {}
    let event = try store.paymentHistory(id: before.id).last!
    expect(event.action == .changeTitle && event.after == ["project": "自定义款项名称"], "rename event only contains changed name")
    try store.mergePayments(publication)
    expect(row().project == "自定义款项名称", "payment rename survives refresh")
    try store.undoPayment(expected: row(), eventID: event.event_id)
    expect(row().project == before.project, "payment rename can be undone")
    try store.renamePayment(expected: row(), name: "保留名称")
    var draft = PaymentDraft(row()); draft.amount = "900.00"
    _ = try store.verifyPayment(expected: row(), draft: draft)
    expect(row().project == "保留名称", "progress verification preserves manually edited name")
    var newerRows = publication.items; newerRows[1].amount = "950.00"
    let newer = PublishedPayments(schema_version: 1, version: "rename-v2", updated_at: "2030-01-01T00:00:00+08:00", coverage: "test", items: newerRows)
    try store.mergePayments(newer)
    let conflicted = row()
    expect(conflicted.conflict == true, "fixture has a real amount conflict")
    try store.renamePayment(expected: conflicted, name: "冲突中更名")
    expect(row().conflict == true && row().sourceConflicts?["amount"] == "950.00", "rename cannot resolve an unverified money conflict")
    expect(TodoStore(directory: store.directory).pendingPayments.rows.first { $0.id == before.id }?.project == "冲突中更名", "name persists after restart")
}
