//
//  Untitled.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import SwiftUI
import CoreData
import Charts

struct TrendsView: View {
    let window: DateWindow
    @Environment(\.managedObjectContext) private var moc
    @EnvironmentObject private var premium: PremiumStore   // ⬅️ paywall state

    // Pull transactions only for the selected window
    @FetchRequest private var txs: FetchedResults<Transaction>

    @State private var showMovingAverage = true
    @State private var annotateTopSpikes = true

    init(window: DateWindow) {
        self.window = window
        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.predicate = NSPredicate(format: "date >= %@ AND date < %@",
                                    window.start as NSDate, window.end as NSDate)
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        _txs = FetchRequest(fetchRequest: req, animation: .default)
    }

    // MARK: - Model

    struct DayPoint: Identifiable {
        let id = UUID()
        let date: Date
        let total: Double
    }

    private var expenses: [Transaction] { txs.filter { $0.kind == TxKind.expense.rawValue } }
    private var currencyCode: String { expenses.first?.currencyCode ?? "USD" }

    private var dayTotals: [DayPoint] {
        guard !expenses.isEmpty else { return [] }
        let cal = Calendar.current
        let groups = Dictionary(grouping: expenses) { cal.startOfDay(for: $0.date ?? .now) }
        return groups.map { (day, items) in
            let sum = items.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
            return DayPoint(date: day, total: (sum as NSDecimalNumber).doubleValue)
        }
        .sorted { $0.date < $1.date }
    }

    private var movingAvg7: [DayPoint] {
        guard !dayTotals.isEmpty else { return [] }
        let values = dayTotals.map { $0.total }
        let ma = movingAverage(values, period: 7)
        return zip(dayTotals.map(\.date), ma).map { DayPoint(date: $0.0, total: $0.1) }
    }

    private var topSpikeDates: Set<Date> {
        guard annotateTopSpikes, !dayTotals.isEmpty else { return [] }
        let top3 = dayTotals.sorted(by: { $0.total > $1.total }).prefix(3)
        return Set(top3.map(\.date))
    }

    private var totalSpent: Double {
        (expenses.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) } as NSDecimalNumber).doubleValue
    }

    // --- Metrics/insights below the chart

    private var avgPerActiveDay: Double {
        guard !dayTotals.isEmpty else { return 0 }
        return totalSpent / Double(dayTotals.count)
    }

    private var peakDay: DayPoint? { dayTotals.max(by: { $0.total < $1.total }) }
    private var peakDayTotal: Double { peakDay?.total ?? 0 }
    private var peakDayDate: Date? { peakDay?.date }

    struct WeekBin: Identifiable { let id = UUID(); let start: Date; let total: Double }
    private var weeklyTotals: [WeekBin] {
        let cal = Calendar(identifier: .iso8601)
        let groups = Dictionary(grouping: dayTotals) { (p: DayPoint) in
            cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: p.date))!
        }
        return groups.map { (start, pts) in
            WeekBin(start: start, total: pts.map(\.total).reduce(0, +))
        }
        .sorted { $0.start < $1.start }
    }

    struct WeekdayBin: Identifiable { let id = UUID(); let weekday: Int; let total: Double; let count: Int }
    private var weekdayAgg: [WeekdayBin] {
        let cal = Calendar.current
        var map: [Int:(sum: Double, count: Int)] = [:]
        for p in dayTotals {
            let wd = (cal.component(.weekday, from: p.date) + 5) % 7 + 1 // 1 = Mon … 7 = Sun
            var e = map[wd] ?? (0,0); e.sum += p.total; e.count += 1; map[wd] = e
        }
        return (1...7).map { wd in
            let e = map[wd] ?? (0,0)
            return WeekdayBin(weekday: wd, total: e.sum, count: e.count)
        }
    }
    private func weekdayLabel(_ wd: Int) -> String {
        ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"][max(1, min(7, wd)) - 1]
    }

    private func topPurchases(limit: Int) -> [Transaction] {
        expenses.sorted {
            ($0.amount?.decimalValue ?? 0) > ($1.amount?.decimalValue ?? 0)
        }.prefix(limit).map { $0 }
    }

    // MARK: - UI

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if dayTotals.isEmpty {
                    ContentUnavailableView(
                        "No expenses in this range",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Add some transactions to see trends.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    // Free chart
                    TrendChart(dayTotals: dayTotals,
                               movingAvg: showMovingAverage ? movingAvg7 : [],
                               spikeDates: topSpikeDates,
                               currencyCode: currencyCode,
                               window: window)
                        .frame(height: 300)
                        .card()

                    // Free quick metrics
                    MetricsRow(
                        total: totalSpent,
                        avgPerActiveDay: avgPerActiveDay,
                        peak: peakDayTotal,
                        peakDate: peakDayDate,
                        currency: currencyCode,
                        activeDays: dayTotals.count
                    )
                    .card()

                    // 🔒 Weekly totals + By weekday (each locked)
                    HStack(alignment: .top, spacing: 16) {
                        PremiumLockedCard(
                            title: "Upgrade to Premium",
                            subtitle: "Track weekly spending trends over time"
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Weekly totals").bold()
                                WeeklyTotalsChart(bins: weeklyTotals, currencyCode: currencyCode)
                                    .frame(height: 220)
                            }
                            .card()
                        }
                        .frame(maxWidth: .infinity)

                        PremiumLockedCard(
                            title: "Upgrade to Premium",
                            subtitle: "See which weekdays you spend the most"
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("By weekday").bold()
                                WeekdayBreakdownChart(bins: weekdayAgg, currencyCode: currencyCode)
                                    .frame(height: 220)
                            }
                            .card()
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // 🔒 Top purchases list
                    PremiumLockedCard(
                        title: "Upgrade to Premium",
                        subtitle: "Discover your top purchases automatically"
                    ) {
                        TopSpendsList(items: topPurchases(limit: 5), currencyCode: currencyCode)
                            .card()
                    }
                }
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Trends").font(.title2).bold()
            Spacer()
            Toggle("7-day average", isOn: $showMovingAverage)
                .toggleStyle(.switch)
            Toggle("Annotate spikes", isOn: $annotateTopSpikes)
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Chart View (with hover/drag tooltip)

private struct TrendChart: View {
    let dayTotals: [TrendsView.DayPoint]
    let movingAvg: [TrendsView.DayPoint]
    let spikeDates: Set<Date>
    let currencyCode: String
    let window: DateWindow

    @State private var hoverDate: Date? = nil   // current hover/drag date

    private func nearestPoint(to date: Date) -> TrendsView.DayPoint? {
        guard !dayTotals.isEmpty else { return nil }
        return dayTotals.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
    private var selected: TrendsView.DayPoint? {
        guard let d = hoverDate else { return nil }
        return nearestPoint(to: d)
    }

    var body: some View {
        Chart {
            // Daily spending
            ForEach(dayTotals) { p in
                LineMark(x: .value("Date", p.date),
                         y: .value("Spent", p.total))
                    .interpolationMethod(.monotone)

                AreaMark(x: .value("Date", p.date),
                         y: .value("Spent", p.total))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.blue.opacity(0.10))
            }

            // 7-day moving average
            ForEach(movingAvg) { p in
                LineMark(x: .value("Date", p.date),
                         y: .value("Avg", p.total))
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .foregroundStyle(.green)
            }

            // Spike annotations
            ForEach(dayTotals.filter { spikeDates.contains($0.date) }) { p in
                PointMark(x: .value("Date", p.date),
                          y: .value("Spent", p.total))
                    .symbolSize(60)
                    .foregroundStyle(.red)
                    .annotation(position: .top) {
                        Text(p.total, format: .currency(code: currencyCode))
                            .font(.caption2).bold()
                            .padding(.vertical, 2).padding(.horizontal, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
            }

            // Hover/drag selection
            if let sel = selected {
                RuleMark(x: .value("Selected", sel.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    .foregroundStyle(.secondary)

                PointMark(x: .value("Selected", sel.date),
                          y: .value("Spent", sel.total))
                    .symbolSize(70)
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .top) {
                        Text(sel.total, format: .currency(code: currencyCode))
                            .font(.caption2).bold()
                            .padding(.vertical, 2).padding(.horizontal, 6)
                            .background(.thinMaterial, in: Capsule())
                    }

            }
        }
        // Keep domain stable to the selected window
        .chartXScale(domain: window.start ... window.end)

        // Adaptive, cleaner x-axis
        .chartXAxis {
            let cal = Calendar.current
            let months = cal.dateComponents([.month], from: window.start, to: window.end).month ?? 0

            if months >= 10 {
                AxisMarks(values: .stride(by: .month)) { v in
                    AxisGridLine(); AxisTick()
                    if let d = v.as(Date.self) {
                        AxisValueLabel {
                            Text(d, format: .dateTime.month(.abbreviated)).font(.caption2)
                        }
                    }
                }
            } else if months >= 3 {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { v in
                    AxisGridLine(); AxisTick()
                    if let d = v.as(Date.self) {
                        AxisValueLabel {
                            Text(d, format: .dateTime.month(.abbreviated).day()).font(.caption2)
                        }
                    }
                }
            } else {
                AxisMarks(values: .stride(by: .day, count: 2)) { v in
                    AxisGridLine(); AxisTick()
                    if let d = v.as(Date.self) {
                        AxisValueLabel { Text(d, format: .dateTime.day()).font(.caption2) }
                    }
                }
            }
        }

        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine(); AxisTick()
                if let num = v.as(Double.self) {
                    AxisValueLabel { Text(num, format: .currency(code: currencyCode)) }
                }
            }
        }

        // Pointer/drag tracking for hover tooltips
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = geo[proxy.plotAreaFrame]
                Rectangle().fill(.clear).contentShape(Rectangle())

                    // iOS / iPadOS: drag/tap-hold
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let xInPlot = value.location.x - plotFrame.origin.x
                                if let date: Date = proxy.value(atX: xInPlot, as: Date.self) {
                                    hoverDate = date
                                }
                            }
                            .onEnded { _ in hoverDate = nil }
                    )

                    // macOS: true hover tracking
                    #if os(macOS)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let xInPlot = point.x - plotFrame.origin.x
                            if let date: Date = proxy.value(atX: xInPlot, as: Date.self) {
                                hoverDate = date
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
                    #endif
            }
        }
    }
}

// MARK: - Metrics & Secondary Views

private struct MetricsRow: View {
    let total: Double
    let avgPerActiveDay: Double
    let peak: Double
    let peakDate: Date?
    let currency: String
    let activeDays: Int

    var body: some View {
        HStack(spacing: 16) {
            MetricCard(title: "Total spent",
                       value: total.formatted(.currency(code: currency)))
            MetricCard(title: "Avg / active day",
                       value: avgPerActiveDay.formatted(.currency(code: currency)))
            MetricCard(title: "Peak day",
                       value: peak.formatted(.currency(code: currency)),
                       footnote: peakDate.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "—")
            MetricCard(title: "Active days", value: "\(activeDays)")
        }
    }
}

private struct MetricCard: View {
    @Environment(\.displayScale) private var scale
    let title: String
    let value: String
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
            if let f = footnote {
                Text(f).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.15), lineWidth: 1 / max(scale, 1))
        )
    }
}

private struct WeeklyTotalsChart: View {
    let bins: [TrendsView.WeekBin]
    let currencyCode: String

    @State private var hoverDate: Date? = nil

    private func nearest(to date: Date) -> TrendsView.WeekBin? {
        guard !bins.isEmpty else { return nil }
        return bins.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }
    private var selected: TrendsView.WeekBin? {
        guard let d = hoverDate else { return nil }
        return nearest(to: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(bins) { b in
                    BarMark(x: .value("Week", b.start),
                            y: .value("Total", b.total))
                }

                // 4-week moving average
                let maVals = movingAverage(bins.map(\.total), period: 4)
                ForEach(Array(zip(bins.map(\.start), maVals)), id: \.0) { (d, v) in
                    LineMark(x: .value("Week", d), y: .value("Avg", v))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.green)
                }

                if let s = selected {
                    RuleMark(x: .value("Selected", s.start))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(.secondary)

                    PointMark(x: .value("Selected", s.start),
                              y: .value("Total", s.total))
                        .symbolSize(70)
                        .foregroundStyle(Color.accentColor)
                        .annotation(position: .top) {
                            Text(s.total, format: .currency(code: currencyCode))
                                .font(.caption2).bold()
                                .padding(.vertical, 2).padding(.horizontal, 6)
                                .background(.thinMaterial, in: Capsule())
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: max(1, bins.count / 6))) { v in
                    AxisGridLine(); AxisTick()
                    if let d = v.as(Date.self) {
                        AxisValueLabel { Text(d, format: .dateTime.month(.abbreviated).day()) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine(); AxisTick()
                    if let n = v.as(Double.self) {
                        AxisValueLabel { Text(n, format: .currency(code: currencyCode)) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plot = geo[proxy.plotAreaFrame]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let x = value.location.x - plot.origin.x
                                    if let date: Date = proxy.value(atX: x, as: Date.self) {
                                        hoverDate = date
                                    }
                                }
                                .onEnded { _ in hoverDate = nil }
                        )
                        #if os(macOS)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt):
                                let x = pt.x - plot.origin.x
                                if let date: Date = proxy.value(atX: x, as: Date.self) {
                                    hoverDate = date
                                }
                            case .ended:
                                hoverDate = nil
                            }
                        }
                        #endif
                }
            }
        }
    }
}

private struct WeekdayBreakdownChart: View {
    let bins: [TrendsView.WeekdayBin]
    let currencyCode: String

    @State private var hoverCategory: String? = nil

    private func label(_ wd: Int) -> String {
        ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"][max(1, min(7, wd)) - 1]
    }
    private func bin(for label: String) -> TrendsView.WeekdayBin? {
        bins.first { self.label($0.weekday) == label }
    }
    private var selected: TrendsView.WeekdayBin? {
        guard let key = hoverCategory else { return nil }
        return bin(for: key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(bins) { b in
                    BarMark(x: .value("Weekday", label(b.weekday)),
                            y: .value("Total", b.total))
                }

                if let s = selected {
                    RuleMark(x: .value("Selected", label(s.weekday)))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(.secondary)

                    PointMark(x: .value("Selected", label(s.weekday)),
                              y: .value("Total", s.total))
                        .symbolSize(70)
                        .foregroundStyle(Color.accentColor)
                        .annotation(position: .top) {
                            Text(s.total, format: .currency(code: currencyCode))
                                .font(.caption2).bold()
                                .padding(.vertical, 2).padding(.horizontal, 6)
                                .background(.thinMaterial, in: Capsule())
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine(); AxisTick()
                    if let n = v.as(Double.self) {
                        AxisValueLabel { Text(n, format: .currency(code: currencyCode)) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plot = geo[proxy.plotAreaFrame]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let x = value.location.x - plot.origin.x
                                    if let cat: String = proxy.value(atX: x, as: String.self) {
                                        hoverCategory = cat
                                    }
                                }
                                .onEnded { _ in hoverCategory = nil }
                        )
                        #if os(macOS)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt):
                                let x = pt.x - plot.origin.x
                                if let cat: String = proxy.value(atX: x, as: String.self) {
                                    hoverCategory = cat
                                }
                            case .ended:
                                hoverCategory = nil
                            }
                        }
                        #endif
                }
            }
        }
    }
}

private struct TopSpendsList: View {
    let items: [Transaction]
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top purchases").bold()
            if items.isEmpty {
                Text("No data").foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.objectID) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.category?.name ?? "—").font(.subheadline)
                            Text(t.date ?? .now, style: .date)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let d: Decimal = t.amount?.decimalValue ?? 0
                        Text((d as NSDecimalNumber).doubleValue.formatted(.currency(code: currencyCode)))
                            .bold()
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.25)
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Math

private func movingAverage(_ values: [Double], period: Int) -> [Double] {
    guard period > 1, !values.isEmpty else { return values }
    var out = Array(repeating: 0.0, count: values.count)
    var sum = 0.0
    for i in 0..<values.count {
        sum += values[i]
        if i >= period { sum -= values[i - period] }
        let count = min(i + 1, period)
        out[i] = sum / Double(count)
    }
    return out
}



