//
//  SubscriptionsView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/16/25.
//

import SwiftUI
import CoreData

struct SubscriptionsView: View {
    @Environment(\.managedObjectContext) private var moc
    @AppStorage(BillReminderDefaults.enabledKey)  private var remindersEnabled = true
    @AppStorage(BillReminderDefaults.leadDaysKey) private var leadDays = BillReminderDefaults.defaultLead

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Subscription.nextBillingDate, ascending: true)],
        animation: .default
    ) private var subs: FetchedResults<Subscription>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Category.name, ascending: true)],
        animation: .default
    ) private var cats: FetchedResults<Category>

    // selection for List + delete key
    @State private var selection: Set<NSManagedObjectID> = []
    @State private var showNew = false

    var body: some View {
        List(selection: $selection) {
            ForEach(subs, id: \.objectID) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.name ?? "—").font(.headline)
                        if let d = s.nextBillingDate {
                            Text("Next: \(d, style: .date)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    let dec: Decimal = s.amount?.decimalValue ?? .zero
                    Text((dec as NSDecimalNumber).doubleValue.formatted(.currency(code: s.currencyCode ?? "USD")))
                        .monospacedDigit()
                }
                .contextMenu {
                    Button(role: .destructive) {
                        deleteSubscriptions([s])
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            // swipe to delete (iOS/macCatalyst)
            .onDelete { indexSet in
                let toDelete = indexSet.map { subs[$0] }
                deleteSubscriptions(toDelete)
            }
        }
        // ⌫ key support
        .onDeleteCommand { deleteSelection() }
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItemGroup {
                if !selection.isEmpty {
                    Button(role: .destructive) {
                        let toDelete = subs.filter { selection.contains($0.objectID) }
                        deleteSubscriptions(toDelete)
                        selection.removeAll()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Button { showNew = true } label: { Label("New", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showNew) {
            NewSubscriptionSheetCoreData(categories: Array(cats)) { name, amount, currency, billing, start, next, cat in
                let s = Subscription(context: moc)
                s.uuid = UUID()
                s.name = name
                s.amount = NSDecimalNumber(decimal: amount)
                s.currencyCode = currency
                s.billingCycle = billing.rawValue
                s.startDate = start
                s.nextBillingDate = next
                s.category = cat
                try? moc.save()
                if remindersEnabled { BillReminder.shared.schedule(for: s, leadDays: leadDays) }
            }
        }
    }

    // MARK: - Delete helpers

    private func deleteSelection() {
        let toDelete = subs.filter { selection.contains($0.objectID) }
        guard !toDelete.isEmpty else { return }
        deleteSubscriptions(toDelete)
        selection.removeAll()
    }

    private func deleteSubscriptions(_ items: [Subscription]) {
        guard !items.isEmpty else { return }
        items.forEach { s in
            // cancel any pending notification for this sub (if you implemented cancel)
            BillReminder.shared.cancel(for: s)
            moc.delete(s)
        }
        try? moc.save()
    }
}

// MARK: - Add Sheet (unchanged, except it calls onSave above)

struct NewSubscriptionSheetCoreData: View {
    let categories: [Category]
    var onSave: (String, Decimal, String, BillingCycle, Date, Date, Category?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var amount: Decimal = 0
    @State private var currency = "USD"
    @State private var billing: BillingCycle = .monthly
    @State private var start = Date()
    @State private var next = Date()
    @State private var category: Category?

    private var isValid: Bool { !name.isEmpty && amount > 0 }

    // ✅ Dedup once here so all views that present this sheet get a clean list
    private var uniqueCats: [Category] {
        uniqueCategories(categories)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Amount", value: $amount, format: .number)

            Picker("Billing", selection: $billing) {
                Text("Monthly").tag(BillingCycle.monthly)
                Text("Yearly").tag(BillingCycle.yearly)
            }

            DatePicker("Start", selection: $start, displayedComponents: .date)
            DatePicker("Next Bill", selection: $next, displayedComponents: .date)

            Picker("Category", selection: $category) {
                Text("—").tag(Optional<Category>.none)
                ForEach(uniqueCats, id: \.objectID) { c in
                    Text(c.name ?? "—").tag(Optional(c))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    onSave(name, amount, currency, billing, start, next, category)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .frame(width: 420, height: 360)
    }
}



