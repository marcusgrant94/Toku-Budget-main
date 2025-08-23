//
//  BudgetsView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

import SwiftUI
import CoreData
import Charts

// MARK: - BudgetsView

struct BudgetView: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.colorScheme) private var scheme

    @FetchRequest private var budgets: FetchedResults<Budget>
    @FetchRequest private var monthTx: FetchedResults<Transaction>

    @State private var showNew = false
    @State private var selection = Set<NSManagedObjectID>()
    @State private var confirmDelete = false

    init() {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let end   = cal.date(byAdding: .month, value: 1, to: start)!

        let bReq: NSFetchRequest<Budget> = Budget.fetchRequest()
        bReq.predicate = NSPredicate(format: "periodStart == %@", start as NSDate)
        bReq.sortDescriptors = [
            NSSortDescriptor(key: "periodStart", ascending: true),
            NSSortDescriptor(key: "uuid",        ascending: true) // tie-breaker
        ]
        // DEBUG: prove what keys are being used at runtime
        print("Budget sort keys:", bReq.sortDescriptors?.compactMap { $0.key } ?? [])

        _budgets = FetchRequest(fetchRequest: bReq, animation: .default)

        let tReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        tReq.predicate = NSPredicate(format: "date >= %@ AND date < %@", start as NSDate, end as NSDate)
        tReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        _monthTx = FetchRequest(fetchRequest: tReq, animation: .default)
    }



    private var spentByCategory: [NSManagedObjectID: Decimal] {
        var dict: [NSManagedObjectID: Decimal] = [:]
        for t in monthTx where t.kind == TxKind.expense.rawValue {
            if let cat = t.category {
                dict[cat.objectID, default: 0] += (t.amount?.decimalValue ?? 0)
            }
        }
        return dict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Budgets").font(.title2).bold()
                Spacer()
                Button { showNew = true } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }

            if budgets.isEmpty {
                VStack(spacing: 8) {
                    Text("No budgets for this month").foregroundStyle(.secondary)
                    Button("Create a Budget") { showNew = true }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .card()
            } else {
                List(selection: $selection) {
                    ForEach(budgets) { b in
                        let spent = b.category.flatMap { spentByCategory[$0.objectID] } ?? 0
                        BudgetRow(budget: b, spent: spent)
                            .contextMenu {
                                Button(role: .destructive) {
                                    selection = [b.objectID]
                                    confirmDelete = true
                                } label: {
                                    Label("Delete Budget", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { idx in
                        idx.map { budgets[$0] }.forEach { moc.delete($0) }
                        try? moc.save()
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
                .alert("Delete \(selection.count) budget\(selection.count == 1 ? "" : "s")?",
                       isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) {
                        for id in selection {
                            if let b = try? moc.existingObject(with: id) as? Budget {
                                moc.delete(b)
                            }
                        }
                        try? moc.save()
                        selection.removeAll()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This won’t delete any transactions or categories.")
                }
            }
        }
        .padding(16)
        .sheet(isPresented: $showNew) { NewBudgetSheet() }
    }
}

// MARK: - Row

struct BudgetRow: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.colorScheme) private var scheme

    let budget: Budget
    let spent: Decimal

    private var total: Decimal { budget.amount?.decimalValue ?? 0 }
    private var remaining: Decimal { max(total - spent, 0) }
    private var progress: Double {
        let t = (total as NSDecimalNumber).doubleValue
        let s = (spent as NSDecimalNumber).doubleValue
        return t > 0 ? min(s / t, 1.0) : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.cardBorder(scheme))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(categoryInitials(budget.category?.name))
                        .font(.subheadline).bold()
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(budget.category?.name ?? "—").font(.headline)
                    Spacer()
                    Text(format(total, code: budget.currencyCode ?? "USD"))
                        .font(.headline).monospacedDigit()
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text("Spent \(format(spent, code: budget.currencyCode ?? "USD"))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Left \(format(remaining, code: budget.currencyCode ?? "USD"))")
                        .foregroundStyle(
                            remaining > 0
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.red)
                        )
                }.font(.caption)
            }
        }
        .padding(.vertical, 6)
    }

    private func categoryInitials(_ name: String?) -> String {
        let parts = (name ?? "").split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let second = parts.dropFirst().first?.prefix(1) ?? ""
        return (first + second).uppercased()
    }
}

// MARK: - New Budget Sheet

struct NewBudgetSheet: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Category.name, ascending: true)],
        animation: .default
    ) private var cats: FetchedResults<Category>

    @State private var amount: Decimal = 0
    @State private var currency = "USD"
    @State private var monthStart: Date = {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    }()
    @State private var category: Category?

    private var isValid: Bool { amount > 0 && category != nil }

    var body: some View {
        Form {
            Picker("Category", selection: $category) {
                Text("—").tag(Optional<Category>.none)
                ForEach(uniqueCategories(Array(cats)), id: \.objectID) { c in
                    Text(c.name ?? "—").tag(Optional(c))
                }
            }
            TextField("Amount", value: $amount, format: .number)
            TextField("Currency", text: $currency)
            DatePicker("Month", selection: $monthStart, displayedComponents: .date)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    let b = Budget(context: moc)
                    b.uuid = UUID()
                    b.amount = NSDecimalNumber(decimal: amount)
                    b.currencyCode = currency
                    b.periodStart = Calendar.current.date(
                        from: Calendar.current.dateComponents([.year, .month], from: monthStart)
                    )
                    b.category = category
                    try? moc.save()
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .frame(width: 420, height: 320)
    }
}

// MARK: - Small helpers

private func format(_ dec: Decimal, code: String) -> String {
    (dec as NSDecimalNumber).doubleValue.formatted(.currency(code: code))
}

private func normalizedCategoryKey(_ name: String?) -> String {
    (name ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
}

/// Return categories with unique names, keeping the first encountered per name.
func uniqueCategories(_ list: [Category]) -> [Category] {
    var seen = Set<String>()
    var out: [Category] = []
    for c in list {
        let key = normalizedCategoryKey(c.name)
        if !seen.contains(key) {
            seen.insert(key)
            out.append(c)
        }
    }
    // Safe sort by display name
    return out.sorted { ($0.name ?? "") < ($1.name ?? "") }
}

