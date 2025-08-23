//
//  OverviewView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/16/25.
//

import SwiftUI
import CoreData
import Charts

struct OverviewView: View {
    let window: DateWindow
    let mode: DateRangeMode
    @Environment(\.managedObjectContext) private var moc
    @StateObject private var cloudUser = CloudUser()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.suggestionNavigator) private var navigateSuggestion

    // Current window transactions
    @FetchRequest private var monthTx: FetchedResults<Transaction>
    // Previous window transactions (for % change)
    @FetchRequest private var prevMonthTx: FetchedResults<Transaction>
    // Budgets for current month (for Y-axis max)
    @FetchRequest private var budgets: FetchedResults<Budget>

    // Delete-all confirmation
    @State private var confirmDeleteAll = false

    init(window: DateWindow, mode: DateRangeMode) {
        self.window = window
        self.mode = mode

        // Current window transactions
        let currReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        currReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        currReq.predicate = NSPredicate(format: "date >= %@ AND date < %@",
                                        window.start as NSDate, window.end as NSDate)
        _monthTx = FetchRequest(fetchRequest: currReq, animation: .default)

        // Previous window transactions (for % change)
        let cal = Calendar.current
        let prevEnd = window.start
        let prevStart: Date = {
            switch mode {
            case .month:   return cal.date(byAdding: .month,  value: -1, to: prevEnd)!
            case .quarter: return cal.date(byAdding: .month,  value: -3, to: prevEnd)!
            case .year:    return cal.date(byAdding: .year,   value: -1, to: prevEnd)!
            }
        }()

        let prevReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        prevReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        prevReq.predicate = NSPredicate(format: "date >= %@ AND date < %@",
                                        prevStart as NSDate, prevEnd as NSDate)
        _prevMonthTx = FetchRequest(fetchRequest: prevReq, animation: .default)

        // Budgets (use the month containing window.start)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: window.start))!
        let bReq: NSFetchRequest<Budget> = Budget.fetchRequest()
        bReq.predicate = NSPredicate(format: "periodStart == %@", monthStart as NSDate)
        bReq.sortDescriptors = [
            NSSortDescriptor(key: "category.name", ascending: true),
            NSSortDescriptor(key: "uuid",          ascending: true)
        ]
        _budgets = FetchRequest(fetchRequest: bReq, animation: .default)
    }

    // MARK: - Rollups

    private var monthExpenses: [Transaction] { monthTx.filter { $0.kind == TxKind.expense.rawValue } }
    private var monthIncome:   [Transaction] { monthTx.filter { $0.kind == TxKind.income.rawValue } }

    private var totalSpent: Decimal { monthExpenses.reduce(0) { $0 + ($1.amount?.decimalValue ?? 0) } }
    private var net: Decimal { monthIncome.reduce(0) { $0 + ($1.amount?.decimalValue ?? 0) } - totalSpent }

    private var prevNet: Decimal {
        let exp = prevMonthTx.filter { $0.kind == TxKind.expense.rawValue }
            .reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
        let inc = prevMonthTx.filter { $0.kind == TxKind.income.rawValue }
            .reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
        return inc - exp
    }

    private var pctChangeVsLast: Double? {
        guard !prevMonthTx.isEmpty else { return nil }
        let prev = (prevNet as NSDecimalNumber).doubleValue
        guard prev != 0 else { return nil }
        let curr = (net as NSDecimalNumber).doubleValue
        return ((curr - prev) / abs(prev)) * 100.0
    }

    private var spendYMaxFromBudgets: Double? {
        budgets.map { ($0.amount ?? 0).doubleValue }.max()
    }

    private var netSpark: [(date: Date, value: Double)] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: Array(monthTx)) { cal.startOfDay(for: $0.date ?? .now) }
        let days = buckets.keys.sorted()
        var running: Double = 0
        return days.map { day in
            let dayNetDec = buckets[day]!.reduce(Decimal.zero) { acc, t in
                let val = t.amount?.decimalValue ?? 0
                return acc + (t.kind == TxKind.income.rawValue ? val : -val)
            }
            let dayNet = (dayNetDec as NSDecimalNumber).doubleValue
            running += dayNet
            return (day, running)
        }
    }

    // MARK: - UI

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Welcome, \(cloudUser.displayName)")
                    .font(.system(size: 28, weight: .bold))

                HStack(alignment: .top, spacing: Theme.spacing) {
                    NetBalanceCard(amount: net, pctChange: pctChangeVsLast, spark: netSpark)
                        .frame(maxWidth: .infinity)

                    UpcomingBillsCard().frame(maxWidth: .infinity)

                    CategoryBreakdownChart(txs: Array(monthTx))
                        .frame(width: 280)
                        .card()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: Theme.spacing) {
                        RecentTable()
                            .frame(maxWidth: .infinity)
                            .card()

                        VStack(spacing: Theme.spacing) {
                            BudgetsMiniCard()
                                .card()
                            SpendBars(txs: Array(monthTx), yMax: spendYMaxFromBudgets)
                                .card()
                        }
                        .frame(width: 320)
                    }
                }

                // ⬇️ Smart suggestions (AI-like helper actions)
                SuggestionsCard(window: window, onAction: navigateSuggestion)
                    .card()
            }
            .padding(20)
        }
        // Delete-all confirmation
        .alert("Delete ALL transactions?",
               isPresented: $confirmDeleteAll) {
            Button("Delete", role: .destructive) {
                deleteAllTransactions()
                // If you only want the current window:
                // monthTx.forEach(moc.delete); try? moc.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all transactions. This cannot be undone.")
        }
        // Toolbar button
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) { confirmDeleteAll = true } label: {
                    Label("Delete All", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Batch delete helper
private extension OverviewView {
    func deleteAllTransactions() {
        let fetch: NSFetchRequest<NSFetchRequestResult> = Transaction.fetchRequest()
        let req = NSBatchDeleteRequest(fetchRequest: fetch)
        req.resultType = .resultTypeObjectIDs
        do {
            if let res = try moc.execute(req) as? NSBatchDeleteResult,
               let ids = res.result as? [NSManagedObjectID] {
                let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: ids]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [moc])
            }
        } catch {
            print("Batch delete failed:", error)
        }
    }
}

// MARK: - Cards (unchanged from your version)

struct NetBalanceCard: View {
    let amount: Decimal
    let pctChange: Double?
    let spark: [(date: Date, value: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Net Balance").foregroundStyle(.secondary)

            Text((amount as NSDecimalNumber).doubleValue.formatted(.currency(code: "USD")))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()

            if !spark.isEmpty {
                let minY = min(0, spark.map(\.value).min() ?? 0)
                let maxY = max(0, spark.map(\.value).max() ?? 0)
                let up   = (spark.last?.value ?? 0) >= 0

                Chart(spark, id: \.date) { p in
                    AreaMark(x: .value("Date", p.date), y: .value("Net", p.value))
                        .foregroundStyle((up ? Color.green : Color.red).opacity(0.18))
                    LineMark(x: .value("Date", p.date), y: .value("Net", p.value))
                        .foregroundStyle(up ? .green : .red)
                    RuleMark(y: .value("Zero", 0))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2]))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: minY...maxY)
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.15)).frame(height: 40)
            }

            HStack {
                if let pct = pctChange {
                    let up = pct >= 0
                    Text("\(up ? "+" : "")\(pct, specifier: "%.1f")% vs last month")
                        .foregroundStyle(up ? .green : .red)
                } else {
                    Text("").hidden()
                }
                Spacer()
                Button("Pay") {}
            }
            .font(.callout)
        }
        .card()
    }
}

struct UpcomingBillsCard: View {
    @Environment(\.managedObjectContext) private var moc
    @FetchRequest private var upcoming: FetchedResults<Subscription>

    init() {
        let today = Calendar.current.startOfDay(for: Date())
        let req: NSFetchRequest<Subscription> = Subscription.fetchRequest()
        req.predicate = NSPredicate(
            format: "nextBillingDate != nil AND nextBillingDate >= %@",
            today as NSDate
        )
        req.sortDescriptors = [
            NSSortDescriptor(keyPath: \Subscription.nextBillingDate, ascending: true)
        ]
        req.fetchLimit = 3
        _upcoming = FetchRequest(fetchRequest: req, animation: .default)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming Bills").bold()

            if upcoming.isEmpty {
                Text("No upcoming bills")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ForEach(upcoming, id: \.objectID) { s in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name ?? "—").font(.headline)
                            if let d = s.nextBillingDate {
                                Text(d, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        let dec: Decimal = s.amount?.decimalValue ?? .zero
                        Text((dec as NSDecimalNumber).doubleValue.formatted(.currency(code: s.currencyCode ?? "USD")))
                            .monospacedDigit()
                            .font(.headline)
                        Button("Pay") { markPaid(s) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .card()
    }

    private func markPaid(_ s: Subscription) {
        guard let due = s.nextBillingDate else { return }
        let cycle = BillingCycle(rawValue: s.billingCycle) ?? .monthly
        let cal = Calendar.current
        let next = (cycle == .monthly)
            ? cal.date(byAdding: .month, value: 1, to: due)
            : cal.date(byAdding: .year,  value: 1, to: due)
        s.nextBillingDate = next
        try? moc.save()
    }
}

struct BudgetsMiniCard: View {
    @Environment(\.managedObjectContext) private var moc
    @FetchRequest private var budgets: FetchedResults<Budget>
    @FetchRequest private var monthTx: FetchedResults<Transaction>

    init() {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let end   = cal.date(byAdding: .month, value: 1, to: start)!

        let bReq: NSFetchRequest<Budget> = Budget.fetchRequest()
        bReq.predicate = NSPredicate(format: "periodStart == %@", start as NSDate)
        bReq.sortDescriptors = [
            NSSortDescriptor(key: "category.name", ascending: true),
            NSSortDescriptor(key: "uuid", ascending: true)
        ]
        _budgets = FetchRequest(fetchRequest: bReq, animation: .default)

        let tReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        tReq.predicate = NSPredicate(format: "date >= %@ AND date < %@", start as NSDate, end as NSDate)
        tReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        _monthTx = FetchRequest(fetchRequest: tReq, animation: .default)
    }

    private var spentByCategory: [NSManagedObjectID: Decimal] {
        var dict: [NSManagedObjectID: Decimal] = [:]
        for t in monthTx where t.kind == TxKind.expense.rawValue {
            guard let cat = t.category else { continue }
            dict[cat.objectID, default: 0] += (t.amount?.decimalValue ?? 0)
        }
        return dict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Budgets").bold()

            if budgets.isEmpty {
                Text("No budgets this month").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                HStack(spacing: 24) {
                    ForEach(Array(budgets.prefix(2))) { b in
                        let total = b.amount?.decimalValue ?? 0
                        let spent = spentByCategory[b.category?.objectID ?? NSManagedObjectID()] ?? 0
                        let t = (total as NSDecimalNumber).doubleValue
                        let s = (spent as NSDecimalNumber).doubleValue
                        let pct = t > 0 ? min(s / t, 1.0) : 0

                        VStack(spacing: 8) {
                            BudgetRing(percent: pct)
                                .frame(width: 96, height: 96)
                            Text(b.category?.name ?? "—")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if budgets.count == 1 { Spacer() }
                }
            }
        }
    }
}

struct BudgetRing: View {
    let percent: Double
    var caption: String = "used"
    private let w: CGFloat = 12

    var body: some View {
        let pct = max(0, min(1, percent))
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: w)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(Int(pct * 100))%").font(.headline).bold()
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(2)
        .animation(.easeInOut(duration: 0.45), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Budget used")
        .accessibilityValue("\(Int(pct * 100)) percent")
    }
}

struct SpendBars: View {
    let txs: [Transaction]
    var currencyCode: String = "USD"
    var yMax: Double? = nil

    private var dayTotals: [(date: Date, total: Double)] {
        let cal = Calendar.current
        let expenses = txs.filter { $0.kind == TxKind.expense.rawValue }
        let groups = Dictionary(grouping: expenses) { cal.startOfDay(for: $0.date ?? .now) }
        return groups.map { (day, items) in
            let sum = items.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
            return (day, (sum as NSDecimalNumber).doubleValue)
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spending by Day").bold()

            Chart(dayTotals, id: \.date) { bin in
                BarMark(x: .value("Date", bin.date),
                        y: .value("Amount", bin.total))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { value in
                    AxisGridLine(); AxisTick()
                    if let d = value.as(Date.self) {
                        AxisValueLabel {
                            Text(d, format: .dateTime.weekday(.narrow))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartYScale(domain: {
                if let cap = yMax, cap > 0 { return 0...cap }
                let auto = (dayTotals.map { $0.total }.max() ?? 100)
                return 0...(auto * 1.15)
            }())
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine(); AxisTick()
                    if let v = value.as(Double.self) {
                        AxisValueLabel { Text(v, format: .currency(code: currencyCode)) }
                    }
                }
            }
            .chartXAxisLabel("Date", alignment: .center)
            .chartYAxisLabel("Amount (\(currencyCode))")
            .frame(height: 180)
        }
    }
}

struct RecentTable: View {
    @Environment(\.managedObjectContext) private var moc

    @FetchRequest private var recent: FetchedResults<Transaction>
    @State private var selection: Set<NSManagedObjectID> = []

    init() {
        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        req.fetchLimit = 6
        _recent = FetchRequest(fetchRequest: req, animation: .default)
    }

    private var recentTotal: Decimal {
        recent.reduce(0) { $0 + ($1.amount?.decimalValue ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").bold()

            Table(of: Transaction.self) {
                TableColumn("Date")     { t in Text(t.date ?? .now, style: .date) }
                TableColumn("Category") { t in Text(t.category?.name ?? "—") }
                TableColumn("Account")  { _ in Text("Visa") }
                TableColumn("Status")   { _ in Text("Paid").foregroundStyle(.green) }
                TableColumn("Amount")   { t in
                    let dec: Decimal = t.amount?.decimalValue ?? .zero
                    Text((dec as NSDecimalNumber).doubleValue.formatted(.currency(code: t.currencyCode ?? "USD")))
                        .monospacedDigit()
                }
                TableColumn("") { t in
                    Button { deleteSingle(t) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                }
                .width(32)
            } rows: {
                ForEach(recent, id: \.objectID) { t in
                    TableRow(t)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteSingle(t)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .onDeleteCommand { deleteSelection() }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Text("Total (recent \(recent.count))").foregroundStyle(.secondary)
                Text((recentTotal as NSDecimalNumber).doubleValue.formatted(.currency(code: "USD")))
                    .bold()
                    .monospacedDigit()
            }
            .font(.footnote)
        }
    }

    private func deleteSingle(_ t: Transaction) {
        moc.delete(t)
        try? moc.save()
        selection.remove(t.objectID)
    }

    private func deleteSelection() {
        let toDelete = recent.filter { selection.contains($0.objectID) }
        guard !toDelete.isEmpty else { return }
        toDelete.forEach(moc.delete)
        try? moc.save()
        selection.removeAll()
    }
}

struct CategoryBreakdownChart: View {
    let txs: [Transaction]

    private var categoryTotals: [(name: String, total: Double)] {
        let expenses = txs.filter { $0.kind == TxKind.expense.rawValue }
        let buckets = Dictionary(grouping: expenses) { (t: Transaction) in
            (t.category?.name?.isEmpty == false ? t.category!.name! : "—")
        }
        return buckets.map { (name, items) in
            let sumDec = items.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
            return (name, (sumDec as NSDecimalNumber).doubleValue)
        }
        .sorted { $0.total > $1.total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Category").bold()

            Chart(categoryTotals, id: \.name) { row in
                SectorMark(angle: .value("Amount", row.total))
                    .foregroundStyle(by: .value("Category", row.name))
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
            .padding(.horizontal, 8)
            .frame(height: 220)
        }
    }
}

struct IncomeExpenseTrend: View {
    let txs: [Transaction]

    private var byDay: [(date: Date, expense: Double, income: Double)] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: txs) { cal.startOfDay(for: $0.date ?? .now) }
        return buckets.map { (day, items) in
            let exp = items.filter { $0.kind == TxKind.expense.rawValue }
                .reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
            let inc = items.filter { $0.kind == TxKind.income.rawValue }
                .reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
            return (day, (exp as NSDecimalNumber).doubleValue, (inc as NSDecimalNumber).doubleValue)
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Income vs Expense").bold()
            Chart(byDay, id: \.date) { row in
                BarMark(x: .value("Date", row.date), y: .value("Expense", row.expense))
                LineMark(x: .value("Date", row.date), y: .value("Income", row.income))
            }
            .frame(height: 200)
        }
    }
}

// Date helpers
extension Date {
    var startOfMonth: Date { Calendar.current.date(from: Calendar.current.dateComponents([.year,.month], from: self))! }
    var endOfMonth: Date { Calendar.current.date(byAdding: .month, value: 1, to: startOfMonth)! }
}


