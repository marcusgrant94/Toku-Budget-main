//
//  Untitled.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import Foundation
import CoreData

// MARK: - Models used by the UI

enum SuggestionKind: String {
    case overspendVsBudget
    case trendingUp
    case duplicateSubs
    case cancelHighCostSub
    case savingsGoalPlan
    case predictiveHighMonths
    case overspendProjection
}

enum SuggestionAction: Hashable {
    case openBudgets
    case openSubscriptions
    case openTrends
    case setBudget(categoryID: NSManagedObjectID)
}

struct MoneySuggestion: Identifiable {
    let id = UUID()
    let kind: SuggestionKind
    let title: String
    let detail: String
    let confidence: Double   // 0.0 ... 1.0
    let actions: [SuggestionAction]
}

// MARK: - Engine

final class SuggestionEngine {

    func generate(in moc: NSManagedObjectContext, window: DateWindow) -> [MoneySuggestion] {
        let curr = fetchTransactions(moc: moc, start: window.start, end: window.end)
        let prevWin = previousWindow(from: window)
        let prev = fetchTransactions(moc: moc, start: prevWin.start, end: prevWin.end)
        let budgets = fetchBudgets(moc: moc, monthOf: window.start)
        let subs = fetchSubscriptions(moc: moc)

        var out: [MoneySuggestion] = []

        // Core rules
        out += overspendSuggestions(currTx: curr, budgets: budgets)
        out += trendingUpSuggestions(currTx: curr, prevTx: prev, thresholdPct: 0.20)
        out += duplicateSubsSuggestions(subs: subs)

        // Extra rules
        out += ruleCancelHighCostSubscription(in: moc)
        out += ruleSavingsGoal(in: moc, window: window)          // ← uses YOUR SavingsGoalStore
        out += rulePredictiveHighMonths(in: moc, window: window)
        out += ruleOverspendProjection(in: moc, window: window)

        out.sort { $0.confidence > $1.confidence }
        return Array(out.prefix(6))
    }

    // MARK: Fetches

    private func fetchTransactions(moc: NSManagedObjectContext, start: Date, end: Date) -> [Transaction] {
        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.predicate = NSPredicate(format: "date >= %@ AND date < %@", start as NSDate, end as NSDate)
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return (try? moc.fetch(req)) ?? []
    }

    private func fetchBudgets(moc: NSManagedObjectContext, monthOf anchor: Date) -> [Budget] {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: anchor))!
        let req: NSFetchRequest<Budget> = Budget.fetchRequest()
        req.predicate = NSPredicate(format: "periodStart == %@", monthStart as NSDate)
        return (try? moc.fetch(req)) ?? []
    }

    private func fetchSubscriptions(moc: NSManagedObjectContext) -> [Subscription] {
        let req: NSFetchRequest<Subscription> = Subscription.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "nextBillingDate", ascending: true)]
        return (try? moc.fetch(req)) ?? []
    }

    private func previousWindow(from window: DateWindow) -> DateWindow {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: window.start, to: window.end).day ?? 30
        let prevEnd = window.start
        let prevStart = cal.date(byAdding: .day, value: -days, to: prevEnd) ?? prevEnd.addingTimeInterval(-Double(days) * 86_400)
        return DateWindow(start: prevStart, end: prevEnd)
    }

    // MARK: Helpers

    private func spentByCategory(_ tx: [Transaction], kind: TxKind) -> [NSManagedObjectID: Decimal] {
        var dict: [NSManagedObjectID: Decimal] = [:]
        for t in tx where t.kind == kind.rawValue {
            guard let cat = t.category else { continue }
            dict[cat.objectID, default: 0] += (t.amount?.decimalValue ?? 0)
        }
        return dict
    }

    private func currency(from tx: [Transaction]) -> String { tx.first?.currencyCode ?? "USD" }

    private func categoryName(_ cat: Category?) -> String {
        (cat?.name?.isEmpty == false) ? (cat?.name ?? "—") : "—"
    }

    private func fmt(_ dec: Decimal, _ code: String) -> String {
        (dec as NSDecimalNumber).doubleValue.formatted(.currency(code: code))
    }

    // MARK: Rules (core)

    private func overspendSuggestions(currTx: [Transaction], budgets: [Budget]) -> [MoneySuggestion] {
        guard !budgets.isEmpty else { return [] }
        let spent = spentByCategory(currTx, kind: .expense)
        var out: [MoneySuggestion] = []

        for b in budgets {
            guard let cat = b.category else { continue }
            let total = b.amount?.decimalValue ?? 0
            let used  = spent[cat.objectID] ?? 0

            let totalD = (total as NSDecimalNumber).doubleValue
            let usedD  = (used  as NSDecimalNumber).doubleValue
            guard totalD > 0 else { continue }

            if usedD > totalD * 1.10 {
                let code = b.currencyCode ?? currency(from: currTx)
                let over = Decimal(usedD - totalD)
                out.append(.init(
                    kind: .overspendVsBudget,
                    title: "Over budget in \(categoryName(cat))",
                    detail: "You’ve spent \(fmt(used, code)) of a \(fmt(total, code)) budget — \(fmt(over, code)) over.",
                    confidence: 0.95,
                    actions: [.setBudget(categoryID: cat.objectID), .openBudgets]
                ))
            }
        }
        return out
    }

    private func trendingUpSuggestions(currTx: [Transaction], prevTx: [Transaction], thresholdPct: Double) -> [MoneySuggestion] {
        guard !currTx.isEmpty else { return [] }
        let curr = spentByCategory(currTx, kind: .expense)
        let prev = spentByCategory(prevTx, kind: .expense)
        let code = currency(from: currTx)

        var out: [MoneySuggestion] = []
        for (catID, nowDec) in curr {
            let prevDec = prev[catID] ?? 0
            let prevD = (prevDec as NSDecimalNumber).doubleValue
            guard prevD > 0 else { continue }

            let nowD = (nowDec as NSDecimalNumber).doubleValue
            let pct = (nowD - prevD) / prevD

            if pct >= thresholdPct {
                let ctx = currTx.first?.managedObjectContext
                let cat = try? ctx?.existingObject(with: catID) as? Category
                let pctInt = Int((pct * 100).rounded())
                let title = "\(categoryName(cat)) up \(pctInt)% vs last period"
                let detail = "Spent \(fmt(nowDec, code)) vs \(fmt(prevDec, code)) previously. Consider setting a budget or tracking this more closely."

                out.append(.init(
                    kind: .trendingUp,
                    title: title,
                    detail: detail,
                    confidence: min(0.9, 0.6 + pct),
                    actions: [.openTrends, .setBudget(categoryID: catID)]
                ))
            }
        }
        return out
    }

    private func duplicateSubsSuggestions(subs: [Subscription]) -> [MoneySuggestion] {
        guard subs.count > 1 else { return [] }
        let groups = Dictionary(grouping: subs) { (s: Subscription) in
            s.category?.objectID ?? NSManagedObjectID()
        }

        var out: [MoneySuggestion] = []
        for (_, items) in groups {
            guard items.count >= 2 else { continue }
            let total = items.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
            let code = items.first?.currencyCode ?? "USD"
            let names = items.compactMap { $0.name }.joined(separator: ", ")
            let catName = items.first?.category?.name ?? "—"

            out.append(.init(
                kind: .duplicateSubs,
                title: "You have \(items.count) subscriptions in \(catName)",
                detail: "\(names) total \(fmt(total, code)). Consider consolidating or cancelling unused ones.",
                confidence: 0.70,
                actions: [.openSubscriptions]
            ))
        }
        return out
    }

    // MARK: Rules (extra)

    private func ruleCancelHighCostSubscription(in moc: NSManagedObjectContext) -> [MoneySuggestion] {
        let req: NSFetchRequest<Subscription> = Subscription.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(keyPath: \Subscription.amount, ascending: false)]
        req.fetchLimit = 1

        guard let top = try? moc.fetch(req).first else { return [] }
        let amountDec: Decimal = top.amount?.decimalValue ?? 0
        let amount = (amountDec as NSDecimalNumber).doubleValue
        guard amount > 0 else { return [] }

        let cycle = BillingCycle(rawValue: top.billingCycle) ?? .monthly
        let monthly = (cycle == .yearly) ? amount / 12.0 : amount
        let yearly  = monthly * 12.0
        let currency = top.currencyCode ?? "USD"

        let name = top.name ?? "a subscription"
        let title  = "Cancel \(name)?"
        let detail = "You’d save \(yearly.formatted(.currency(code: currency))) per year. Consider pausing/cancelling if you don’t use it."

        return [.init(kind: .cancelHighCostSub,
                      title: title,
                      detail: detail,
                      confidence: 0.75,
                      actions: [.openSubscriptions])]
    }

    /// Uses your SavingsGoalStore to create a monthly/weekly target,
    /// and suggests trimming a discretionary category.
    private func ruleSavingsGoal(in moc: NSManagedObjectContext, window: DateWindow) -> [MoneySuggestion] {
        guard let goal = SavingsGoalStore().read() else { return [] }

        let cal = Calendar.current
        let monthsLeftRaw = cal.dateComponents([.month], from: Date(), to: goal.targetDate).month ?? 0
        let monthsLeft = max(1, monthsLeftRaw)

        let goalAmount = (goal.amount as NSDecimalNumber).doubleValue
        let needMonthly = goalAmount / Double(monthsLeft)
        let needWeekly  = needMonthly / 4.0
        let currency = "USD" // infer if you wish

        // Pick a discretionary category in the current window
        let disc = topDiscretionaryCategory(in: moc, window: window)
        let catName = disc?.name ?? "Entertainment"

        let title  = "To reach your goal: save \(needMonthly.formatted(.currency(code: currency)))/mo"
        let detail = "Try trimming \(catName) by ~\(needWeekly.formatted(.currency(code: currency))) each week. Set a cap to stay on track."

        var acts: [SuggestionAction] = [.openTrends]
        if let disc = disc { acts.insert(.setBudget(categoryID: disc.objectID), at: 0) }
        else { acts.insert(.openBudgets, at: 0) }

        return [.init(kind: .savingsGoalPlan,
                      title: title,
                      detail: detail,
                      confidence: 0.80,
                      actions: acts)]
    }

    private func topDiscretionaryCategory(in moc: NSManagedObjectContext, window: DateWindow) -> Category? {
        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.predicate = NSPredicate(format: "date >= %@ AND date < %@ AND kind == %d",
                                    window.start as NSDate, window.end as NSDate, TxKind.expense.rawValue)

        guard let tx = try? moc.fetch(req), !tx.isEmpty else { return nil }

        let grouped = Dictionary(grouping: tx) { $0.category }
        let fixedKeywords = ["rent", "mortgage", "utility", "utilities", "insurance"]

        let scored: [(Category, Double)] = grouped.compactMap { (cat, items) in
            guard let c = cat else { return nil }
            let name = (c.name ?? "").lowercased()
            if fixedKeywords.contains(where: { name.contains($0) }) { return nil }
            let sumDec = items.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
            let sum = (sumDec as NSDecimalNumber).doubleValue
            return (c, sum)
        }

        return scored.sorted { $0.1 > $1.1 }.first?.0
    }

    private func rulePredictiveHighMonths(in moc: NSManagedObjectContext, window: DateWindow) -> [MoneySuggestion] {
        let lookbackStart = Calendar.current.date(byAdding: .month, value: -24, to: window.end) ?? window.start

        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.predicate = NSPredicate(format: "date >= %@ AND date < %@ AND kind == %d",
                                    lookbackStart as NSDate, window.end as NSDate, TxKind.expense.rawValue)
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

        guard let tx = try? moc.fetch(req), !tx.isEmpty else { return [] }

        let cal = Calendar.current
        var sum = [Int: Double](), count = [Int: Int]()
        for t in tx {
            let month = cal.component(.month, from: t.date ?? .now)
            let v = t.amount?.doubleValue ?? 0
            sum[month, default: 0]   += v
            count[month, default: 0] += 1
        }

        let avg = (1...12).map { m -> (Int, Double) in
            let s = sum[m, default: 0]
            let c = max(1, count[m, default: 1])
            return (m, s / Double(c))
        }.sorted { $0.1 > $1.1 }

        let hot = Set(avg.prefix(3).map { $0.0 })

        let next1Date = cal.date(byAdding: .month, value: 1, to: Date())!
        let next2Date = cal.date(byAdding: .month, value: 2, to: Date())!
        let next1 = cal.component(.month, from: next1Date)
        let next2 = cal.component(.month, from: next2Date)

        guard hot.contains(next1) || hot.contains(next2) else { return [] }

        let df = DateFormatter(); df.dateFormat = "LLLL"
        let label = "\(df.string(from: next1Date)), \(df.string(from: next2Date))"

        let title  = "Heads-up: upcoming expensive months"
        let detail = "Historically, the next months (\(label)) run high. Consider setting temporary caps or pausing non-essentials."

        return [.init(kind: .predictiveHighMonths,
                      title: title,
                      detail: detail,
                      confidence: 0.65,
                      actions: [.openTrends, .openBudgets])]
    }

    private func ruleOverspendProjection(in moc: NSManagedObjectContext, window: DateWindow) -> [MoneySuggestion] {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let end   = cal.date(byAdding: .month, value: 1, to: start)!

        // Month-to-date
        let today = Date()
        let mtdReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        mtdReq.predicate = NSPredicate(format: "date >= %@ AND date < %@ AND kind == %d",
                                       start as NSDate, min(end, today) as NSDate, TxKind.expense.rawValue)
        guard let mtd = try? moc.fetch(mtdReq) else { return [] }
        let mtdSum = (mtd.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) } as NSDecimalNumber).doubleValue

        // Project end-of-month (simple run-rate)
        let totalDays = cal.dateComponents([.day], from: start, to: end).day ?? 30
        let elapsed   = max(1, cal.dateComponents([.day], from: start, to: today).day ?? 1)
        let runRate   = mtdSum / Double(elapsed)
        let projected = runRate * Double(totalDays)

        // Typical = avg last 3 months total spend
        let histStart = cal.date(byAdding: .month, value: -3, to: start)!
        let hReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        hReq.predicate = NSPredicate(format: "date >= %@ AND date < %@ AND kind == %d",
                                     histStart as NSDate, start as NSDate, TxKind.expense.rawValue)
        guard let hist = try? moc.fetch(hReq) else { return [] }
        let histSum = (hist.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) } as NSDecimalNumber).doubleValue
        let typical = histSum / 3.0

        guard projected > typical * 1.10 else { return [] }

        let currency = "USD"
        let title  = "You may overspend this month"
        let detail = "Projected \(projected.formatted(.currency(code: currency))) vs typical \(typical.formatted(.currency(code: currency))). Consider trimming discretionary categories."

        return [.init(kind: .overspendProjection,
                      title: title,
                      detail: detail,
                      confidence: 0.80,
                      actions: [.openTrends, .openBudgets])]
    }
}


