import AppKit
import SwiftUI

struct TodoBoard: View {
    @ObservedObject var model: TodoModel
    @State private var scope: TodoBoardScope = .all
    @State private var editing: TodoItem?
    @State private var paymentScope: PaymentScope?
    @State private var showingRemovedPayments = false
    @State private var creating: NewTodoDraft?
    @State private var added: TodoItem?
    @State private var scrollEpoch = UUID()
    @State private var showingSettings = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let board = TodoBoardSnapshot(items: model.items, scope: scope, now: context.date)
            VStack(alignment: .leading, spacing: 11) {
                header(board: board)
                Divider()
                if scope == .payment {
                    paymentPicker
                }
                ScrollView {
                    if scope == .payment {
                        paymentList
                    } else {
                        taskList(board: board, now: context.date)
                    }
                }
                .defaultScrollAnchor(.top)
                .id(scrollEpoch)
                if let added {
                    HStack {
                        Text("已添加：\(added.title)").lineLimit(1)
                        Spacer()
                        Button("查看") { editing = added }
                        Button { self.added = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("关闭添加提示")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let undo = model.undo {
                    HStack(spacing: 8) {
                        Text(undo.state == .done ? "已完成事项" : "已取消事项")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("撤销") {
                            model.undoState()
                        }
                    }
                    .font(.system(size: 12))
                    .padding(8)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                if let error = model.operationError {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if scope == .payment && !model.pendingPayments.removedRows.isEmpty {
                    Button("已移除 \(model.pendingPayments.removedRows.count) 项 · 查看与恢复") {
                        showingRemovedPayments = true
                    }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 6) {
                    ForEach(TodoBoardScope.allCases) { target in
                        Button {
                            scope = target
                            scrollEpoch = UUID()
                        } label: {
                            Text(target.rawValue)
                                .font(.system(size: 12, weight: scope == target ? .semibold : .regular))
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(.white.opacity(scope == target ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(scope == target ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
        }
        .background(Color(.sRGB, red: 0.095, green: 0.105, blue: 0.12))
        .preferredColorScheme(.dark)
        .onReceive(model.$requestedScope.compactMap { $0 }) { scope in
            self.scope = scope
            scrollEpoch = UUID()
            model.requestedScope = nil
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if editing == nil && creating == nil { model.refreshView() }
        }
        .sheet(item: $editing) { item in
            TodoEditor(item: item, save: { model.save($0, item: item) },
                       changeState: { model.changeState($0, of: item) }, close: { editing = nil })
        }
        .sheet(isPresented: $showingRemovedPayments) {
            RemovedPaymentsView(model: model, close: { showingRemovedPayments = false })
        }
        .sheet(isPresented: $showingSettings) {
            TodoSettings(save: model.setWidgetAppearance)
        }
        .sheet(item: $creating) { draft in
            NewTodoEditor(draft: draft, save: { draft in
                guard let item = model.createTask(draft) else {
                    let message = model.editError ?? "保存失败，请重试。"
                    model.editError = nil
                    return message
                }
                if scope == .payment || !scope.includes(item.lane) { scope = item.lane == .team ? .team : .personal }
                added = item
                scrollEpoch = UUID()
                creating = nil
                return nil
            }, close: { creating = nil })
        }
        .alert("待办未更新", isPresented: Binding(get: { model.editError != nil },
                                                  set: { if !$0 { model.editError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.editError ?? "")
        }
    }

    private func header(board: TodoBoardSnapshot) -> some View {
        HStack(spacing: 9) {
            Text("待办助手").font(.system(size: 16, weight: .semibold))
            if scope == .payment {
                Text("· " + currentPaymentScope.countLabel(model.pendingPayments.rows(in: currentPaymentScope).count)).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("· \(board.activeCount) 项待办")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { creating = NewTodoDraft(lane: scope == .team ? .team : .personal) } label: {
                Image(systemName: "plus")
            }.buttonStyle(.borderless).help("新增待办").accessibilityLabel("新增待办")
            Button { model.sync() } label: {
                Image(systemName: model.failures.isEmpty ? "arrow.clockwise" : "exclamationmark.triangle")
            }
            .buttonStyle(.borderless)
            .disabled(model.syncing)
            .help(model.failures.isEmpty ? "立即同步" : model.failures.joined(separator: "\n"))
            .accessibilityLabel("立即同步")
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")
            .accessibilityLabel("设置")
        }
    }

    private func taskList(board: TodoBoardSnapshot, now: Date) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if board.rows.isEmpty {
                Text("暂无待办，点击右上角 ＋ 添加").foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(board.rows) { item in
                TodoBoardRow(item: item, now: now,
                             open: { editing = item },
                             change: { _ = model.changeState($0, of: item) },
                             pin: { model.setPlanning(for: item, pinned: !item.isPinned) },
                             prioritize: { model.setPlanning(for: item, priority: item.priority == .high ? .normal : .high) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentPaymentScope: PaymentScope {
        paymentScope ?? model.pendingPayments.initialScope
    }

    private var paymentPicker: some View {
        Picker("款项阶段", selection: Binding(get: { currentPaymentScope }, set: { paymentScope = $0; scrollEpoch = UUID() })) {
            ForEach(PaymentScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var paymentList: some View {
        let rows = model.pendingPayments.rows(in: currentPaymentScope)
        return LazyVStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text(model.pendingPayments.emptyMessage(for: currentPaymentScope))
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(rows) { payment in
                VStack(alignment: .leading, spacing: 2) {
                    PendingPaymentRow(payment: payment, advance: { model.advancePayment(payment) },
                                      remove: { model.removePayment(payment) })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodoSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var appearance = WidgetAppearanceSettings()
    @State private var error: String?
    let save: (WidgetAppearanceSettings) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.headline)
            GroupBox("外观") {
                VStack(alignment: .leading, spacing: 10) {
                    transparencySlider("底板透明度", value: $appearance.backingTransparency)
                    transparencySlider("卡片底色透明度", value: $appearance.cardTransparency)
                    ZStack(alignment: .leading) {
                        LinearGradient(colors: [.indigo, .teal.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Color(red: 0.025, green: 0.03, blue: 0.045)
                            .opacity(reduceTransparency ? 1 : appearance.backingOpacity)
                        VStack(alignment: .leading, spacing: 7) {
                            Label("普通待办", systemImage: "circle")
                            Label("已完成", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(
                                    Color(nsColor: TodoCardTone.done.rowFill)
                                        .opacity(reduceTransparency ? 1 : appearance.cardOpacity),
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                        }
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(10)
                    }
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                    Text(reduceTransparency ? "macOS 已开启「降低透明度」，当前使用实色背景。" : "底板滑杆调节深色遮罩。壁纸透出效果由 macOS 的「图标与小组件样式」决定。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("恢复默认") { appearance = WidgetAppearanceSettings() }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try save(appearance)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 350)
        .onAppear {
            if let store = try? TodoStore.shared() {
                appearance = store.widgetAppearance()
            }
        }
    }

    private func transparencySlider(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)%").monospacedDigit()
            }
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0) }
            ), in: 0...100, step: 1)
                .accessibilityLabel(title)
                .accessibilityValue("\(value.wrappedValue)%")
        }
    }
}

private struct TodoBoardRow: View {
    let item: TodoItem
    let now: Date
    let open: () -> Void
    let change: (TodoState) -> Void
    let pin: () -> Void
    let prioritize: () -> Void

    private enum Control: Hashable { case complete, detail, more }
    @State private var hovering = false
    @FocusState private var focus: Control?

    var body: some View {
        let urgency = item.urgency(at: now)
        HStack(alignment: .top, spacing: 8) {
            if item.state == .open {
                Button { change(.done) } label: {
                    Image(systemName: "circle").font(.system(size: 17))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focus, equals: .complete)
                .accessibilityLabel("完成 \(item.title)")
            } else {
                Image(systemName: item.state == .done ? "checkmark.circle.fill" : "minus.circle")
                    .font(.system(size: 17))
                    .frame(width: 24, height: 24).accessibilityHidden(true)
            }
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.rowMetadata(at: now))
                        .font(.system(size: 11))
                        .foregroundStyle(urgency.metadataColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .detail)
            .accessibilityHint("查看完整内容、相关人员与来源")
            Menu {
                Button("查看完整详情", action: open)
                if item.state == .open {
                    Button(item.isPinned ? "取消置顶" : "置顶", action: pin)
                    Button(item.priority == .high ? "设为普通优先级" : "设为高优先级", action: prioritize)
                    Divider()
                    Button("取消事项", role: .destructive) { change(.cancelled) }
                } else {
                    Button("恢复为待办") { change(.open) }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 21, height: 23)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focused($focus, equals: .more)
            .accessibilityLabel("更多操作")
            .opacity(hovering || focus != nil ? 1 : 0.28)
        }
        .foregroundStyle(urgency.titleColor)
        .padding(.vertical, 7)
        .padding(.horizontal, 7)
        .frame(minHeight: 51, alignment: .leading)
        .background {
            if let fill = item.cardTone(at: now)?.rowFill {
                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: fill))
            }
        }
        .overlay {
            if hovering || focus != nil {
                RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15))
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
    }
}
