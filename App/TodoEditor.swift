import AppKit
import SwiftUI

struct TodoDraft {
    var title: String
    var notes: String
    var owner: String
    var contact: String
    var lane: TodoLane
    var hasDeadline: Bool
    var includesTime: Bool
    var date: Date
    var deadline: String? {
        guard hasDeadline else { return nil }
        return includesTime ? TodoClock.timestamp(date) : TodoClock.day(date)
    }

    init(_ item: TodoItem) {
        title = item.title
        notes = item.notes ?? ""
        owner = item.owner ?? ""
        contact = item.contact ?? ""
        lane = item.lane
        hasDeadline = item.due != nil
        includesTime = item.due.map { $0.count > 10 } ?? false
        date = TodoClock.parse(item.due) ?? .now
    }
}

struct TodoEditor: View {
    let item: TodoItem
    let save: (TodoDraft) -> Bool
    let changeState: (TodoState) -> Bool
    let close: () -> Void
    @State private var draft: TodoDraft

    init(item: TodoItem, save: @escaping (TodoDraft) -> Bool, changeState: @escaping (TodoState) -> Bool,
         close: @escaping () -> Void) {
        self.item = item
        self.save = save
        self.changeState = changeState
        self.close = close
        _draft = State(initialValue: TodoDraft(item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("事项详情").font(.system(size: 16, weight: .semibold))
            Form {
                TextField("待办名称", text: $draft.title, axis: .vertical).lineLimit(2...4)
                if item.locallyCreated == true {
                    TextField("备注", text: $draft.notes, axis: .vertical).lineLimit(2...4)
                }
                Picker("栏目", selection: $draft.lane) {
                    ForEach(TodoLane.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("负责人", text: $draft.owner, prompt: Text("待确认"))
                TextField("对接人", text: $draft.contact, prompt: Text("客户或供应商"))
                Toggle("设定截止时间", isOn: $draft.hasDeadline)
                if draft.hasDeadline {
                    Toggle("指定具体钟点", isOn: $draft.includesTime)
                    DatePicker("截止时间", selection: $draft.date,
                               displayedComponents: draft.includesTime ? [.date, .hourAndMinute] : [.date])
                        .environment(\.timeZone, TodoClock.zone)
                        .environment(\.calendar, TodoClock.calendar)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    let original = item.source.originalText ?? item.source.title
                    if original != item.title {
                        Text("原文").font(.caption.weight(.semibold))
                        Text(original).textSelection(.enabled)
                    }
                    if let notes = item.notes, !notes.isEmpty {
                        Text(notes).textSelection(.enabled)
                    }
                    ForEach(item.source.evidence, id: \.self) { evidence in
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: evidence.path))
                        } label: {
                            Label(evidence.label, systemImage: "doc.text")
                        }.buttonStyle(.link)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 105, maxHeight: 175)
            Text("截止时间使用北京时间").font(.caption).foregroundStyle(.secondary)
            HStack {
                if item.state == .open {
                    Button("取消事项", role: .destructive) {
                        if changeState(.cancelled) { close() }
                    }
                } else {
                    Button("恢复为待办") {
                        if changeState(.open) { close() }
                    }
                }
                Spacer()
                Button("关闭") { close() }.keyboardShortcut(.cancelAction)
                Button("保存") { if save(draft) { close() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(15)
        .frame(width: 355)
    }
}

struct NewTodoEditor: View {
    @State var draft: NewTodoDraft
    let save: (NewTodoDraft) -> String?
    let close: () -> Void
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("新增待办").font(.system(size: 16, weight: .semibold))
            TextField("填写要做的事项", text: $draft.title, axis: .vertical)
                .font(.system(size: 15)).lineLimit(2...4).focused($titleFocused)
                .accessibilityLabel("事项内容")
            Form {
                Picker("栏目", selection: $draft.lane) {
                    Text("个人").tag(TodoLane.personal)
                    Text("团队").tag(TodoLane.team)
                }
                TextField("负责人", text: $draft.owner, prompt: Text("可不填"))
                TextField("对接人", text: $draft.contact, prompt: Text("客户或供应商，可不填"))
                Toggle("设定截止日期", isOn: $draft.hasDeadline)
                if draft.hasDeadline {
                    Toggle("指定具体钟点", isOn: $draft.includesTime)
                    DatePicker("截止日期", selection: $draft.date,
                               displayedComponents: draft.includesTime ? [.date, .hourAndMinute] : [.date])
                        .environment(\.timeZone, TodoClock.zone)
                        .environment(\.calendar, TodoClock.calendar)
                }
            }
            Text("备注（选填）").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $draft.notes).font(.system(size: 13))
                .frame(height: 85).padding(6)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("备注")
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack {
                Text("只需填写事项即可保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("添加") {
                    do { _ = try draft.source(); error = save(draft) }
                    catch { self.error = error.localizedDescription; titleFocused = true }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 365)
        .preferredColorScheme(.dark)
        .onAppear { titleFocused = true }
    }
}

struct PaymentDetail: View {
    @ObservedObject var model: TodoModel
    let paymentID: String
    let close: () -> Void
    @State private var editing: PendingPayment?
    @State private var editToken = UUID()
    @State private var history: [TodoOperation] = []
    @State private var notice: String?
    @State private var error: String?
    @State private var confirmingUndo = false

    private var payment: PendingPayment? {
        (model.pendingPayments.rows + model.pendingPayments.removedRows).first { $0.id == paymentID }
    }

    var body: some View {
        Group {
            if let payment {
                if let snapshot = editing, !payment.isRemoved {
                    PaymentVerificationForm(payment: snapshot, isStale: snapshot != payment, reload: {
                        editing = payment; editToken = UUID()
                    }, save: { draft in
                        guard model.verifyPayment(snapshot, draft: draft) else {
                            let message = model.editError ?? "保存失败，请重试。"
                            model.editError = nil
                            return message
                        }
                        editing = nil
                        notice = "已保存，已移至「\(draft.stage.scope.title)」"
                        loadHistory()
                        return nil
                    }, cancel: { editing = nil })
                    .id(editToken)
                } else {
                    details(payment)
                }
            } else {
                VStack(spacing: 15) {
                    Text("暂时无法读取这笔款项，请稍后重试。")
                    Button("重新读取") { model.refreshView() }
                    Button("关闭", action: close)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .background(Color(.sRGB, red: 0.095, green: 0.105, blue: 0.12))
        .preferredColorScheme(.dark)
        .onAppear { loadHistory() }
        .onChange(of: payment?.lastOperationID) { _, _ in loadHistory() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in model.refreshView() }
        .alert("未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("撤销最近一次款项记录？", isPresented: $confirmingUndo, titleVisibility: .visible) {
            Button("撤销这次记录") {
                guard let payment, let event = history.last else { return }
                if model.undoPayment(payment, eventID: event.event_id) {
                    notice = "已撤销最近一次记录"; loadHistory()
                } else {
                    error = model.editError; model.editError = nil
                }
            }
            Button("返回", role: .cancel) {}
        } message: {
            Text("恢复这次记录修改前的字段，并保留撤销记录。这不会撤回实际请款或付款。")
        }
    }

    private func details(_ payment: PendingPayment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("款项详情").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(payment.displayStage).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color(nsColor: payment.rowFill), in: Capsule())
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PaymentNameEditor(payment: payment, save: { expected, name in
                        if model.renamePayment(expected, name: name) {
                            notice = "名称已保存"; loadHistory(); return nil
                        }
                        let message = model.editError ?? "保存失败，请重试。"
                        model.editError = nil
                        return message
                    })
                    if let original = payment.originalProject {
                        DisclosureGroup("原始款项名称") {
                            Text(original).font(.system(size: 12)).textSelection(.enabled)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(payment.formattedAmount).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        if payment.scope == .verification {
                            Text("原记录金额，款项进度与实际未付金额待核实")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(.green) }
                    if payment.isRemoved {
                        Text("此项已移除，不再显示在待办列表。可以在下方恢复。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if payment.conflict == true { PaymentConflictView(payment: payment) }
                    VStack(alignment: .leading, spacing: 9) {
                        if let value = payment.counterparty { field("收款方", value) }
                        if let value = payment.due { field("截止日期", TodoClock.label(value)) }
                        if let value = payment.application_id { field("申请单号", value) }
                        if let value = payment.paid_amount { field("已付金额", value) }
                        if let value = payment.remaining_amount { field("未付金额", value) }
                    }
                    if let note = payment.confirmationNote {
                        section("最近确认 · \(TodoClock.label(payment.confirmedAt ?? payment.updated_at))", note)
                    }
                    if let action = payment.next_action, !action.isEmpty {
                        section(payment.confirmedAt == nil ? "下一步" : "来源中的跟进提示", action)
                    }
                    if !payment.evidence.isEmpty {
                        Divider()
                        Text("来源与说明").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(Array(payment.evidence.enumerated()), id: \.offset) { _, evidence in
                            section(evidence.source, evidence.summary)
                        }
                        DisclosureGroup("查看来源编号") {
                            ForEach(Array(payment.evidence.enumerated()), id: \.offset) { _, evidence in
                                Text(evidence.source + " · " + evidence.refs.joined(separator: "、"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.font(.system(size: 11))
                    }
                    if !history.isEmpty {
                        Divider()
                        DisclosureGroup("核实记录（\(history.count)）") {
                            VStack(alignment: .leading, spacing: 13) {
                                ForEach(history.reversed(), id: \.event_id) { event in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(TodoClock.label(event.occurred_at)) · \(paymentActionName(event.action))")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                        if let note = event.note { Text(note).font(.system(size: 12)) }
                                        ForEach(event.after.keys.sorted(), id: \.self) { key in
                                            Text("\(paymentFieldName(key))：\(paymentFieldValue(key, event.before[key] ?? nil)) → \(paymentFieldValue(key, event.after[key] ?? nil))")
                                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }.padding(.top, 8)
                        }.font(.system(size: 12))
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = model.operationError {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                if let event = history.last, [.verifyPayment, .changePaymentStage, .changeTitle].contains(event.action),
                   payment.conflict != true, !payment.isRemoved {
                    Button("撤销上次") { confirmingUndo = true }
                }
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
                if payment.isRemoved {
                    Button("恢复此项") {
                        if model.restorePayment(payment) {
                            editing = nil; notice = "已恢复此项"; loadHistory()
                        } else { error = model.editError; model.editError = nil }
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button(payment.scope == .verification ? "核实款项" : "更新进度") {
                        editing = payment; editToken = UUID(); notice = nil
                    }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func loadHistory() {
        do { history = try TodoStore.shared().paymentHistory(id: paymentID) }
        catch { self.error = "无法读取核实记录。" + error.localizedDescription }
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12))
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PaymentNameEditor: View {
    let payment: PendingPayment
    let save: (PendingPayment, String) -> String?
    @State private var name: String
    @State private var baseline: PendingPayment?
    @State private var error: String?

    init(payment: PendingPayment, save: @escaping (PendingPayment, String) -> String?) {
        self.payment = payment; self.save = save
        _name = State(initialValue: payment.project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("款项名称", text: Binding(get: { name }, set: {
                if baseline == nil { baseline = payment }
                name = $0; error = nil
            }), axis: .vertical)
                .font(.system(size: 17, weight: .medium)).lineLimit(1...4)
                .textFieldStyle(.roundedBorder).accessibilityLabel("款项名称")
                .disabled(payment.isRemoved)
            if baseline != nil {
                HStack {
                    Button("放弃修改") { baseline = nil; name = payment.project; error = nil }
                    Spacer()
                    Button("保存名称") {
                        error = save(baseline ?? payment, name)
                        if error == nil { baseline = nil; name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }.buttonStyle(.borderedProminent)
                }.font(.system(size: 12))
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        }
        .onChange(of: payment) { _, updated in
            if baseline == nil { name = updated.project }
        }
    }
}

private struct PaymentVerificationForm: View {
    let payment: PendingPayment
    let isStale: Bool
    let reload: () -> Void
    let save: (PaymentDraft) -> String?
    let cancel: () -> Void
    @State private var draft: PaymentDraft
    @State private var error: String?
    @State private var confirming = false

    init(payment: PendingPayment, isStale: Bool, reload: @escaping () -> Void,
         save: @escaping (PaymentDraft) -> String?, cancel: @escaping () -> Void) {
        self.payment = payment; self.isStale = isStale; self.reload = reload
        self.save = save; self.cancel = cancel
        _draft = State(initialValue: PaymentDraft(payment))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("核实与更新").font(.system(size: 16, weight: .semibold))
            Text(payment.project).font(.system(size: 13, weight: .medium)).lineLimit(2)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if isStale {
                        Text("这笔款项已有新信息，请重新载入后核实。未保存的填写会被清除。")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        Button("重新载入", action: reload)
                    }
                    if payment.conflict == true { PaymentConflictView(payment: payment) }
                    if payment.shared_uncertainty_group != nil {
                        Text("本笔与其他款项有到账归属疑问。请先确认对应项目；此次只更新本笔，不会同时更新其他款项。")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Form {
                        TextField("款项名称", text: $draft.project, axis: .vertical).lineLimit(2...4)
                        Picker("状态", selection: $draft.stage) {
                            ForEach(PaymentStage.selectableCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        TextField("收款方", text: $draft.counterparty)
                        TextField("总金额", text: $draft.amount, prompt: Text("数字，如 900.00"))
                        TextField("币种", text: $draft.currency, prompt: Text("CNY"))
                        TextField("申请单号", text: $draft.applicationID, prompt: Text("有则填写"))
                        TextField("截止日期", text: $draft.due, prompt: Text("YYYY-MM-DD，可留空"))
                        if draft.stage != .paid {
                            TextField("已付金额", text: $draft.paidAmount, prompt: Text("未知留空，不默认零"))
                            TextField("未付金额", text: $draft.remainingAmount, prompt: Text("留空按总额减已付计算"))
                        }
                    }
                    if draft.stage == .paid {
                        Text("确认全部付清后，已付金额将记为总金额，未付金额记为 0。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if payment.stage == .paid {
                        Text("更正误记的付款时，请同时核对已付和未付金额。")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("核实依据 / 更正原因（选填）").font(.system(size: 12, weight: .medium))
                        Text("可填写本人确认、申请单号、付款凭证编号或对方确认内容。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextEditor(text: $draft.note).font(.system(size: 12))
                            .accessibilityLabel("核实依据或更正原因")
                            .frame(height: 70).padding(5)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text("这里只记录进度，不会提交实际请款或执行转账。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.trailing, 3)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button("返回", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存核实结果") {
                    do { _ = try draft.validatedFields(); error = nil; confirming = true }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStale)
            }
        }
        .onChange(of: draft.stage) { _, _ in error = nil }
        .alert("确认记录为「\(draft.stage.title)」？", isPresented: $confirming) {
            Button("返回核对", role: .cancel) {}
            Button("确认记录") { error = save(draft) }
        } message: {
            Text(confirmationSummary)
        }
    }

    private var confirmationSummary: String {
        guard let fields = try? draft.validatedFields() else { return "" }
        let result = payment.applying(fields)
        return "\(payment.project)\n收款方：\(result.counterparty ?? "待确认")\n金额：\(result.formattedAmount)\n已付：\(result.paid_amount ?? "待确认") · 未付：\(result.remaining_amount ?? "待确认")\n\n\(draft.stage.confirmationText)\n保存后进入「\(draft.stage.scope.title)」。"
    }
}

private struct PaymentConflictView: View {
    let payment: PendingPayment
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("来源与上次确认不一致，本机仍保留你的记录。")
                .font(.system(size: 12, weight: .medium))
            ForEach((payment.sourceConflicts ?? [:]).keys.sorted(), id: \.self) { key in
                Text("\(paymentFieldName(key))：本机 \((payment.editableFields[key] ?? nil) ?? "未填写")；来源 \((payment.sourceConflicts?[key] ?? nil) ?? "未填写")")
                    .font(.system(size: 11))
            }
            Text("核对后填写本次确认的值，保存即可解除此冲突。")
                .font(.system(size: 11))
        }
        .foregroundStyle(.orange)
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

private func paymentFieldName(_ key: String) -> String {
    ["project": "款项名称", "stage": "阶段", "counterparty": "收款方", "amount": "总金额", "currency": "币种",
     "application_id": "申请单号", "due": "截止日期", "paid_amount": "已付金额", "remaining_amount": "未付金额",
     "excluded": "列表显示"][key] ?? key
}

private func paymentFieldValue(_ key: String, _ value: String?) -> String {
    if key == "excluded" { return value == "true" ? "已移除" : "正常显示" }
    return value ?? "未填写"
}

private func paymentActionName(_ action: TodoOperation.Action) -> String {
    switch action {
    case .changeTitle: "修改名称"
    case .removePayment: "移除记录"
    case .restore: "恢复记录"
    case .undo: "撤销记录"
    default: "用户确认"
    }
}

struct RemovedPaymentsView: View {
    @ObservedObject var model: TodoModel
    let close: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("已移除款项").font(.system(size: 16, weight: .semibold))
            Text("移除的款项不会自动回来；误操作可在这里恢复。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.pendingPayments.removedRows.isEmpty {
                        Text("暂无已移除款项").foregroundStyle(.secondary)
                    }
                    ForEach(model.pendingPayments.removedRows) { payment in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Link(payment.project, destination: TodoStore.paymentDetailURL(id: payment.id))
                                    .font(.system(size: 14, weight: .medium)).buttonStyle(.plain)
                                Text("\(payment.formattedAmount) · \(TodoClock.label(payment.removedAt)) 移除")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("恢复") {
                                if !model.restorePayment(payment) { error = model.editError; model.editError = nil }
                            }
                            .accessibilityLabel("恢复「\(payment.project)」")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Spacer(); Button("关闭", action: close).keyboardShortcut(.cancelAction) }
        }
        .padding(16).frame(width: 370, height: 390)
        .preferredColorScheme(.dark)
        .alert("未能恢复", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
