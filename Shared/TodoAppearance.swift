import SwiftUI
import WidgetKit
import AppIntents

enum WidgetRowMetrics {
    private static func height(_ text: String, width: Double, size: Double, weight: NSFont.Weight, lines: Int) -> Double {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(1, width), height: 10_000),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: [.font: font])
        let line = ceil(font.ascender - font.descender + font.leading)
        return ceil(min(max(line, bounds.height), line * Double(lines)))
    }

    static func task(_ item: TodoItem, width: Double, now: Date) -> Double {
        let textWidth = max(1, width - 47)
        let title = height(item.title, width: textWidth, size: 14, weight: .medium, lines: 2)
        let metadata = height(item.rowMetadata(at: now), width: textWidth, size: 11, weight: .regular, lines: 3)
        return max(40, max(25, title + 3 + metadata) + 10) + 4
    }

    static func payment(_ item: PendingPayment, width: Double) -> Double {
        let title = height(item.project, width: max(1, width - 47), size: 14, weight: .medium, lines: 2)
        return title + 16 + 22 + 12 + 20 + 4
    }
}

extension TodoCardTone {
    var rowFill: NSColor {
        switch self {
        case .overdue: NSColor(srgbRed: 0.40, green: 0.15, blue: 0.17, alpha: 1)
        case .week: NSColor(srgbRed: 0.43, green: 0.36, blue: 0.10, alpha: 1)
        case .done: NSColor(srgbRed: 0.14, green: 0.27, blue: 0.45, alpha: 1)
        case .cancelled: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.22, alpha: 1)
        }
    }
}

extension Urgency {
    var titleColor: Color {
        self == .cancelled ? .white.opacity(0.51) : .white
    }

    var metadataColor: Color {
        .white.opacity(self == .cancelled ? 0.46 : 0.77)
    }
}

extension TodoItem {
    func rowMetadata(at now: Date) -> String {
        ([summaryStatus(at: now)] + summaryFields).joined(separator: " · ")
    }
}

struct PendingPaymentRow: View {
    let payment: PendingPayment
    var advance: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    var fillOpacity: Double = 1

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            progressControl
            Link(destination: TodoStore.paymentDetailURL(id: payment.id)) {
            VStack(alignment: .leading, spacing: 5) {
                Text(payment.project).font(.system(size: 14, weight: .medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text([payment.displayStage, payment.counterparty].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.77))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(payment.listAmount)
                        .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                        .layoutPriority(1)
                    if payment.amount != nil || payment.remaining_amount != nil {
                        Text(payment.listAmountLabel)
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.70))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55)).accessibilityHidden(true)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开此款项的详情")
        }
        .foregroundStyle(.white.opacity(payment.stage == .withdrawn ? 0.51 : 1))
        .padding(.vertical, 10)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PaymentRowFill(color: payment.rowFill)
                .opacity(fillOpacity)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private var progressControl: some View {
        if payment.scope == .verification && !payment.isRemoved {
            Group {
                if let remove {
                    Button(action: remove) { progressIcon }
                } else {
                    Button(intent: SetPaymentExcluded(payment, excluded: true)) { progressIcon }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除「\(payment.project)」")
            .help("移除此项，误操作可以恢复")
        } else if let next = payment.quickNextStage {
            Group {
                if let advance {
                    Button(action: advance) { progressIcon }
                } else {
                    Button(intent: AdvancePayment(payment)) { progressIcon }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(next == .paid ? "标记本笔已付款" : "标记已请款，移至待付款")
            .help(next == .paid ? "标记本笔已付款" : "已请款，移至待付款")
        } else {
            Link(destination: TodoStore.paymentDetailURL(id: payment.id)) { progressIcon }
                .buttonStyle(.plain)
                .accessibilityLabel(payment.scope == .verification ? "核实此款项" : "查看款项详情")
        }
    }

    private var progressIcon: some View {
        Image(systemName: payment.quickNextStage == nil ? payment.stageSymbol : "circle")
            .font(.system(size: 16, weight: .regular))
            .frame(width: 25, height: 25).contentShape(Rectangle())
    }

}

extension PendingPayment {
    var listAmount: String {
        if isPartiallyPaid, let remaining_amount {
            var remaining = self
            remaining.amount = remaining_amount
            return remaining.formattedAmount
        }
        return formattedAmount
    }

    var listAmountLabel: String {
        if scope == .verification { return "记录金额" }
        if isPartiallyPaid { return "未付" }
        if stage == .paid { return "已付" }
        return "总金额"
    }

    private var isPartiallyPaid: Bool {
        scope != .verification && stage.editorStage == .pay && (PaymentDraft.decimal(paid_amount) ?? 0) > 0 &&
            PaymentDraft.decimal(remaining_amount) != nil
    }

    var stageSymbol: String {
        if scope == .verification { return "questionmark.circle" }
        switch stage {
        case .verify: return "questionmark.circle"
        case .apply, .returned: return "doc.text"
        case .submitted, .approving: return "clock"
        case .pay: return "creditcard"
        case .paid: return "checkmark.circle.fill"
        case .withdrawn: return "minus.circle"
        }
    }

    var rowFill: NSColor {
        // Verification is a payment stage, not a confirmed overdue debt.
        if scope == .verification { return NSColor(srgbRed: 0.25, green: 0.22, blue: 0.16, alpha: 1) }
        if stage == .paid { return TodoCardTone.done.rowFill }
        if stage == .withdrawn { return TodoCardTone.cancelled.rowFill }
        return NSColor(srgbRed: 0.15, green: 0.17, blue: 0.19, alpha: 1)
    }
}

private struct PaymentRowFill: View {
    let color: NSColor

    var body: some View {
        let tile = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            rect.fill(using: .copy)
            return true
        }
        Image(nsImage: tile).resizable().widgetAccentedRenderingMode(.fullColor)
    }
}
