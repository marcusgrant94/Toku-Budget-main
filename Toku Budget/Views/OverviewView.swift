//
//  OverviewView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/16/25.
//

import SwiftUI
import CoreData
import Charts
import os.log

struct OverviewView: View {
    let window: DateWindow
    let mode: DateRangeMode

    @Environment(\.managedObjectContext) private var moc
    @EnvironmentObject private var premium: PremiumStore
    @StateObject private var cloudUser = CloudUser()

    // Sheet
    @State private var selectedTx: Transaction?

    // 🔵 Onboarding coach for Overview
    @StateObject private var tour = CoachTour(storageKey: "tour.overview")

    @FetchRequest private var monthTx: FetchedResults<Transaction>
    @FetchRequest private var prevMonthTx: FetchedResults<Transaction>
    @FetchRequest private var budgets: FetchedResults<Budget>

    @State private var confirmDeleteAll = false

    init(window: DateWindow, mode: DateRangeMode) {
        self.window = window
        self.mode = mode

        let currReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        currReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        currReq.predicate = NSPredicate(format: "date >= %@ AND date < %@",
                                        window.start as NSDate, window.end as NSDate)
        _monthTx = FetchRequest(fetchRequest: currReq, animation: .default)

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

                // Top cards row
                HStack(alignment: .top, spacing: Theme.spacing) {
                    NetBalanceCard(amount: net, pctChange: pctChangeVsLast, spark: netSpark)
                        .frame(maxWidth: .infinity)

                    UpcomingBillsCard()
                        .frame(maxWidth: .infinity)
                        .coachAnchor(.overviewBills)

                    CategoryBreakdownChart(txs: Array(monthTx))
                        .frame(width: 280)
                        .card()
                }

                // Middle row: Recent + side column (Budgets + SpendBars)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: Theme.spacing) {
                        RecentTable { tx in
                            selectedTx = tx
                        }
                        .frame(maxWidth: .infinity)
                        .card()
                        .coachAnchor(.overviewRecent)

                        VStack(spacing: Theme.spacing) {
                            BudgetsMiniCard()
                                .card()
                                .coachAnchor(.overviewBudgets)

                            SpendBars(txs: Array(monthTx), yMax: spendYMaxFromBudgets)
                                .card()
                                .coachAnchor(.overviewSpendBars)
                        }
                        .frame(width: 320)
                    }
                }

                // AI tips (paywalled)
                PremiumLockedCard(title: "Upgrade to Premium",
                                  subtitle: "AI Powered Personal financial tips") {
                    AITipsCard(window: window, viewID: "overview")
                        .card()
                        .coachAnchor(.overviewTips)
                }
            }
            .padding(20)
        }
        .alert("Delete ALL transactions?",
               isPresented: $confirmDeleteAll) {
            Button("Delete", role: .destructive) {
                deleteAllTransactions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all transactions. This cannot be undone.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Replay the tour
                Button {
                    tour.show(overviewSteps)
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Show quick tips")

                Button(role: .destructive) { confirmDeleteAll = true } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .coachAnchor(.overviewDeleteAll)
            }
        }
        // Attach the overlay
        .coachOverlay(tour)
        // First-time tour
        .onAppear {
            tour.startOnce(overviewSteps)
        }
        // 🔹 Present detail sheet when a row is chosen
        .sheet(item: $selectedTx) { tx in
            TransactionDetailSheet(tx: tx)
                .frame(minWidth: 520, minHeight: 420)
        }
    }

    // MARK: - Coach steps for Overview

    private var overviewSteps: [CoachStep] {
        [
            .init(
                key: .overviewRecent,
                title: "Your recent activity",
                body: "Double-click any row to edit. Import transactions from the Transactions screen."
            ),
            .init(
                key: .overviewBudgets,
                title: "Budgets at a glance",
                body: "Set monthly limits in Budgets to keep categories on track."
            ),
            .init(
                key: .overviewSpendBars,
                title: "Daily spending",
                body: "See which days spike. Explore deeper trends in Trends/Stats."
            ),
            .init(
                key: .overviewBills,
                title: "Upcoming bills",
                body: "Track due dates and amounts. Mark bills paid to roll them forward."
            ),
            .init(
                key: .overviewTips,
                title: "AI Coach",
                body: "Personalized tips based on your activity. Subscribe to Premium to unlock."
            ),
            .init(
                key: .overviewDeleteAll,
                title: "Delete All",
                body: "Deletes all transactions. Use with care."
            )
        ]
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

// MARK: - Cards (unchanged below)

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
            }
            .font(.callout)
        }
        .card()
    }
}



struct UpcomingBillsCard: View {
    @Environment(\.managedObjectContext) private var moc

    // Fetch everything that has a nextBillingDate; sort earliest first.
    @FetchRequest private var withDates: FetchedResults<Subscription>

    private let log = Logger(subsystem: "TokuBudget", category: "UpcomingBillsCard")

    init() {
        let req: NSFetchRequest<Subscription> = Subscription.fetchRequest()
        req.predicate = NSPredicate(format: "nextBillingDate != nil")
        req.sortDescriptors = [NSSortDescriptor(keyPath: \Subscription.nextBillingDate, ascending: true)]
        _withDates = FetchRequest(fetchRequest: req, animation: .default)
    }

    // Only show items due today or later, then cap to 3
    private var upcoming: [Subscription] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return withDates
            .filter { ($0.nextBillingDate ?? .distantPast) >= startOfToday }
            .prefix(3)
            .map { $0 }
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
                        Circle().fill(statusColor(for: s).opacity(0.2)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(statusColor(for: s), lineWidth: 2))

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

                        Button("Mark Paid") { markPaid(s) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .card()
        .onAppear {
            #if DEBUG
            log.debug("withDates=\(self.withDates.count) filtered upcoming=\(self.upcoming.count)")
            self.withDates.forEach { sub in
                if let d = sub.nextBillingDate {
                    log.debug("• \(sub.name ?? "—") due \(d.formatted())")
                }
            }
            #endif
        }
        // (No widget syncing here anymore)
    }

    private func statusColor(for s: Subscription) -> Color {
        guard let d = s.nextBillingDate else { return .secondary }
        let today = Calendar.current.startOfDay(for: Date())
        let due   = Calendar.current.startOfDay(for: d)
        if due < today { return .red }
        if let days = Calendar.current.dateComponents([.day], from: today, to: due).day, days <= 7 { return .orange }
        return .green
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

        #if canImport(UIKit) || canImport(AppKit)
        if UserDefaults.standard.bool(forKey: BillReminderDefaults.enabledKey) {
            let lead = UserDefaults.standard.integer(forKey: BillReminderDefaults.leadDaysKey)
            BillReminder.shared.schedule(for: s, leadDays: lead)
        }
        #endif
        // (No widget syncing here anymore)
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
    /// Optional external cap (e.g. from budgets). We'll still pad it a bit.
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

    /// Make a “nice” rounded axis max (1/2/5 × 10^n) with 5–10% headroom
    private func niceAxisMax(for value: Double) -> Double {
        guard value > 0 else { return 100 }
        let padded = value * 1.08
        let exp  = floor(log10(padded))
        let base = pow(10, exp)
        let frac = padded / base
        let nice: Double = (frac <= 1) ? 1 : (frac <= 2) ? 2 : (frac <= 5) ? 5 : 10
        return nice * base
    }

    private var yUpperBound: Double {
        let dataMax = dayTotals.map(\.total).max() ?? 0
        let proposed = max(dataMax, yMax ?? 0)
        return niceAxisMax(for: proposed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spending by Day").bold()

            Chart(dayTotals, id: \.date) { bin in
                BarMark(
                    x: .value("Date", bin.date),
                    y: .value("Amount", bin.total)
                )
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { value in
                    AxisGridLine(); AxisTick()
                    if let d = value.as(Date.self) {
                        AxisValueLabel {
                            Text(d, format: .dateTime.weekday(.narrow)).font(.caption2)
                        }
                    }
                }
            }
            // ⬇️ Keep bars below the top grid line
            .chartYScale(domain: 0...yUpperBound)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine(); AxisTick()
                    if let v = value.as(Double.self) {
                        AxisValueLabel { Text(v, format: .currency(code: currencyCode)) }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.padding(.top, 6)
            }
            .chartXAxisLabel("Date", alignment: .center)
            .chartYAxisLabel("Amount (\(currencyCode))")
            .frame(height: 180)
        }
    }
}

typealias Tx = Transaction

struct RecentTable: View {
    @Environment(\.managedObjectContext) private var moc
    @AppStorage("settings.sheets.sortKey") private var sortKey: SheetsSortKey = .dateDesc
    @FetchRequest private var recentRaw: FetchedResults<Transaction>

    // Selection drives the highlight; Transaction.ID is the class identifier in your build
    @State private var selection = Set<Transaction.ID>()

    var onOpen: (Transaction) -> Void = { _ in }

    init(onOpen: @escaping (Transaction) -> Void = { _ in }) {
        self.onOpen = onOpen
        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        _recentRaw = FetchRequest(fetchRequest: req, animation: .default)
    }

    private var recentSorted: [Transaction] {
        var arr = Array(recentRaw)
        switch sortKey {
        case .dateDesc:   arr.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .dateAsc:    arr.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        case .amountDesc: arr.sort { ($0.amount?.doubleValue ?? 0) > ($1.amount?.doubleValue ?? 0) }
        case .amountAsc:  arr.sort { ($0.amount?.doubleValue ?? 0) < ($1.amount?.doubleValue ?? 0) }
        }
        return arr
    }

    private var recentTotal: Decimal {
        recentSorted.reduce(0) { $0 + ($1.amount?.decimalValue ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent").bold()
                Spacer()
                Text(activeSortLabel).font(.caption).foregroundStyle(.secondary)
            }

            // ✅ selection binding gives the row highlight; single click opens the sheet
            Table(recentSorted, selection: $selection) {
                TableColumn("Date") { (t: Transaction) in
                    Text(t.date ?? .now, style: .date)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = [t.id]; onOpen(t) }
                }
                TableColumn("Category") { (t: Transaction) in
                    Text(t.category?.name ?? "—")
                        .contentShape(Rectangle())
                        .onTapGesture { selection = [t.id]; onOpen(t) }
                }
//                TableColumn("Account") { (t: Transaction) in
//                    Text("Visa")
//                        .contentShape(Rectangle())
//                        .onTapGesture { selection = [t.id]; onOpen(t) }
//                }
//                TableColumn("Status")  { (t: Transaction) in
//                    Text("Paid").foregroundStyle(.green)
//                        .contentShape(Rectangle())
//                        .onTapGesture { selection = [t.id]; onOpen(t) }
//                }
                TableColumn("Amount")  { (t: Transaction) in
                    let dec: Decimal = t.amount?.decimalValue ?? .zero
                    Text((dec as NSDecimalNumber).doubleValue.formatted(.currency(code: t.currencyCode ?? "USD")))
                        .monospacedDigit()
                        .contentShape(Rectangle())
                        .onTapGesture { selection = [t.id]; onOpen(t) }
                }
                TableColumn(" ") { (t: Transaction) in
                    Button { deleteSingle(t) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                }
                .width(36)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Text("Total (recent \(recentSorted.count))").foregroundStyle(.secondary)
                Text((recentTotal as NSDecimalNumber).doubleValue.formatted(.currency(code: "USD")))
                    .bold().monospacedDigit()
            }
            .font(.footnote)
        }
    }

    private var activeSortLabel: String {
        switch sortKey {
        case .dateDesc:   return "Sorted: Date ↓"
        case .dateAsc:    return "Sorted: Date ↑"
        case .amountDesc: return "Sorted: Amount ↓"
        case .amountAsc:  return "Sorted: Amount ↑"
        }
    }

    private func deleteSingle(_ t: Transaction) {
        moc.delete(t)
        try? moc.save()
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




