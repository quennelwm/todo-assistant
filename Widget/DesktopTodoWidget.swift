import SwiftUI
import WidgetKit
import AppIntents

struct TodoEntry: TimelineEntry {
    let date: Date
    let tasks: [TodoItem]
    var unavailable = false
    var scope: TodoBoardScope = .all
    var payments: PendingPaymentList = .notConnected
    var paymentScope: PaymentScope = .application
    var navigation = WidgetNavigation(scope: TodoBoardScope.all.rawValue, paymentScope: nil)
    var appearance = WidgetAppearanceSettings()
}

struct TodoTimeline: TimelineProvider {
    func placeholder(in context: Context) -> TodoEntry {
        let sample = [("确认报价", "我", "客户", TodoLane.personal), ("安排物料寄送", "同事", "供应商", TodoLane.team)]
        return TodoEntry(date: .now, tasks: sample.enumerated().map { index, row in
            TodoItem(source: SourceTask(id: "sample-\(index)", title: row.0, owner: row.1, contact: row.2,
                                        due: TodoClock.day(.now), lane: row.3, state: .open, notes: nil,
                                        evidence: [], aliases: []))
        })
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoEntry>) -> Void) {
        let current = load()
        let now = current.date
        let calendar = TodoClock.calendar
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let expiry = now.addingTimeInterval(60 * 60)
        let dueTimes = current.tasks.compactMap { task -> Date? in
            guard task.state == .open, let value = task.due, value.count > 10,
                  let due = TodoClock.parse(value), due > now, due <= expiry else { return nil }
            return due
        }
        let changes = Set(dueTimes + (midnight <= expiry ? [midnight] : [])).sorted()
        let entries = [current] + changes.map {
            TodoEntry(date: $0, tasks: current.tasks, unavailable: current.unavailable, scope: current.scope,
                      payments: current.payments, paymentScope: current.paymentScope, navigation: current.navigation,
                      appearance: current.appearance)
        }
        completion(Timeline(entries: entries, policy: .after(expiry)))
    }

    private func load() -> TodoEntry {
        do {
            let store = try TodoStore.shared()
            let scope = store.widgetScope()
            let appearance = store.widgetAppearance()
            if scope == .payment {
                let payments = store.pendingPayments
                return TodoEntry(date: .now, tasks: [], scope: scope, payments: payments,
                                 paymentScope: store.paymentScope() ?? payments.initialScope, navigation: store.widgetNavigation(),
                                 appearance: appearance)
            }
            return TodoEntry(date: .now, tasks: try store.load(), scope: scope, navigation: store.widgetNavigation(),
                             appearance: appearance)
        } catch {
            return TodoEntry(date: .now, tasks: [], unavailable: true)
        }
    }
}

struct TodoWidgetView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var entry: TodoEntry

    private var backgroundOpacity: Double {
        reduceTransparency ? 1 : entry.appearance.backingOpacity
    }

    private var cardOpacity: Double {
        reduceTransparency ? 1 : entry.appearance.cardOpacity
    }

    var body: some View {
        let board = TodoBoardSnapshot(items: entry.tasks, scope: entry.scope, now: entry.date)
        GeometryReader { available in
            let latest = entry.scope == .payment ? entry.payments.removedRows.first : nil
            let height = max(1, available.size.height - 90
                             - (entry.scope == .payment ? 33 : 0) - (latest == nil ? 0 : 31))
            let heights = entry.scope == .payment
                ? entry.payments.rows(in: entry.paymentScope).map { WidgetRowMetrics.payment($0, width: available.size.width) }
                : board.rows.map { WidgetRowMetrics.task($0, width: available.size.width, now: entry.date) }
            let page = TodoPagination(heights: heights, available: height,
                                      spacing: entry.scope == .payment ? 6 : 4, requestedPage: entry.navigation.page)
            VStack(alignment: .leading, spacing: 9) {
                header(board: board, page: page).frame(height: 26)
                Divider().frame(height: 1)
                if entry.scope == .payment { paymentFilters.frame(height: 24) }
                list(board: board, range: page.range)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: available.size.width, height: height, alignment: .topLeading)
                    .clipped().contentShape(Rectangle())
                if let latest {
                    HStack {
                        Text("已移除 \(entry.payments.removedRows.count) 项").foregroundStyle(.white.opacity(0.74))
                        Spacer()
                        Button(intent: SetPaymentExcluded(latest, excluded: false)) { Text("撤销最近移除") }
                            .buttonStyle(.plain).accessibilityLabel("恢复「\(latest.project)」")
                    }.font(.system(size: 11)).frame(height: 22)
                }
                Divider().frame(height: 1)
                filters.frame(height: 26)
            }
        }
        .padding(15)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if backgroundOpacity > 0 {
                // Keep the adjustable tint separate from the system's widget material.
                solidFill(NSColor(srgbRed: 0.025, green: 0.03, blue: 0.045, alpha: 1)).opacity(backgroundOpacity)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(TodoBoardScope.allCases) { scope in
                Button(intent: SetTodoScope(scope)) {
                    Text(scope.rawValue)
                        .font(.system(size: 12, weight: entry.scope == scope ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(.white.opacity(entry.scope == scope ? 0.14 : 0.04),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(entry.scope == scope ? .isSelected : [])
            }
        }
    }

    private var paymentFilters: some View {
        HStack(spacing: 6) {
            ForEach(PaymentScope.allCases) { scope in
                Button(intent: SetPaymentScope(scope)) {
                    Text(scope.title)
                        .font(.system(size: 11, weight: entry.paymentScope == scope ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(.white.opacity(entry.paymentScope == scope ? 0.14 : 0.04),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(entry.paymentScope == scope ? .isSelected : [])
            }
        }
    }

    private func list(board: TodoBoardSnapshot, range: Range<Int>) -> some View {
        return VStack(alignment: .leading, spacing: entry.scope == .payment ? 6 : 4) {
            if entry.unavailable {
                message("点击顶部打开待办助手检查。")
            } else if entry.scope == .payment {
                let rows = entry.payments.rows(in: entry.paymentScope)
                if rows.isEmpty {
                    message(entry.payments.emptyMessage(for: entry.paymentScope))
                }
                ForEach(Array(rows[range])) { payment in
                    PendingPaymentRow(payment: payment, fillOpacity: cardOpacity)
                }
            } else if board.rows.isEmpty {
                message("暂无待办，点击顶部打开窗口，再点 ＋ 添加。")
            } else {
                ForEach(Array(board.rows[range])) { row($0) }
            }
        }
    }

    private func header(board: TodoBoardSnapshot, page: TodoPagination) -> some View {
        HStack(spacing: 10) {
            Link(destination: TodoStore.boardURL(scope: entry.scope)) {
                Text("待办助手").font(.system(size: 16, weight: .semibold)).fixedSize()
            }.accessibilityHint("打开待办助手窗口")
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Button(intent: SetWidgetPage(page: page.page - 1, navigation: entry.navigation)) {
                    Image(systemName: "chevron.left").frame(width: 22, height: 26).contentShape(Rectangle())
                }.disabled(!page.hasPrevious).opacity(page.hasPrevious ? 0.8 : 0.25)
                    .accessibilityLabel("上一页").help("上一页")
                Button(intent: SetWidgetPage(page: page.page + 1, navigation: entry.navigation)) {
                    Image(systemName: "chevron.right").frame(width: 22, height: 26).contentShape(Rectangle())
                }.disabled(!page.hasNext).opacity(page.hasNext ? 0.8 : 0.25)
                    .accessibilityLabel("下一页").help("下一页")
            }
            .font(.system(size: 12, weight: .medium))
            .accessibilityValue("第 \(page.page + 1) 页，共 \(page.starts.count) 页")
            Link(destination: TodoStore.boardURL(scope: entry.scope)) {
                Text(entry.scope == .payment
                     ? entry.paymentScope.countLabel(entry.payments.rows(in: entry.paymentScope).count)
                     : "\(board.activeCount) 项待办")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.74)).fixedSize()
            }
        }.buttonStyle(.plain)
    }

    private func message(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.white.opacity(0.74))
    }

    private func row(_ item: TodoItem) -> some View {
        let urgency = item.urgency(at: entry.date)
        return HStack(alignment: .top, spacing: 8) {
            if item.state == .open {
                Button(intent: SetTodoState(id: item.id, completed: true)) {
                    Image(systemName: "circle").font(.system(size: 16))
                        .frame(width: 25, height: 25).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("完成 \(item.title)")
            } else {
                Image(systemName: item.state == .done ? "checkmark.circle.fill" : "minus.circle")
                    .font(.system(size: 16)).frame(width: 25, height: 25)
                    .accessibilityHidden(true)
            }
            Link(destination: TodoStore.detailURL(id: item.id)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 14, weight: .medium))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(item.rowMetadata(at: entry.date))
                        .font(.system(size: 11)).foregroundStyle(urgency.metadataColor)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开此事项的详情")
        }
        .foregroundStyle(urgency.titleColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(minHeight: 40, alignment: .topLeading)
        .background {
            if let fill = item.cardTone(at: entry.date)?.rowFill {
                solidFill(fill).opacity(cardOpacity).clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func solidFill(_ color: NSColor) -> some View {
        let tile = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            rect.fill(using: .copy)
            return true
        }
        return Image(nsImage: tile).resizable().widgetAccentedRenderingMode(.fullColor)
    }
}

@main
struct DesktopTodoWidget: Widget {
    private var families: [WidgetFamily] {
        if #available(macOS 27, *) { return [.systemLarge, .systemExtraLarge, .systemExtraLargePortrait] }
        return [.systemLarge, .systemExtraLarge]
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TodoStore.widgetKind, provider: TodoTimeline()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("待办助手")
        .description("按状态查看个人和团队待办，可直接标记完成。")
        .contentMarginsDisabled()
        .supportedFamilies(families)
    }
}
