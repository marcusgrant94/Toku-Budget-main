//
//  StatsView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import SwiftUI
import CoreData
import Charts

// MARK: - StatsView (AI-only tips)

struct StatsView: View {
    let window: DateWindow
    @Environment(\.managedObjectContext) private var moc

    private enum Layout {
        static let chartHeight: CGFloat = 400
        static let pieWidth: CGFloat   = 450
    }

    @FetchRequest private var txs: FetchedResults<Transaction>
    @FetchRequest private var budgets: FetchedResults<Budget>

    init(window: DateWindow) {
        self.window = window

        let tReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        tReq.predicate = NSPredicate(format: "date >= %@ AND date < %@", window.start as NSDate, window.end as NSDate)
        tReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        _txs = FetchRequest(fetchRequest: tReq, animation: .default)

        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year,.month], from: window.start))!
        let bReq: NSFetchRequest<Budget> = Budget.fetchRequest()
        bReq.predicate = NSPredicate(format: "periodStart == %@", monthStart as NSDate)
        bReq.sortDescriptors = [
            NSSortDescriptor(key: "category.name", ascending: true),
            NSSortDescriptor(key: "uuid",          ascending: true)
        ]
        _budgets = FetchRequest(fetchRequest: bReq, animation: .default)
    }

    private var expenses: [Transaction] { txs.filter { $0.kind == TxKind.expense.rawValue } }
    private var currencyCode: String { expenses.first?.currencyCode ?? "USD" }

    private var categoryTotals: [(category: Category?, total: Double)] {
        guard !expenses.isEmpty else { return [] }
        let groups = Dictionary(grouping: expenses) { $0.category }
        return groups.map { (cat, items) in
            let sum = items.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
            return (cat, (sum as NSDecimalNumber).doubleValue)
        }
        .sorted { $0.total > $1.total }
    }

    private var totalSpent: Double {
        (expenses.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) } as NSDecimalNumber).doubleValue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Spending by Category").font(.title3).bold()

                HStack(alignment: .top, spacing: 14) {
                    StatsPieChart(totals: categoryTotals)
                        .frame(width: Layout.pieWidth, height: Layout.chartHeight)
                        .clipped()

                    CategoryBreakdownList(
                        totals: categoryTotals,
                        grandTotal: totalSpent,
                        currency: currencyCode
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.chartHeight)
                    .clipped()
                }
                .card()

                // 🔵 AI-only tips card (uses your Worker/OpenAI path)
                AITipsCard(window: window, viewID: "stats")
                    .card()
            }
            .padding(16)
        }
    }
}

private struct StatsPieChart: View {
    let totals: [(category: Category?, total: Double)]

    private var rows: [(name: String, total: Double)] {
        totals.map { (cat, v) in ((cat?.name?.isEmpty == false ? cat!.name! : "—"), v) }
    }

    var body: some View {
        Chart(rows, id: \.name) { r in
            SectorMark(angle: .value("Amount", r.total))
                .foregroundStyle(by: .value("Category", r.name))
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 4)
        .padding(6)
    }
}

private struct CategoryBreakdownList: View {
    let totals: [(category: Category?, total: Double)]
    let grandTotal: Double
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Category").foregroundStyle(.secondary)
                Spacer()
                Text("Spent").foregroundStyle(.secondary)
                Text("%").foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }
            .font(.caption2)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Array(totals.enumerated()), id: \.offset) { _, row in
                        let pct = grandTotal > 0 ? row.total / grandTotal : 0
                        VStack(spacing: 4) {
                            HStack(spacing: 8) {
                                Text(row.category?.name ?? "—").font(.subheadline)
                                Spacer()
                                Text(row.total, format: .currency(code: currency))
                                    .monospacedDigit()
                                Text("\(pct * 100, specifier: "%.1f")%")
                                    .frame(width: 48, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                                    .font(.caption2)
                            }
                            ProgressView(value: pct).progressViewStyle(.linear)
                        }
                    }
                }
                .padding(.trailing, 2)
            }

            Divider().opacity(0.25)

            HStack {
                Spacer()
                Text("Total").foregroundStyle(.secondary)
                Text(grandTotal, format: .currency(code: currency))
                    .bold().monospacedDigit()
            }
            .font(.footnote)
        }
        .padding(8)
    }
}


