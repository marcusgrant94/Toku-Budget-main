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
    @EnvironmentObject private var premium: PremiumStore
    @StateObject private var tour = CoachTour(storageKey: "tour.bills")

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
    @State private var showPaywall = false
    @State private var showUpcomingOnly = true
    @State private var soonWindowDays: Int = 30

    // MARK: - Free/Premium limit

    private let freeLimit = 10
    private var billCount: Int { subs.count }                          // all bills (with a nextBillingDate)
    private var atLimit: Bool { !premium.isPremium && billCount >= freeLimit }
    private var remaining: Int { max(0, freeLimit - billCount) }

    // MARK: - Filtering for the list

    private var filtered: [Subscription] {
        guard showUpcomingOnly else { return Array(subs) }
        let limit = Calendar.current.date(byAdding: .day, value: soonWindowDays, to: Date())!
        return subs.filter { ($0.nextBillingDate ?? .distantPast) <= limit }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                header

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
                    .coachAnchor(.billsList)
                }
            }
            .padding(16)

            if atLimit {
                LimitBanner(
                    title: "Free limit reached",
                    message: "You’ve added \(billCount) bills. Upgrade to Premium for unlimited.",
                    actionTitle: "Upgrade"
                ) { showPaywall = true }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .coachOverlay(tour)
        .onAppear {
            tour.startOnce([
                CoachStep(
                    key: .billsNew,
                    title: "Add your first bill",
                    body: "Tap **New Bill** to track subscriptions or recurring payments."
                ),
                CoachStep(
                    key: .billsList,
                    title: "Stay ahead of due dates",
                    body: "Bills are sorted by next date. Use **Mark Paid** to roll to next cycle."
                )
            ])
        }
        .sheet(isPresented: $showNew) {
            NewSubscriptionSheetCoreData(categories: Array(cats)) { name, amount, currency, billing, start, next, cat in
                guard premium.isPremium || billCount < freeLimit else {
                    showPaywall = true
                    return
                }
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
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallView() }
                .frame(minWidth: 540, minHeight: 680)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Bills").font(.title2).bold()
            Spacer()
            Toggle("Upcoming only", isOn: $showUpcomingOnly)
                .toggleStyle(.switch)
            Stepper("Next \(soonWindowDays) days",
                    value: $soonWindowDays, in: 7...120, step: 7)
                .labelsHidden()

            if !premium.isPremium {
                Text("\(min(billCount, freeLimit))/\(freeLimit)")
                    .foregroundStyle(remaining == 0 ? .red : .secondary)
                    .monospacedDigit()
                    .help("Free plan limit")
            }

            Button { handleNewTapped() } label: {
                Label("New Bill", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(atLimit)
            .coachAnchor(.billsNew)
        }
    }

    private func handleNewTapped() {
        if premium.isPremium || billCount < freeLimit {
            showNew = true
        } else {
            showPaywall = true
        }
    }

    // MARK: - Advance the bill's nextBillingDate by its cycle

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

        // Keep reminders, but widgets are disabled for now
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

// Small reusable upgrade banner (same style as used elsewhere)
private struct LimitBanner: View {
    let title: String
    let message: String
    let actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "lock.fill").imageScale(.medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        )
    }
}



