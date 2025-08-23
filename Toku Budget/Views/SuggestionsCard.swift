//
//  SuggestionsCard.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import SwiftUI
import CoreData


struct SuggestionsCard: View {
    @Environment(\.managedObjectContext) private var moc
    let window: DateWindow
    /// Parent can wire navigation here (Budgets/Subscriptions/Trends).
    var onAction: (SuggestionAction) -> Void = { _ in }

    @State private var suggestions: [MoneySuggestion] = []
    @State private var expanded = true

    // For "Set Budget" flow
    @State private var presentNewBudget = false
    @State private var preselectCategory: Category?
    @State private var currencyGuess = "USD"
    @State private var amountGuess: Decimal = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tips", systemImage: "lightbulb.max.fill")
                    .font(.headline)
                Spacer()
                Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                    .buttonStyle(.plain)
            }

            if expanded {
                if suggestions.isEmpty {
                    Text("No suggestions right now")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestions) { s in
                        SuggestionRow(
                            suggestion: s,
                            onPrimary: { handlePrimaryAction(for: s) },
                            onSecondary: { action in onAction(action) }
                        )
                        Divider().opacity(0.25)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
        .task {
            let engine = SuggestionEngine()
            suggestions = engine.generate(in: moc, window: window)
            // try to guess currency (used in Set Budget sheet default)
            if let anyTxn = try? moc.fetch(Transaction.fetchRequest()).first as? Transaction {
                currencyGuess = anyTxn.currencyCode ?? "USD"
            }
        }
        .sheet(isPresented: $presentNewBudget) {
            NewBudgetSheetPrefilled(
                category: preselectCategory,
                defaultAmount: amountGuess,
                currency: currencyGuess,
                monthAnchor: window.start
            )
        }
    }

    // MARK: - Actions

    private func isSetBudget(_ a: SuggestionAction) -> Bool {
        if case .setBudget = a { return true }
        return false
    }

    private func handlePrimaryAction(for s: MoneySuggestion) {
        // Prefer Set Budget if present; otherwise bounce to the first action
        if let set = s.actions.first(where: isSetBudget) {
            if case .setBudget(let categoryID) = set,
               let cat = try? moc.existingObject(with: categoryID) as? Category {
                preselectCategory = cat
                // small helper: use 10% less than current category spend as a hint
                amountGuess = estimateSuggestedBudget(for: cat)
                presentNewBudget = true
            }
        } else if let first = s.actions.first {
            onAction(first)
        }
    }

    private func estimateSuggestedBudget(for category: Category) -> Decimal {
        // approximate: this month’s spend in that category (if available)
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: window.start))!
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart)!

        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.predicate = NSPredicate(format: "date >= %@ AND date < %@ AND category == %@ AND kind == %d",
                                    monthStart as NSDate, monthEnd as NSDate, category, TxKind.expense.rawValue)
        let tx = (try? moc.fetch(req)) ?? []
        let sum = tx.reduce(Decimal.zero) { $0 + ($1.amount?.decimalValue ?? 0) }
        // suggest a slightly lower target (e.g., 90% of current spend)
        return (sum as NSDecimalNumber).multiplying(by: 0.90).decimalValue
    }
}

private struct SuggestionRow: View {
    let suggestion: MoneySuggestion
    var onPrimary: () -> Void
    var onSecondary: (SuggestionAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(suggestion.title).font(.subheadline).bold()
                Spacer()
                Text("\(Int(suggestion.confidence * 100))%")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
            Text(suggestion.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(primaryLabel(suggestion)) { onPrimary() }
                    .buttonStyle(.borderedProminent)

                ForEach(secondaryActions(suggestion), id: \.self) { act in
                    Button(secondaryLabel(act)) { onSecondary(act) }
                        .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func primaryLabel(_ s: MoneySuggestion) -> String {
        if s.actions.contains(where: { if case .setBudget = $0 { return true } else { return false } }) {
            return "Set Budget…"
        }
        return "Review"
    }

    private func secondaryActions(_ s: MoneySuggestion) -> [SuggestionAction] {
        // Show any non-primary actions
        s.actions.filter {
            if case .setBudget = $0 { return false } // handled by primary
            return true
        }
    }

    private func secondaryLabel(_ a: SuggestionAction) -> String {
        switch a {
        case .openBudgets:       return "Open Budgets"
        case .openSubscriptions: return "Review Subs"
        case .openTrends:        return "Open Trends"
        case .setBudget:         return "Set Budget…"
        }
    }
}

// Wrapper that pre-fills your existing NewBudgetSheet
private struct NewBudgetSheetPrefilled: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.dismiss) private var dismiss

    let category: Category?
    let defaultAmount: Decimal
    let currency: String
    let monthAnchor: Date

    // Mirror NewBudgetSheet’s state
    @State private var amount: Decimal = 0
    @State private var currencyText: String = "USD"
    @State private var monthStart: Date = Date()
    @State private var selectedCategory: Category?

    private var isValid: Bool { amount > 0 && selectedCategory != nil }

    var body: some View {
        Form {
            Picker("Category", selection: $selectedCategory) {
                if let c = selectedCategory {
                    Text(c.name ?? "—").tag(Optional(c))
                } else {
                    Text("—").tag(Optional<Category>.none)
                }
            }
            .disabled(true)

            TextField("Amount", value: $amount, format: .number)
            TextField("Currency", text: $currencyText)
            DatePicker("Month", selection: $monthStart, displayedComponents: .date)
        }
        .onAppear {
            amount = defaultAmount > 0 ? defaultAmount : 0
            currencyText = currency
            let cal = Calendar.current
            monthStart = cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor))!
            selectedCategory = category
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    let b = Budget(context: moc)
                    b.uuid = UUID()
                    b.amount = NSDecimalNumber(decimal: amount)
                    b.currencyCode = currencyText
                    b.periodStart = Calendar.current.date(
                        from: Calendar.current.dateComponents([.year, .month], from: monthStart)
                    )
                    b.category = selectedCategory
                    try? moc.save()
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .frame(width: 420, height: 320)
    }
}

