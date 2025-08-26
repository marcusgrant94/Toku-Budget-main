//
//  TransactionDetailSheet.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/24/25.
//

import SwiftUI
import CoreData

struct TransactionDetailSheet: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var tx: Transaction

    // Local edit buffer
    @State private var amount: Decimal = 0
    @State private var kind: TxKind = .expense
    @State private var date: Date = Date()
    @State private var note: String = ""
    @State private var currency: String = "USD"
    @State private var category: Category?

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Category.name, ascending: true)],
        animation: .default
    ) private var cats: FetchedResults<Category>

    init(tx: Transaction) {
        self.tx = tx
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transaction Details").font(.title3).bold()
                Spacer()
                Button(role: .destructive) {
                    moc.delete(tx)
                    try? moc.save()
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            Form {
                Picker("Type", selection: $kind) {
                    Text("Expense").tag(TxKind.expense)
                    Text("Income").tag(TxKind.income)
                }

                TextField("Amount", value: $amount, format: .number)

                DatePicker("Date", selection: $date, displayedComponents: .date)

                Picker("Category", selection: $category) {
                    Text("—").tag(Optional<Category>.none)
                    ForEach(Array(cats), id: \.objectID) { c in
                        Text(c.name ?? "—").tag(Optional(c))
                    }
                }

                TextField("Currency", text: $currency)
                TextField("Note", text: $note, axis: .vertical)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(amount <= 0)
            }
        }
        .padding(16)
        .onAppear { loadFromTx() }
    }

    private func loadFromTx() {
        amount   = tx.amount?.decimalValue ?? 0
        kind     = TxKind(rawValue: tx.kind) ?? .expense
        date     = tx.date ?? Date()
        note     = tx.note ?? ""
        currency = tx.currencyCode ?? "USD"
        category = tx.category
    }

    private func save() {
        tx.amount       = NSDecimalNumber(decimal: amount)
        tx.kind         = kind.rawValue          // Int16
        tx.date         = date
        tx.note         = note.isEmpty ? nil : note
        tx.currencyCode = currency
        tx.category     = category
        try? moc.save()
        dismiss()
    }
}


