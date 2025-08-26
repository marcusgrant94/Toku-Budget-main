//
//  TransactionsView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/16/25.
//

import SwiftUI
import CoreData

struct TransactionsView: View {
    @Environment(\.managedObjectContext) private var moc
    @EnvironmentObject private var premium: PremiumStore
    @StateObject private var tour = CoachTour(storageKey: "tour.transactions")

    // Window-scoped list shown in the table (set in init(window:))
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Transaction.date, ascending: false)],
        animation: .default
    ) private var txns: FetchedResults<Transaction>

    // A second fetch that always counts *all* transactions (no predicate)
    @FetchRequest(sortDescriptors: [], animation: .default)
    private var allTxns: FetchedResults<Transaction>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Category.name, ascending: true)],
        animation: .default
    ) private var cats: FetchedResults<Category>

    @State private var selection: Set<NSManagedObjectID> = []
    @State private var showNew = false
    @State private var showPaywall = false
    @State private var confirmDeleteAll = false

    private let freeLimit = 30
    private var totalCount: Int { allTxns.count }
    private var atLimit: Bool { !premium.isPremium && totalCount >= freeLimit }
    private var remaining: Int { max(0, freeLimit - totalCount) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Table(of: Transaction.self) {
                TableColumn("Date") { t in
                    Text(t.date ?? .now, style: .date)
                }
                TableColumn("Category") { t in
                    Text(t.category?.name ?? "—")
                }
                TableColumn("Type") { t in
                    let kind = TxKind(rawValue: t.kind) ?? .expense
                    Text(kind == .expense ? "Expense" : "Income")
                }
                TableColumn("Amount") { t in
                    let dec: Decimal = t.amount?.decimalValue ?? .zero
                    Text((dec as NSDecimalNumber).doubleValue.formatted(.currency(code: t.currencyCode ?? "USD")))
                        .monospacedDigit()
                }
                TableColumn("Note") { t in
                    Text(t.note ?? "")
                }
            } rows: {
                ForEach(txns, id: \.objectID) { t in
                    TableRow(t)
                        .contextMenu {
                            Button(role: .destructive) {
                                moc.delete(t)
                                try? moc.save()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }

            // Floating Add button (coach target)
            Button(action: handleAddTapped) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .disabled(atLimit)
            .coachAnchor(.transactionsAdd)   // 👈 onboarding anchor

            // 🔒 Limit banner when free limit reached
            if atLimit {
                LimitBanner(
                    title: "Free limit reached",
                    message: "You’ve saved \(totalCount) transactions. Upgrade to Premium for unlimited.",
                    actionTitle: "Upgrade"
                ) { showPaywall = true }
                .padding(.bottom, 64) // sit above the Add button
                .padding(.horizontal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .coachOverlay(tour)   // 👈 show onboarding overlay
        .onAppear {
            // Show once: where to add or import
            tour.startOnce([
                CoachStep(
                    key: .transactionsAdd,
                    title: "Add or Import",
                    body: "Click **Add** to create a transaction.\nTo bulk import, use **File → Import CSV**."
                )
            ])
        }
        .sheet(isPresented: $showNew) {
            NewTransactionSheetCoreData(categories: Array(cats)) { amt, kind, date, note, cat in
                addTransaction(amount: amt, kind: kind, date: date, note: note, category: cat)
            }
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallView() }
                .frame(minWidth: 540, minHeight: 680)
        }
        .alert("Delete ALL transactions?",
               isPresented: $confirmDeleteAll) {
            Button("Delete", role: .destructive) { deleteAllTransactions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all transactions. This cannot be undone.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if !premium.isPremium {
                    Text("\(min(totalCount, freeLimit))/\(freeLimit)")
                        .foregroundStyle(remaining == 0 ? .red : .secondary)
                        .monospacedDigit()
                        .help("Free plan limit")
                }

                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                }

                Button(action: handleAddTapped) {
                    Label("New", systemImage: "plus")
                }
                .disabled(atLimit)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func handleAddTapped() {
        if premium.isPremium || totalCount < freeLimit {
            showNew = true
        } else {
            showPaywall = true
        }
    }

    private func addTransaction(amount: Decimal,
                                kind: TxKind,
                                date: Date,
                                note: String,
                                category: Category?) {
        // Double-check the limit on save
        guard premium.isPremium || totalCount < freeLimit else {
            showPaywall = true
            return
        }
        let t = Transaction(context: moc)
        t.uuid = UUID()
        t.date = date
        t.amount = NSDecimalNumber(decimal: amount)
        t.kind = (kind == .expense) ? 0 : 1
        t.note = note.isEmpty ? nil : note
        t.currencyCode = "USD"
        t.category = category
        try? moc.save()
    }
}

// Window-scoped initializer stays the same
extension TransactionsView {
    init(window: DateWindow) {
        let txReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        txReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        txReq.predicate = NSPredicate(format: "date >= %@ AND date < %@",
                                      window.start as NSDate, window.end as NSDate)
        _txns = FetchRequest(fetchRequest: txReq, animation: .default)

        let cReq: NSFetchRequest<Category> = Category.fetchRequest()
        cReq.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        _cats = FetchRequest(fetchRequest: cReq, animation: .default)

        // _allTxns remains with its default (no predicate) to count every transaction.
    }
}

// MARK: - Batch delete helper
private extension TransactionsView {
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

// MARK: - Limit banner

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
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        )
    }
}

// MARK: - Add Sheet (Core Data)

struct NewTransactionSheetCoreData: View {
    let categories: [Category]
    var onSave: (Decimal, TxKind, Date, String, Category?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Decimal = 0
    @State private var kind: TxKind = .expense
    @State private var date = Date()
    @State private var note = ""
    @State private var category: Category?

    private var isValid: Bool { amount > 0 }

    var body: some View {
        Form {
            Picker("Type", selection: $kind) {
                Text("Expense").tag(TxKind.expense)
                Text("Income").tag(TxKind.income)
            }
            TextField("Amount", value: $amount, format: .number)
            DatePicker("Date", selection: $date, displayedComponents: .date)
            Picker("Category", selection: $category) {
                Text("—").tag(Optional<Category>.none)
                ForEach(uniqueCategories(categories), id: \.objectID) { c in
                    Text(c.name ?? "—").tag(Optional(c))
                }
            }
            TextField("Note", text: $note)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    onSave(amount, kind, date, note, category)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .frame(width: 420, height: 340)
    }
}

// MARK: - Helpers

extension Decimal {
    func currency(code: String) -> String {
        (self as NSDecimalNumber).doubleValue.formatted(.currency(code: code))
    }
}





