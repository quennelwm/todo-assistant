import Foundation

func expect(_ condition: Bool, _ description: String) {
    if !condition {
        FileHandle.standardError.write(Data(("FAIL: " + description + "\n").utf8))
        exit(1)
    }
}

let now = TodoClock.parse("2026-11-05T14:00:00+08:00")!
func task(_ id: String, _ due: String?, _ state: TodoState = .open) -> SourceTask {
    SourceTask(id: id, title: id, owner: "我", contact: nil, due: due, lane: .personal,
               state: state, notes: nil, evidence: [], aliases: [])
}

let tasks = [
    task("done", nil, .done), task("later", "2026-11-07"), task("today", "2026-11-05"),
    task("none", nil), task("tomorrow", "2026-11-06"), task("past-time", "2026-11-05T10:00:00+08:00"),
    task("past-day", "2026-11-04"), task("cancelled", nil, .cancelled)
]
let sorted = TodoItem.sorted(tasks.map { TodoItem(source: $0) }, at: now)
expect(sorted.map(\.id) == ["past-day", "past-time", "today", "tomorrow", "later", "none", "done", "cancelled"],
       "date-only deadlines stay orange all day and explicit times can turn red")

let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
defer { try? FileManager.default.removeItem(at: scratch) }
let app = TodoStore(directory: scratch)
let widget = TodoStore(directory: scratch)
try app.merge([task("existing", "2026-11-06")])
try widget.setState(.done, id: "existing", onlyIfOpen: true)
try widget.setState(.cancelled, id: "existing", onlyIfOpen: true)
try app.edit(id: "existing", owner: "同事", contact: "客户", lane: .team, due: nil, state: .done)
var update = task("integrated", "2026-11-08")
update.aliases = ["existing"]
update.title = "更新后的事项"
try app.merge([task("existing", "2026-11-06"), update])
let merged = try widget.load()
expect(merged.count == 1 && merged[0].title == "更新后的事项", "cross-source aliases preserve one row")
expect(merged[0].state == .done && merged[0].lane == .team && merged[0].due == nil &&
       merged[0].contact == "客户" && merged[0].owner == "同事", "manual edits survive another source snapshot")
try app.setState(.open, id: "existing")
let restored = try widget.load()
expect(restored.first?.state == .open, "restore persists across store instances")

let handoff = """
## 一般背景
| X99 | 团队 | 无关 | — | — | — | 待办 | — |
## 桌面待办
| ID | 栏目 | 内容 | 负责人 | 对接人 | 截止 | 状态 | 来源 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Q101 | 团队 | 寄送物料 | 同事 | 供应商 | 2026-11-06 | 待办 | 企微 M101 |
| T101 | 待确认 | 核对通知 | — | — | 明晚 | 待办 | 短信 101 |
| Q102 | 团队 | 一般信息 | 同事 | — | — | 未知 | 企微 M102 |
## 其他
| X10 | 本人 | 无关 | — | — | — | 待办 | — |
"""
let extracted = HandoffReader.markdown(handoff, path: "/tmp/终版汇总.md")
expect(extracted.map(\.id) == ["Q101", "T101"] && extracted[0].contact == "供应商" &&
       extracted[1].due == nil && extracted[1].lane == .unassigned,
       "only explicit actionable handoff rows import, without guessing deadlines")

let wechat = """
{"items":[
{"id":"W01","title":"跟进项目","owner":"同事；我协调","due":"2026-11-05","due_precision":"日期","status":"待处理"},
{"id":"W02","title":"团队事项","owner":"交付团队；我知会","due":"2026-11-06","due_precision":"活动起始日期","status":"待处理"},
{"id":"W03","title":"普通信息","owner":"我","status":"可选信息"}]}
"""
let imported = try HandoffReader.wechat(Data(wechat.utf8), path: "/tmp/待办清单.json")
expect(imported.map(\.lane) == [.personal, .team] && imported[1].due == nil,
       "FYI and activity start times do not turn into the user's assignments or deadlines")

let dated = TodoClock.timestamp(now)
expect(TodoClock.parse(dated) == now && TodoClock.parse("2026-02-30") == nil, "manual calendar dates round trip")
var newer = task("stable", "2026-11-08", .cancelled)
newer.revision = now
var older = task("stable", "2026-11-06")
older.revision = now.addingTimeInterval(-60)
try app.merge([newer])
try app.merge([older])
let stable = try app.load().first { $0.id == "stable" }
expect(stable?.state == .cancelled && stable?.due == newer.due, "older handoffs cannot reopen a newer status")

let integration = scratch.appending(path: "Integration")
let sources = LocalSources(home: scratch, integrationDirectory: integration)
try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true)
let masterFile = integration.appending(path: "待办总表.md")
let paymentFile = integration.appending(path: "请款与付款清单.json")
let masterText = """
# 待办总表
版本 test-v1。发布于 2026-11-05T19:05:10+08:00。

## 桌面待办
| ID | 栏目 | 内容 | 负责人 | 对接人 | 截止 | 状态 | 来源 | 同事项 ID |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| formal | 团队 | 发布版任务 | 李乙 | 客户 | 2026-11-06 | 待办 | 企微 | old-id |
| officially-closed | 本人 | 关闭的事项 | 我 | — | — | 已取消 | 微信 | — |
"""
let paymentsText = """
{"schema_version":1,"version":"test-v1","updated_at":"2026-11-05T19:05:10+08:00","coverage":"测试","items":[
{"id":"P01","project":"场地费","amount":"500.00","currency":"CNY","stage":"待申请","evidence":[],"updated_at":"2026-11-05T19:05:10+08:00"},
{"id":"P02","project":"拍摄","amount":"900.00","stage":"待核实","evidence":[],"updated_at":"2026-11-05T19:05:10+08:00"},
{"id":"P03","project":"运输","stage":"待付款","evidence":[],"updated_at":"2026-11-05T19:05:10+08:00"}]}
"""
let integrated = TodoStore(directory: scratch.appending(path: "IntegratedApp"))
try integrated.merge([task("old-id", "2026-11-05"), task("old-unlisted", nil)])
try integrated.setState(.done, id: "old-id")
try Data(masterText.utf8).write(to: masterFile)
try Data(paymentsText.utf8).write(to: paymentFile)
expect(sources.sync(to: integrated).isEmpty, "both formal inputs are readable")
let firstMaster = try integrated.load()
let migrated = firstMaster.first { $0.id == "old-id" }!
expect(migrated.masterID == "formal" && migrated.title == "发布版任务" && migrated.state == .done,
       "master matches a legacy alias and preserves the old ID and manual state")
let activeMaster = TodoBoardSnapshot(items: firstMaster, scope: .all, now: now)
expect(!activeMaster.rows.contains { $0.id == "old-unlisted" }, "unlisted legacy tasks remain archived in storage")
try integrated.merge([task("officially-closed", nil), task("legacy-new", nil)])
let afterLegacy = try integrated.load()
expect(firstMaster == afterLegacy, "older sources cannot reopen or add rows after master migration")

try integrated.setState(.open, id: "formal")
let beforeCancel = try integrated.load().first { $0.id == "old-id" }!
let cancelledEvent = try integrated.setState(.cancelled, id: "formal", onlyIfOpen: true)!
try integrated.undoState(id: "old-id", eventID: cancelledEvent, previous: beforeCancel.manual, previousState: beforeCancel.state)
try integrated.edit(id: "formal", owner: "张甲", contact: nil, lane: nil, due: nil, state: nil)
try integrated.setPlanning(id: "formal", priority: .high)
let editedMaster = try integrated.load().first { $0.id == "old-id" }!
expect(editedMaster.state == .open && editedMaster.due == nil && editedMaster.owner == "张甲",
       "manual restore, undo, deadline removal and owner edits persist before delivery")
let undo = editedMaster.outbox!.first { $0.action == .undo }!
expect(undo.reverts_event_id == cancelledEvent && undo.item_id == "formal" && undo.base_version == "test-v1",
       "undo links the original event and publishes the formal ID and base version")
do {
    try integrated.undoState(id: "formal", eventID: cancelledEvent, previous: beforeCancel.manual, previousState: beforeCancel.state)
    expect(false, "an old undo cannot overwrite a subsequent state")
} catch TodoStore.Failure.staleAction {}

let updatedMaster = masterText.replacingOccurrences(of: "test-v1", with: "test-v2")
    .replacingOccurrences(of: "李乙", with: "郭添添")
try Data(updatedMaster.utf8).write(to: masterFile)
expect(sources.sync(to: integrated).isEmpty, "new master syncs")
let conflicted = try integrated.load().first { $0.id == "old-id" }!
expect(conflicted.owner == "张甲" && conflicted.conflicts == ["owner"], "a conflicting master edit is flagged without replacing the local edit")
try Data(masterText.utf8).write(to: masterFile)
expect(sources.sync(to: integrated).count == 1, "an older version with the same publication timestamp is rejected")
let afterRollback = try integrated.load().first { $0.id == "old-id" }!
expect(afterRollback == conflicted, "the rejected snapshot leaves the new source and manual values intact")


let payRows = integrated.pendingPayments.rows
expect(payRows.map { $0.stage.scope } == [.application, .verification, .payment], "payments are classified by actual stage")
do {
    try integrated.confirmPaymentStage(id: "P01", expected: .apply, next: .paid)
    expect(false, "application cannot go straight to paid")
} catch TodoStore.Failure.staleAction {}
try integrated.confirmPaymentStage(id: "P01", expected: .apply, next: .submitted)
expect(integrated.pendingPayments.rows.first?.stage == .submitted &&
       integrated.pendingPayments.rows.first?.stage.scope == .payment, "submitting an application changes the stage only")
try integrated.confirmPaymentStage(id: "P03", expected: .pay, next: .paid)
expect(integrated.pendingPayments.rows.last?.stage == .paid, "explicit actual-payment confirmation is a separate transition")
let lastGoodPayments = integrated.pendingPayments
try Data("invalid".utf8).write(to: paymentFile)
try Data((updatedMaster + "\n| broken row |").utf8).write(to: masterFile)
let beforeFailedSync = try integrated.load()
expect(sources.sync(to: integrated).count == 2, "bad formal inputs report both errors")
let afterFailedSync = try integrated.load()
expect(afterFailedSync == beforeFailedSync && integrated.pendingPayments == lastGoodPayments,
       "a read failure preserves the last good data and pending events")

do {
    try integrated.publishOperations(to: sources.operations)
    expect(false, "an unavailable destination must report a delivery failure")
} catch {}
let queuedAfterFailure = try integrated.load()
expect(queuedAfterFailure == beforeFailedSync, "a delivery failure preserves the original event IDs")
try FileManager.default.createDirectory(at: sources.operations, withIntermediateDirectories: true)
let alreadyDelivered = sources.operations.appending(path: "\(undo.event_id).json")
try JSONEncoder().encode(undo).write(to: alreadyDelivered)
try integrated.publishOperations(to: sources.operations)
let publishedFiles = try FileManager.default.contentsOfDirectory(at: sources.operations, includingPropertiesForKeys: nil)
let publishedEvents = try publishedFiles.map { try JSONDecoder().decode(TodoOperation.self, from: Data(contentsOf: $0)) }
let expectedTotal = beforeFailedSync.flatMap { $0.outbox ?? [] }.count + 2
expect(publishedEvents.count == expectedTotal && Set(publishedEvents.map(\.event_id)).count == expectedTotal,
       "task and payment events are delivered exactly once by event ID")
expect(publishedEvents.contains { $0.action == .reschedule && $0.before["due"] == "2026-11-06" && $0.after.keys.contains("due") },
       "clearing a deadline records a null and no unrelated fields")
expect(publishedEvents.contains { $0.item_id == "P01" && $0.item_type == .payment && $0.after["stage"] == "已提交" },
       "the recorded application event does not claim actual payment")
try integrated.publishOperations(to: sources.operations)
let afterRetry = try FileManager.default.contentsOfDirectory(at: sources.operations, includingPropertiesForKeys: nil)
expect(Set(afterRetry) == Set(publishedFiles), "retry does not duplicate or rewrite events")

let recordOnly = """
## 桌面待办
| F03 | 本人 | 非行动背景信息 | 我 | — | — | 仅记录 | 近期记忆 |
"""
let history = HandoffReader.markdown(recordOnly, path: "/tmp/终版汇总.md")
expect(history.count == 1 && TodoItem.sorted(history.map { TodoItem(source: $0) }, at: now).isEmpty,
       "a newer information-only classification removes the row from both boards")

let syncNow = TodoClock.parse("2026-11-05T15:30:00+08:00")!
var automatic = TodoAutomaticUpdateStatus()
expect(!automatic.enabled, "new installs default to manual mode")
automatic.enabled = true
expect(automatic.delay(after: nil, now: syncNow) == 0, "first automatic update is due immediately")
automatic.lastSuccessfulUpdate = syncNow.addingTimeInterval(-120)
expect(automatic.delay(after: nil, now: syncNow) == 1680, "relaunch resumes the existing 30-minute cadence")
expect(automatic.delay(after: syncNow, now: syncNow) == 1800, "a failed attempt cannot spin before the next interval")
automatic.enabled = false
expect(automatic.delay(after: syncNow, now: syncNow) == nil, "paused updates have no automatic deadline")
let statusFile = scratch.appending(path: "AutomaticUpdates/status.json")
try automatic.save(to: statusFile)
let savedAutomatic = try TodoAutomaticUpdateStatus.load(from: statusFile)
expect(savedAutomatic == automatic, "pause and last success persist together")

var pinned = TodoItem(source: task("pinned", nil))
pinned.manual.pinned = true
var high = TodoItem(source: task("high", nil))
high.manual.priority = .high
var teamLate = TodoItem(source: task("team-overdue", "2026-11-04"))
teamLate.source.lane = .team
let scheduled = [task("month", "2026-11-13"), task("future", "2026-12-02")].map { TodoItem(source: $0) }
let board = TodoBoardSnapshot(items: sorted + [pinned, high, teamLate] + scheduled, scope: .all, now: now)
expect(board.rows.map(\.id) == ["past-day", "team-overdue", "past-time", "today", "tomorrow", "later",
                               "month", "future", "pinned", "high", "none", "done", "cancelled"],
       "all rows are shown in status order across lanes, with pins and priority inside each status")
expect(board.activeCount == 11, "finished and cancelled rows do not inflate the active count")
expect(TodoBoardSnapshot(items: board.rows, scope: .team, now: now).rows.map(\.id) == ["team-overdue"],
       "the team scope filters before calculating counts")
expect(TodoBoardSnapshot(items: board.rows, scope: .payment, now: now).rows.isEmpty,
       "regular tasks never leak into the payment filter")

expect(widget.pendingPayments == .notConnected, "a missing payment feed is distinct from an empty queue")
let cautious = """
## 桌面待办
| R01 | 团队 | 先核对金额，再付款 | 张三／李四；王五知会 | 客户 | 2026-11-04 | 疑似取消 | 聊天记录 | — | 完整背景 | 核对金额后再付款 | 完整原文 | 张三 | 高 | 活动开始 |
"""
let cautiousRow = HandoffReader.markdown(cautious, path: "/tmp/终版汇总.md")[0]
expect(cautiousRow.state == .open && cautiousRow.needsReview == true && cautiousRow.due == nil,
       "suspected cancellation stays active and activity start does not become overdue")
expect(cautiousRow.title == "先核对金额，再付款" && cautiousRow.displayTitle == "核对金额后再付款" &&
       cautiousRow.originalText == "完整原文" && cautiousRow.primaryOwner == "张三",
       "short title, original and lead owner stay separate")
try app.setPlanning(id: "existing", pinned: true, priority: .high)
try app.merge([update])
let planned = try app.load().first { $0.id == "existing" }
expect(planned?.isPinned == true && planned?.priority == .high && planned?.state == .open,
       "refresh preserves manual planning and state")

expect(widget.widgetScope() == .all, "fresh widget defaults to all lanes")
try app.setWidgetScope(.payment)
expect(widget.widgetScope() == .payment, "filter selection is persisted for the widget timeline")
var summarySource = task("事项 #1", "2026-11-05T17:30:00+08:00")
summarySource.owner = "张甲／李乙；我知会"
summarySource.contact = "供应商 A"
summarySource.evidence = [
    Evidence(label: "企业微信 Q02、截图 S04", path: "/tmp/handoff"),
    Evidence(label: "企微 Q02", path: "/tmp/duplicate"),
    Evidence(label: "日历", path: "/tmp/calendar")
]
let summaryItem = TodoItem(source: summarySource)
expect(summaryItem.summaryStatus(at: now) == "今日" &&
       summaryItem.summaryFields == ["11月5日 17:30", "企微／截图／日历", "张甲", "供应商 A"],
       "summary retains field order, a single owner and unique source names")
var repairSource = task("T02-repair", nil)
repairSource.contact = "示例客服"
repairSource.evidence = [
    Evidence(label: "短信 T02、微信 E1000000、E1000001–E1000005；近期记忆", path: "/tmp/handoff"),
    Evidence(label: "E1000001 — E1000005、Microsoft Outlook", path: "/tmp/source")
]
let repair = TodoItem(source: repairSource)
expect(repair.summaryFields == ["短信／微信／邮件", "我", "示例客服"],
       "message number ranges stay out of the summary while named sources remain")
expect(repair.source.evidence == repairSource.evidence, "the detail view can still show the original evidence")
let calendarLabels = ["2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07",
                      "2026-11-13", "2026-12-02"].map {
    TodoItem(source: task("date", $0)).summaryStatus(at: now)
}
expect(calendarLabels == ["逾期", "今日", "明日", "本周", "本月", "以后"],
       "status uses Shanghai dates and distinguishes later months")
let details = URLComponents(url: TodoStore.detailURL(id: summaryItem.id), resolvingAgainstBaseURL: false)
expect(details?.host == "detail" && details?.queryItems?.first?.value == summaryItem.id,
       "detail URLs carry the exact task identifier")

let paymentFixture = try JSONDecoder().decode(PublishedPayments.self, from: Data(paymentsText.utf8))
expect(paymentFixture.items[0].formattedAmount == "¥500.00" &&
       paymentFixture.items[1].formattedAmount == "900.00" &&
       paymentFixture.items[2].formattedAmount == "金额待确认",
       "payment amounts distinguish CNY, unspecified currency and missing amounts")
let preciseFixture = paymentsText.replacingOccurrences(of: "500.00", with: "123456.789")
expect(try JSONDecoder().decode(PublishedPayments.self, from: Data(preciseFixture.utf8)).items[0].formattedAmount == "¥123,456.789",
       "amount presentation adds grouping without losing source precision")
let paymentLink = URLComponents(url: TodoStore.paymentDetailURL(id: "P & 01"), resolvingAgainstBaseURL: false)
expect(paymentLink?.host == "payment" && paymentLink?.queryItems?.first?.value == "P & 01",
       "payment detail route is separate from board and preserves identifiers")

// A source acknowledgement must not erase a user's confirmed progress.
let protectedPayments = TodoStore(directory: scratch.appending(path: "PaymentProtection"))
let originalPublication = try JSONDecoder().decode(PublishedPayments.self, from: Data(paymentsText.utf8))
try protectedPayments.mergePayments(originalPublication)
try protectedPayments.confirmPaymentStage(id: "P01", expected: .apply, next: .submitted)
let acknowledgedText = paymentsText.replacingOccurrences(of: "test-v1", with: "test-v2")
    .replacingOccurrences(of: "待申请", with: "已提交")
try protectedPayments.mergePayments(JSONDecoder().decode(PublishedPayments.self, from: Data(acknowledgedText.utf8)))
let regressedText = paymentsText.replacingOccurrences(of: "test-v1", with: "test-v3")
try protectedPayments.mergePayments(JSONDecoder().decode(PublishedPayments.self, from: Data(regressedText.utf8)))
expect(protectedPayments.pendingPayments.rows.first?.stage == .submitted &&
       protectedPayments.pendingPayments.rows.first?.conflict == true,
       "acknowledged manual payment stage survives a later conflicting publication")

try testPaymentWorkflow(in: scratch, publication: originalPublication)
try testPaymentRemoval(in: scratch, publication: originalPublication)
try testManualAndPaging(in: scratch)
try testNameEditing(in: scratch, publication: paymentFixture)


let manualStore = TodoStore(directory: scratch.appending(path: "FreshInstall"))
let freshHome = scratch.appending(path: "FreshHome")
let manualSources = LocalSources(home: freshHome)
expect(!manualSources.isConfigured && manualSources.sync(to: manualStore).isEmpty,
       "fresh install needs no integration directory or permission")
var freshDraft = NewTodoDraft(); freshDraft.title = "独立模式手动待办"
let freshItem = try manualStore.createTask(freshDraft)
_ = manualSources.sync(to: manualStore)
expect(try manualStore.load().first?.id == freshItem.id, "manual task survives unconfigured refresh")
expect(!FileManager.default.fileExists(atPath: freshHome.path), "manual mode does not create external integration directories")



var noisySource = task("simple-source", nil)
noisySource.evidence = [
    Evidence(label: "微信／E1234567及11月5日活动群", path: "/tmp/handoff.md"),
    Evidence(label: "企业微信_导出明细_20261106.json", path: "/tmp/archive.json"),
    Evidence(label: "短信 iMessage 数据库_123", path: "/tmp/archive.db"),
    Evidence(label: "截图 IMG_20261106_183001.png", path: "/tmp/screenshot.png"),
    Evidence(label: "照片 IMG_001.jpg", path: "/tmp/photo.jpg"),
    Evidence(label: "长文件名_会议信息整理_最终版.pdf", path: "/tmp/long-document.pdf")
]
expect(TodoItem(source: noisySource).summaryFields.first == "微信／企微／短信／截图／照片／文档", "source categories never expose filenames, dates or reference IDs")
expect(TodoItem(source: noisySource).source.evidence == noisySource.evidence, "source simplification retains full original evidence")

print("All Desktop Todo checks passed")
