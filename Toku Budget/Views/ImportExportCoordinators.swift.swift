//
//  ImportExportCoordinators.swift.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

import SwiftUI
import CoreData
import AppKit
import UniformTypeIdentifiers

// Opens a window hosting CSVImportView
enum ImportCoordinator {
    // keep a strong ref so the window doesn't deallocate
    private static var importWindow: NSWindow?

    static func presentImporter(_ moc: NSManagedObjectContext) {
        let view = CSVImportView()                             // <- use the importer view you added earlier
            .environment(\.managedObjectContext, moc)

        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Import CSV"
        win.setContentSize(NSSize(width: 900, height: 620))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        importWindow = win
    }
}

// Simple CSV export (date-ascending)
enum ExportCoordinator {
    static func presentExporter(_ moc: NSManagedObjectContext) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "TokuBudget-\(Date.now.formatted(.dateTime.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportCSV(to: url, moc: moc)
    }

    private static func exportCSV(to url: URL, moc: NSManagedObjectContext) {
        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        let txs = (try? moc.fetch(req)) ?? []

        var rows: [[String]] = []
        rows.append(["Date","Amount","Type","Currency","Category","Note"])
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        for t in txs {
            let amt = (t.amount ?? 0).doubleValue
            let type = (t.kind == 0) ? "Expense" : "Income"
            rows.append([
                df.string(from: t.date ?? .now),
                String(format: "%.2f", amt),
                type,
                t.currencyCode ?? "USD",
                t.category?.name ?? "",
                t.note ?? ""
            ])
        }

        let csv = CSVWriter.makeCSV(rows)
        try? csv.data(using: .utf8)?.write(to: url)
    }
}

// Minimal CSV writer (escapes quotes/commas/newlines)
enum CSVWriter {
    static func makeCSV(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n")
    }
    private static func escape(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}
