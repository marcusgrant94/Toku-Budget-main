//
//  StatsView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import SwiftUI
import CoreData
import Charts

// MARK: - StatsView

struct StatsView: View {
    let window: DateWindow
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.suggestionNavigator) private var navigateSuggestion

    // Tweak these two numbers to taste
    private enum Layout {
        static let chartHeight: CGFloat = 400   // ⬅️ was larger
        static let pieWidth: CGFloat   = 450   // ⬅️ was wider
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

    private var budgetedCategoryIDs: Set<NSManagedObjectID> {
        Set(budgets.compactMap { $0.category?.objectID })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Spending by Category").font(.title3).bold()

                HStack(alignment: .top, spacing: 14) {
                    StatsPieChart(totals: categoryTotals)
                        .frame(width: Layout.pieWidth, height: Layout.chartHeight)   // ⬅️ smaller pie
                        .clipped()

                    CategoryBreakdownList(
                        totals: categoryTotals,
                        grandTotal: totalSpent,
                        currency: currencyCode
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.chartHeight)                               // ⬅️ capped height
                    .clipped()
                }
                .card()

                BalanceSuggestionsCard(
                    window: window,
                    totals: categoryTotals,
                    grandTotal: totalSpent,
                    budgetedCategoryIDs: budgetedCategoryIDs,
                    currency: currencyCode,
                    onAction: { navigateSuggestion($0) }
                )
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
        .chartLegend(position: .bottom, alignment: .leading, spacing: 4) // ⬅️ tighter legend
        .padding(6)
    }
}

private struct CategoryBreakdownList: View {
    let totals: [(category: Category?, total: Double)]
    let grandTotal: Double
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {               // ⬅️ tighter spacing
            HStack {
                Text("Category").foregroundStyle(.secondary)
                Spacer()
                Text("Spent").foregroundStyle(.secondary)
                Text("%").foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }
            .font(.caption2)                                     // ⬅️ smaller header

            // Compact rows
            ScrollView(.vertical, showsIndicators: false) {      // ⬅️ scroll if content exceeds cap
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


// MARK: - BalanceSuggestionsCard

/// Lightweight suggestion model (reuses your SuggestionAction routing).
private struct BalanceSuggestion: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let detail: String
    let confidence: Double        // 0…1 (used as a hint badge)
    let actions: [SuggestionAction]
}

private struct BalanceSuggestionsCard: View {
    let window: DateWindow
    let totals: [(category: Category?, total: Double)]
    let grandTotal: Double
    let budgetedCategoryIDs: Set<NSManagedObjectID>
    let currency: String
    var onAction: (SuggestionAction) -> Void

    @State private var suggestions: [BalanceSuggestion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Balance your spending").font(.headline)
                Spacer()
                Button {
                    recompute()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh suggestions")
            }

            if suggestions.isEmpty {
                Text("No balance suggestions right now")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestions) { s in
                    BalanceSuggestionRow(s: s, currency: currency) { action in
                        onAction(action)
                    }
                    Divider().opacity(0.25)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
        .onAppear { recompute() }
    }

    private func recompute() {
        suggestions = BalanceSuggestionEngine.make(
            totals: totals,
            grandTotal: grandTotal,
            budgetedCategoryIDs: budgetedCategoryIDs,
            currency: currency
        )
    }
}

private struct BalanceSuggestionRow: View {
    let s: BalanceSuggestion
    let currency: String
    var onTap: (SuggestionAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(s.title).font(.subheadline).bold()
                Spacer()
                Text("\(Int(s.confidence * 100))%")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
            Text(s.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let primary = s.actions.first {
                    Button(primaryButtonLabel(primary)) { onTap(primary) }
                        .buttonStyle(.borderedProminent)
                }
                ForEach(Array(s.actions.dropFirst()), id: \.self) { a in
                    Button(secondaryButtonLabel(a)) { onTap(a) }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func primaryButtonLabel(_ a: SuggestionAction) -> String {
        switch a {
        case .setBudget:         return "Set Budget…"
        case .openBudgets:       return "Open Budgets"
        case .openSubscriptions: return "Review Subs"
        case .openTrends:        return "Open Trends"
        }
    }

    private func secondaryButtonLabel(_ a: SuggestionAction) -> String {
        switch a {
        case .setBudget:         return "Set Budget…"
        case .openBudgets:       return "Budgets"
        case .openSubscriptions: return "Subs"
        case .openTrends:        return "Trends"
        }
    }
}

// MARK: - Engine (heuristics tuned for the pie view)

private enum BalanceSuggestionEngine {

    static func make(
        totals: [(category: Category?, total: Double)],
        grandTotal: Double,
        budgetedCategoryIDs: Set<NSManagedObjectID>,
        currency: String
    ) -> [BalanceSuggestion] {
        guard grandTotal > 0 else { return [] }

        var out: [BalanceSuggestion] = []

        // 1) Top-heavy category (>50% of spend)
        if let top = totals.first, top.total / grandTotal >= 0.50, let cat = top.category {
            let cap = top.total * 0.9 // suggest 10% reduction
            let title = "Spending is concentrated in \(cat.name ?? "—")"
            let detail = "This category accounts for \(percent(top.total, of: grandTotal)). Consider capping it around \(format(cap, code: currency)) next month."
            out.append(BalanceSuggestion(
                title: title,
                detail: detail,
                confidence: 0.85,
                actions: [.setBudget(categoryID: cat.objectID), .openBudgets, .openTrends]
            ))
        }

        // 2) Top-3 share too high (>80%)
        let top3Total = totals.prefix(3).map(\.total).reduce(0, +)
        if top3Total / grandTotal >= 0.80 {
            let names = totals.prefix(3).map { $0.category?.name ?? "—" }.joined(separator: ", ")
            let title = "Most spend is in just a few categories"
            let detail = "Top categories (\(names)) make up \(percent(top3Total, of: grandTotal)) of spending. Diversify or set caps to keep balance."
            out.append(BalanceSuggestion(
                title: title,
                detail: detail,
                confidence: 0.7,
                actions: [.openBudgets, .openTrends]
            ))
        }

        // 3) Categories with spend but no budget (help user create one)
        let missingBudgetCats: [Category] = totals.compactMap { pair in
            guard let c = pair.category, pair.total >= 0.01 else { return nil }
            return budgetedCategoryIDs.contains(c.objectID) ? nil : c
        }
        if let first = missingBudgetCats.first {
            let title = "No budget set for \(first.name ?? "—")"
            let detail = "You're spending here without a cap. Create a budget to stay on track."
            out.append(BalanceSuggestion(
                title: title,
                detail: detail,
                confidence: 0.65,
                actions: [.setBudget(categoryID: first.objectID), .openBudgets]
            ))
        }

        return out
    }

    private static func percent(_ part: Double, of whole: Double) -> String {
        let p = (whole > 0) ? (part / whole * 100.0) : 0
        return String(format: "%.1f%%", p)
    }

    private static func format(_ value: Double, code: String) -> String {
        value.formatted(.currency(code: code))
    }
}

