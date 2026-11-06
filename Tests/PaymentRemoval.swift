import Foundation

func testPaymentRemoval(in scratch: URL, publication: PublishedPayments) throws {
    let store = TodoStore(directory: scratch.appending(path: "PaymentRemoval"))
    try store.mergePayments(publication)
    let original = store.pendingPayments.rows.first { $0.stage == .verify }!
    try store.removePayment(id: original.id, expectedToken: original.actionToken)
    expect(!store.pendingPayments.rows.contains { $0.id == original.id }, "removed payment disappears from all active filters")
    let removed = store.pendingPayments.removedRows.first!
    expect(removed.stage == original.stage && removed.amount == original.amount && removed.removalEventID != nil,
           "removal changes visibility, never financial facts")
    let removal = try store.paymentHistory(id: original.id).last!
    expect(removal.action == .removePayment && removal.before == ["excluded": "false"] && removal.after == ["excluded": "true"],
           "removal emits its own recoverable event")
    do { try store.removePayment(id: original.id, expectedToken: original.actionToken); expect(false, "old removal button cannot run twice") }
    catch TodoStore.Failure.staleAction {}
    do { _ = try store.verifyPayment(expected: removed, draft: PaymentDraft(removed)); expect(false, "removed records cannot be edited before restoring") }
    catch TodoStore.Failure.staleAction {}
    try store.mergePayments(publication)
    expect(store.pendingPayments.rows.count == publication.items.count - 1, "same source cannot re-add a removed payment")
    expect(TodoStore(directory: store.directory).pendingPayments.removedRows.count == 1, "removal survives restart")

    var updates = publication.items
    let index = updates.firstIndex { $0.id == original.id }!
    updates[index].stage = .pay
    let newer = PublishedPayments(schema_version: 1, version: "test-v2", updated_at: publication.updated_at, coverage: "test", items: updates)
    try store.mergePayments(newer)
    expect(!store.pendingPayments.rows.contains { $0.id == original.id }, "even a newer stage does not revive an excluded record")
    do { try store.restorePayment(id: original.id, expectedToken: removed.actionToken); expect(false, "stale recovery token rejected") }
    catch TodoStore.Failure.staleAction {}
    let latest = store.pendingPayments.removedRows.first!
    try store.restorePayment(id: latest.id, expectedToken: latest.actionToken)
    expect(store.pendingPayments.rows.first { $0.id == latest.id }?.stage == .pay && store.pendingPayments.removedRows.isEmpty,
           "restore preserves the latest financial facts")
    let restoration = try store.paymentHistory(id: latest.id).last!
    expect(restoration.action == .restore && restoration.reverts_event_id == removal.event_id,
           "restore links to the exact removal")
    let active = store.pendingPayments.rows.first { $0.id == latest.id }!
    do { try store.removePayment(id: active.id, expectedToken: active.actionToken); expect(false, "only pending-verification rows have a remove button") }
    catch TodoStore.Failure.staleAction {}

    let destination = scratch.appending(path: "RemovalEvents")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try store.publishOperations(to: destination)
    try store.publishOperations(to: destination)
    expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 2, "removal and restore publish once each")

    let orphan = TodoStore(directory: scratch.appending(path: "RemovedSourceOmission"))
    try orphan.mergePayments(publication)
    try orphan.removePayment(id: original.id, expectedToken: original.actionToken)
    try orphan.mergePayments(PublishedPayments(schema_version: 1, version: "test-v2", updated_at: publication.updated_at, coverage: "test", items: []))
    expect(orphan.pendingPayments.rows.isEmpty && orphan.pendingPayments.removedRows.count == 1,
           "source omission keeps the recoverable removed record")
    let hidden = orphan.pendingPayments.removedRows[0]
    try orphan.restorePayment(id: hidden.id, expectedToken: hidden.actionToken)
    expect(orphan.pendingPayments.rows.count == 1, "removed record is recoverable even after source omission")

    let conflictStore = TodoStore(directory: scratch.appending(path: "RemoveConflictedPayment"))
    try conflictStore.mergePayments(publication)
    var confirmed = PaymentDraft(original)
    confirmed.stage = .pay; confirmed.counterparty = "测试供应商"; confirmed.currency = "CNY"
    _ = try conflictStore.verifyPayment(expected: original, draft: confirmed)
    var changed = publication.items
    changed[index].amount = "950.00"
    try conflictStore.mergePayments(PublishedPayments(schema_version: 1, version: "test-v2", updated_at: publication.updated_at, coverage: "test", items: changed))
    let conflicted = conflictStore.pendingPayments.rows.first { $0.id == original.id }!
    expect(conflicted.conflict == true && conflicted.scope == .verification, "fixture exposes source disagreement")
    try conflictStore.removePayment(id: conflicted.id, expectedToken: conflicted.actionToken)
    let deletedConflict = conflictStore.pendingPayments.removedRows.first!
    try conflictStore.restorePayment(id: deletedConflict.id, expectedToken: deletedConflict.actionToken)
    let recovered = conflictStore.pendingPayments.rows.first { $0.id == original.id }!
    expect(recovered.conflict == true && recovered.amount == "900.00" && recovered.stage == .pay,
           "restoring a removed conflict preserves confirmed values and unresolved evidence")
}
