//
//  BillsView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/19/25.
//

import SwiftUI
import CoreData

struct BillsView: View {
    @Environment(\.managedObjectContext) private var moc

    // Show upcoming first
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Subscription.nextBillingDate, ascending: true)],
        predicate: NSPredicate(format: "nextBillingDate != nil"),
        animation: .default
    ) private var subs: FetchedResults<Subscription>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Category.name, ascending: true)],
        animation: .default
    ) private var cats: FetchedResults<Category>

    @State private var showNew = false
    @State private var showUpcomingOnly = true
    @State private var soonWindowDays: Int = 30

    private var filtered: [Subscription] {
        guard showUpcomingOnly else { return Array(subs) }
        let limit = Calendar.current.date(byAdding: .day, value: soonWindowDays, to: Date())!
        return subs.filter { ($0.nextBillingDate ?? .distantPast) <= limit }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bills").font(.title2).bold()
                Spacer()
                Toggle("Upcoming only", isOn: $showUpcomingOnly)
                    .toggleStyle(.switch)
                Stepper("Next \(soonWindowDays) days",
                        value: $soonWindowDays, in: 7...120, step: 7)
                    .labelsHidden()
                Button { showNew = true } label: {
                    Label("New Bill", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if filtered.isEmpty {
                ContentUnavailableView("No upcoming bills",
                                       systemImage: "calendar.badge.clock",
                                       description: Text("Add a bill to see it here."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List {
                    ForEach(filtered, id: \.objectID) { s in
                        BillRow(s: s, onPay: { markPaid(s) })
                            .contextMenu {
                                Button("Mark as Paid") { markPaid(s) }
                                Divider()
                                Button(role: .destructive) {
                                    moc.delete(s); try? moc.save()
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    .onDelete { idx in
                        idx.map { filtered[$0] }.forEach(moc.delete)
                        try? moc.save()
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .sheet(isPresented: $showNew) {
            // Reuse your existing sheet
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
            }
        }
    }

    // Advance the bill's nextBillingDate by its cycle
    @AppStorage(BillReminderDefaults.enabledKey)  private var remindersEnabled = true
    @AppStorage(BillReminderDefaults.leadDaysKey) private var leadDays = BillReminderDefaults.defaultLead

    private func markPaid(_ s: Subscription) {
        guard let due = s.nextBillingDate else { return }
        let cycle = BillingCycle(rawValue: s.billingCycle) ?? .monthly
        let cal = Calendar.current

        let next = (cycle == .monthly)
            ? cal.date(byAdding: .month, value: 1, to: due)
            : cal.date(byAdding: .year,  value: 1, to: due)

        s.nextBillingDate = next
        try? moc.save()

        if remindersEnabled { BillReminder.shared.schedule(for: s, leadDays: leadDays) }
    }

}

private struct BillRow: View {
    let s: Subscription
    var onPay: () -> Void

    private var statusColor: Color {
        guard let d = s.nextBillingDate else { return .secondary }
        let today = Calendar.current.startOfDay(for: Date())
        let due   = Calendar.current.startOfDay(for: d)
        if due < today { return .red }
        if let days = Calendar.current.dateComponents([.day], from: today, to: due).day,
           days <= 7 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor.opacity(0.2)).frame(width: 28, height: 28)
                .overlay(Circle().stroke(statusColor, lineWidth: 2))

            VStack(alignment: .leading, spacing: 2) {
                Text(s.name ?? "—").font(.headline)
                if let d = s.nextBillingDate {
                    Text("Due \(d.formatted(.dateTime.month(.abbreviated).day()))")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Spacer()

            let dec: Decimal = s.amount?.decimalValue ?? .zero
            Text((dec as NSDecimalNumber).doubleValue.formatted(.currency(code: s.currencyCode ?? "USD")))
                .monospacedDigit()
                .font(.headline)

            Button("Mark Paid", action: onPay)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}
