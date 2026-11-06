import Foundation

func testPaymentWorkflow(in scratch: URL, publication: PublishedPayments) throws {
    let store = TodoStore(directory: scratch.appending(path: "PaymentWorkflow"))
    try store.mergePayments(publication)
    func row(_ id: String = "P02") -> PendingPayment { store.pendingPayments.rows.first { $0.id == id }! }
    func reject(_ draft: PaymentDraft, item: PendingPayment) throws {
        do { _ = try store.verifyPayment(expected: item, draft: draft); expect(false, "invalid verification rejected") }
        catch is PaymentValidationError {}
    }
    let original = row()
    var draft = PaymentDraft(original)
    draft.stage = .submitted
    draft.counterparty = "测试供应商"
    draft.currency = "CNY"
    draft.note = "本人核对申请记录，已提交成功"
    expect((try? draft.validatedFields()) != nil, "stage save does not require a checkbox")
    draft.amount = "-1"
    try reject(draft, item: original)
    draft.amount = "900.00"
    let event = try store.verifyPayment(expected: original, draft: draft)
    expect(row().stage == .submitted && row().confirmationNote == draft.note, "verification saves fields and basis")
    expect(row().scope == .payment && row().paid_amount == nil, "submission never invents a payment")
    do { _ = try store.verifyPayment(expected: original, draft: draft); expect(false, "stale editor rejected") }
    catch TodoStore.Failure.staleAction {}
    try store.mergePayments(publication)
    expect(row().stage == .submitted && row().counterparty == "测试供应商", "refresh preserves verified values")
    try store.undoPayment(expected: row(), eventID: event)
    expect(row().stage == .verify && row().currency == nil, "undo restores nullable fields and original stage")
    let undo = try store.paymentHistory(id: "P02").last!
    expect(undo.action == .undo && undo.reverts_event_id == event, "undo is a linked audit event")
    do { try store.undoPayment(expected: row(), eventID: event); expect(false, "same action cannot undo twice") }
    catch TodoStore.Failure.staleAction {}

    var partial = PaymentDraft(row())
    partial.stage = .pay
    partial.counterparty = "测试供应商"
    partial.currency = "CNY"
    partial.paidAmount = "300.01"
    partial.note = "确认只付本笔300.01元"
    _ = try store.verifyPayment(expected: row(), draft: partial)
    expect(row().paid_amount == "300.01" && row().remaining_amount == "599.99" && row().displayStage == "待付款",
           "partial payment uses exact decimals and remains active")
    var invalid = PaymentDraft(row())
    invalid.note = "错误金额测试"; invalid.paidAmount = "901"
    try reject(invalid, item: row())
    invalid.paidAmount = "300.01"; invalid.remainingAmount = "700"
    try reject(invalid, item: row())
    var final = PaymentDraft(row())
    final.stage = .paid; final.note = "本人确认本笔已全部付清"
    let closed = try store.verifyPayment(expected: row(), draft: final)
    expect(row().paid_amount == "900.00" && row().remaining_amount == "0" && row().scope == .history,
           "explicit full payment sets settled amounts and enters history")
    expect(row("P01").stage == .apply, "verifying one payment never updates another")
    let historyBefore = try store.paymentHistory(id: "P02")
    let destination = scratch.appending(path: "PaymentEvents")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try store.publishOperations(to: destination)
    try store.publishOperations(to: destination)
    expect(try store.paymentHistory(id: "P02") == historyBefore, "delivery preserves audit history")
    expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == historyBefore.count,
           "operation retries do not duplicate payment events")
    let reopened = TodoStore(directory: store.directory)
    expect(try reopened.paymentHistory(id: "P02") == historyBefore && reopened.pendingPayments.rows == store.pendingPayments.rows,
           "verified values and audit survive relaunch")
    let empty = PublishedPayments(schema_version: 1, version: "test-v2", updated_at: publication.updated_at, coverage: "test", items: [])
    try store.mergePayments(empty)
    expect(row().stage == .paid, "source omission does not erase verified history")
    try store.undoPayment(expected: row(), eventID: closed)
    expect(row().stage == .pay && row().remaining_amount == "599.99", "history can be corrected after source omission")

    let conflicts = TodoStore(directory: scratch.appending(path: "PaymentFieldConflicts"))
    try conflicts.mergePayments(publication)
    let first = conflicts.pendingPayments.rows[1]
    var verified = PaymentDraft(first)
    verified.counterparty = "已核实供应商"; verified.currency = "CNY"; verified.stage = .apply
    verified.note = "本人核实本笔金额及收款方"
    _ = try conflicts.verifyPayment(expected: first, draft: verified)
    var newRows = publication.items
    newRows[1].amount = "950.00"
    let newer = PublishedPayments(schema_version: 1, version: "test-v2", updated_at: publication.updated_at,
                                 coverage: "test", items: newRows)
    try conflicts.mergePayments(newer)
    let conflicting = conflicts.pendingPayments.rows[1]
    expect(conflicting.amount == "900.00" && conflicting.conflict == true && conflicting.scope == .verification &&
           conflicting.sourceConflicts?["amount"] == "950.00", "source disagreement keeps the confirmed amount and exposes both values")
    verified.note = "本人再次确认900元，来源950元不适用"
    let resolution = try conflicts.verifyPayment(expected: conflicting, draft: verified)
    expect(conflicts.pendingPayments.rows[1].conflict != true, "explicit re-verification resolves conflict")
    try conflicts.undoPayment(expected: conflicts.pendingPayments.rows[1], eventID: resolution)
    expect(conflicts.pendingPayments.rows[1].conflict == true, "undo restores the conflict needing verification")
    _ = try conflicts.verifyPayment(expected: conflicts.pendingPayments.rows[1], draft: verified)
    try conflicts.mergePayments(newer)
    expect(conflicts.pendingPayments.rows[1].conflict != true, "same known source does not recreate a resolved conflict")

    for stage in PaymentStage.allCases {
        let before = conflicts.pendingPayments.rows[1]
        var each = PaymentDraft(before)
        each.stage = stage; each.note = "逐阶段测试"
        each.paidAmount = ""; each.remainingAmount = ""
        _ = try conflicts.verifyPayment(expected: before, draft: each)
        expect(conflicts.pendingPayments.rows[1].scope == stage.scope, "all actual stages have an accessible destination")
    }
    var unconfirmed = PaymentDraft(original)
    unconfirmed.note = "暂未拿到明确记录，继续待核实"
    let values = try unconfirmed.validatedFields()
    expect(values["paid_amount"]! == nil && values["remaining_amount"]! == nil, "unknown values remain null")
    unconfirmed.note = "   "
    expect((try? unconfirmed.validatedFields()) != nil, "explanation is optional")
    unconfirmed.note = "校验日期"; unconfirmed.due = "明天"
    try reject(unconfirmed, item: row())

    let quick = TodoStore(directory: scratch.appending(path: "QuickPayments"))
    try quick.mergePayments(publication)
    let ready = quick.pendingPayments.rows[0]
    try quick.advancePayment(id: ready.id, expectedToken: ready.actionToken)
    let requested = quick.pendingPayments.rows[0]
    expect(requested.stage == .pay && requested.scope == .payment, "first circle enters the same waiting-payment state as the form")
    do { try quick.advancePayment(id: ready.id, expectedToken: ready.actionToken); expect(false, "replayed circle cannot skip a stage") }
    catch TodoStore.Failure.staleAction {}
    try quick.advancePayment(id: requested.id, expectedToken: requested.actionToken)
    let paid = quick.pendingPayments.rows[0]
    expect(paid.stage == .paid && paid.paid_amount == "500.00" && paid.remaining_amount == "0",
           "second circle marks this payment settled")
    expect(paid.confirmationNote == nil, "quick actions do not fabricate a user explanation")
    try quick.undoPayment(expected: paid, eventID: paid.lastOperationID!)
    expect(quick.pendingPayments.rows[0].stage == .pay, "quick completion is undoable")
    let unknown = quick.pendingPayments.rows[1]
    do { try quick.advancePayment(id: unknown.id, expectedToken: unknown.actionToken); expect(false, "unverified row cannot advance via circle") }
    catch TodoStore.Failure.staleAction {}
    let unspecified = quick.pendingPayments.rows[2]
    try quick.advancePayment(id: unspecified.id, expectedToken: unspecified.actionToken)
    expect(quick.pendingPayments.rows[2].stage == .paid && quick.pendingPayments.rows[2].paid_amount == nil,
           "paid with unknown total never invents a paid amount")
    expect(PaymentScope.allCases.map(\.title) == ["待请款", "待付款", "已付款", "待核实"], "payment tab order matches user's workflow")
    expect(PaymentStage.selectableCases.map(\.title) == PaymentScope.allCases.map(\.title),
           "form offers exactly the same four states as the tabs")
    for old in [PaymentStage.submitted, .approving] {
        var legacy = requested
        legacy.counterparty = "测试供应商"
        legacy.stage = old; legacy.paid_amount = "100.00"; legacy.remaining_amount = "400.00"
        let draft = PaymentDraft(legacy)
        expect(draft.stage == .pay && legacy.displayStage == "待付款" && (try? draft.validatedFields()) != nil,
               "legacy in-progress records open as waiting-payment and accept partial amounts")
    }
    expect(PaymentStage.returned.title == "待请款", "legacy returned records do not add another selectable state")
    var blank = PaymentDraft(unknown)
    blank.note = "   "
    _ = try quick.verifyPayment(expected: unknown, draft: blank)
    expect(quick.pendingPayments.rows[1].confirmationNote == nil, "blank optional note persists without a forced unwrap or fake note")
}
