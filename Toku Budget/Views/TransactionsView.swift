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

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Transaction.date, ascending: false)],
        animation: .default
    ) private var txns: FetchedResults<Transaction>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Category.name, ascending: true)],
        animation: .default
    ) private var cats: FetchedResults<Category>

    @State private var selection: Set<NSManagedObjectID> = []
    @State private var showNew = false
    @State private var confirmDeleteAll = false

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

            Button { showNew = true } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .padding()
        }
        .sheet(isPresented: $showNew) {
            NewTransactionSheetCoreData(categories: Array(cats)) { amt, kind, date, note, cat in
                let t = Transaction(context: moc)
                t.uuid = UUID()
                t.date = date
                t.amount = NSDecimalNumber(decimal: amt)
                t.kind = (kind == .expense) ? 0 : 1
                t.note = note.isEmpty ? nil : note
                t.currencyCode = "USD"
                t.category = cat
                try? moc.save()
            }
        }
        .alert("Delete ALL transactions?",
               isPresented: $confirmDeleteAll) {
            Button("Delete", role: .destructive) {
                deleteAllTransactions()
                // If you prefer to delete only currently fetched ones:
                // txns.forEach(moc.delete); try? moc.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all transactions. This cannot be undone.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                Button { showNew = true } label: { Label("New", systemImage: "plus") }
            }
        }
        .padding(12)
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



