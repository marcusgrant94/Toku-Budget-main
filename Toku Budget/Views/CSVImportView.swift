//
//  CSVImportView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

//
//  CSVImportView.swift
//

import SwiftUI
import CoreData
import TabularData
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct CSVImportView: View {
    @AppStorage("importAmountMode") private var amountMode: Int = 1


    enum ImportField: String, Codable, CaseIterable {
        case date, amount, debit, credit, type, note, category, currency
    }

    @Environment(\.managedObjectContext) private var moc

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ImportTemplate.name, ascending: true)],
        animation: .default
    ) private var templates: FetchedResults<ImportTemplate>

    // CSV data
    @State private var table: DataFrame?
    @State private var headers: [String] = []
    @State private var rowsPreview: [[String]] = []
    @State private var detectedSignature = ""

    // Mapping UI
    @State private var selectedTemplate: ImportTemplate?
    @State private var map: [ImportField: String] = [:]
    @State private var dateFormat = "MM/dd/yyyy"
    @State private var delimiter: Character = ","
    @State private var currencyFallback = "USD"

    // UX
    @State private var showImportResult = false
    @State private var importSummary = ""

    var body: some View {
        VStack(spacing: 12) {

            // Pinned top bar
            HStack(spacing: 12) {
                Button("Choose CSV…", action: openCSV)

                if table != nil {
                    Button("Import", action: runImport)
                        .buttonStyle(.borderedProminent)
                        .disabled(!importReady)
                }

                Spacer()

                Picker("Template", selection: $selectedTemplate) {
                    Text("—").tag(Optional<ImportTemplate>.none)
                    ForEach(templates) { t in
                        Text(t.name ?? "—").tag(Optional(t))
                    }
                }
                .onChange(of: selectedTemplate) { applyTemplate($0) }

                Button("Save as Template", action: saveTemplate)
                    .disabled(table == nil)
            }

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    CompactImportRequirements(
                        hasDate: !(map[.date] ?? "").isEmpty,
                        hasAmount: !(map[.amount] ?? "").isEmpty,
                        hasDebit: !(map[.debit] ?? "").isEmpty,
                        hasCredit: !(map[.credit] ?? "").isEmpty,
                        dateFormat: dateFormat,
                        delimiter: delimiter
                    )
                    .card()

                    if table != nil {
                        mappingControls

                        PreviewGrid(headers: headers, rows: rowsPreview)
                            .frame(minHeight: 240)
                            .card()
                    } else {
                        VStack(spacing: 8) {
                            Text("Import CSV").font(.title2).bold()
                            Text("Pick a file to preview and map columns.")
                                .foregroundStyle(.secondary)
                            Button("Choose CSV…", action: openCSV)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .card()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .padding(16)
        .alert("Import complete", isPresented: $showImportResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importSummary)
        }
    }
}

// MARK: - Requirements panel

/// Compact, dynamic requirements box
struct CompactImportRequirements: View {
    let hasDate: Bool
    let hasAmount: Bool
    let hasDebit: Bool
    let hasCredit: Bool
    let dateFormat: String
    let delimiter: Character

    private var needsAmountPair: Bool { !hasAmount && !(hasDebit || hasCredit) }
    private var ready: Bool { hasDate && (!needsAmountPair) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Import setup", systemImage: "info.circle")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                row(done: hasDate,  "Map a **Date** column")
                row(done: !needsAmountPair, "Map **Amount** *or* **Debit/Credit**")
            }

            if ready {
                Label("Ready to import", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Text("Map the missing fields above, then tap **Import**.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Tiny helpful hints (kept short)
            VStack(alignment: .leading, spacing: 4) {
                Text("Optional columns: **Note**, **Category**, **Currency**, **Type**.")
                Text("Date format: `\(dateFormat)` • Delimiter: `\(String(delimiter))`.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(done: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(try! AttributedString(markdown: text))
        }
        .font(.subheadline)
    }
}


// MARK: - Mapping controls

private extension CSVImportView {
    func binding(for f: ImportField) -> Binding<String> {
        Binding(
            get: { map[f] ?? "" },
            set: { map[f] = $0 }
        )
    }

    var mappingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Column Mapping").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(ImportField.allCases, id: \.self) { f in
                    MappingRow(field: f, headers: headers, selection: binding(for: f))
                }

                GridRow {
                    Text("Date Format")
                    TextField("MM/dd/yyyy", text: $dateFormat)
                        .frame(width: 220)
                }

                GridRow {
                    Text("Delimiter")
                    Picker("", selection: $delimiter) {
                        Text(",").tag(Character(","))
                        Text(";").tag(Character(";"))
                        Text("\\t").tag(Character("\t"))
                    }
                    .frame(width: 100)
                }

                GridRow {
                    Text("Amount Mode")
                    Picker("", selection: $amountMode) {
                        Text("Single Amount (exp < 0)").tag(0)
                        Text("Debit/Credit Columns").tag(1)
                    }
                    .frame(width: 260)
                }

                GridRow {
                    Text("Currency Fallback")
                    TextField("USD", text: $currencyFallback)
                        .frame(width: 120)
                }
            }
        }
    }

    struct MappingRow: View {
        let field: CSVImportView.ImportField
        let headers: [String]
        @Binding var selection: String

        var body: some View {
            GridRow {
                Text(field.rawValue.capitalized)
                Picker("", selection: $selection) {
                    Text("—").tag("")
                    ForEach(headers, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 220)
            }
        }
    }
}

// MARK: - Preview table

private struct PreviewGrid: View {
    let headers: [String]
    let rows: [[String]]
    private let colWidth: CGFloat = 140

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(headers, id: \.self) { h in
                        Text(h)
                            .font(.headline)
                            .frame(width: colWidth, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.2))
                    }
                }
                Divider()

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: colWidth, alignment: .leading)
                                .padding(8)
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

// MARK: - File I/O + CSV parsing

private extension CSVImportView {
    func openCSV() {
        #if os(macOS)
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText, .plainText]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        loadCSV(url)
        #endif
    }

    private enum CSVSoftError: Error { case empty }

    private func detectDelimiter(in raw: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        let lines = raw.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { return "," }
        let sample = String(lines[1])
        var best: (c: Character, count: Int) = (",", -1)
        for c in candidates {
            let n = sample.filter { $0 == c }.count
            if n > best.count { best = (c, n) }
        }
        return best.c
    }

    private func parseCSVLoose(_ raw: String, delimiter: Character) throws -> (headers: [String], rows: [[String]]) {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = raw.startIndex

        func pushField() { row.append(field); field.removeAll(keepingCapacity: true) }
        func pushRow() { rows.append(row); row.removeAll(keepingCapacity: true) }

        while i < raw.endIndex {
            let ch = raw[i]
            if ch == "\"" {
                let next = raw.index(after: i)
                if inQuotes, next < raw.endIndex, raw[next] == "\"" {
                    field.append("\""); i = next
                } else {
                    inQuotes.toggle()
                }
            } else if ch == delimiter && !inQuotes {
                pushField()
            } else if (ch == "\n" || ch == "\r") && !inQuotes {
                pushField()
                if !row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    pushRow()
                } else {
                    row.removeAll()
                }
                if ch == "\r" {
                    let next = raw.index(after: i)
                    if next < raw.endIndex, raw[next] == "\n" { i = next }
                }
            } else {
                field.append(ch)
            }
            i = raw.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty { pushField(); pushRow() }

        guard let header = rows.first else { throw CSVSoftError.empty }
        let expected = header.count

        var normalized: [[String]] = []
        for r in rows.dropFirst() {
            if r.count == expected { normalized.append(r); continue }
            if r.count < expected {
                var padded = r
                padded.append(contentsOf: Array(repeating: "", count: expected - r.count))
                normalized.append(padded)
            } else {
                let mergedLast = r[(expected-1)...].joined(separator: String(delimiter))
                normalized.append(Array(r.prefix(expected-1)) + [mergedLast])
            }
        }
        return (header, normalized)
    }

    private func makeDataFrame(headers: [String], rows: [[String]]) -> DataFrame {
        var df = DataFrame()
        for (ci, name) in headers.enumerated() {
            let contents: [String] = rows.map { ci < $0.count ? $0[ci] : "" }
            let col = Column<String>(name: name, contents: contents)
            df.append(column: col)
        }
        return df
    }

    private func loadCSV(_ url: URL) {
        do {
            // Try strict first
            let opts = CSVReadingOptions(hasHeaderRow: true, delimiter: delimiter)
            let df = try DataFrame(contentsOfCSVFile: url, options: opts)

            self.table = df
            self.headers = df.columns.map(\.name)
            self.detectedSignature = headers.sorted().joined(separator: "|")

            let previewRows = Array(df.prefix(20).rows)
            let nameToIndex = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($0.element, $0.offset) })
            self.rowsPreview = previewRows.map { row in
                headers.map { h in
                    guard let idx = nameToIndex[h] else { return "" }
                    let any = row[idx]
                    return any.map { String(describing: $0) } ?? ""
                }
            }

            if let match = templates.first(where: { $0.headerSignature == detectedSignature }) {
                applyTemplate(match); selectedTemplate = match
            } else {
                autoMapHeaders()
            }
        } catch {
            // Lenient fallback
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let autoDelim = detectDelimiter(in: raw)
                let parsed = try parseCSVLoose(raw, delimiter: autoDelim)
                self.delimiter = autoDelim
                self.headers = parsed.headers
                self.detectedSignature = parsed.headers.sorted().joined(separator: "|")
                self.rowsPreview = Array(parsed.rows.prefix(20))
                self.table = makeDataFrame(headers: parsed.headers, rows: parsed.rows)

                if let match = templates.first(where: { $0.headerSignature == detectedSignature }) {
                    applyTemplate(match); selectedTemplate = match
                } else {
                    autoMapHeaders()
                }
            } catch {
                print("CSV (lenient) read failed:", error)
                self.table = nil
            }
        }
    }
}

// MARK: - Templates

private extension CSVImportView {
    func applyTemplate(_ t: ImportTemplate?) {
        guard let t else { return }
        self.dateFormat       = t.dateFormat ?? "MM/dd/yyyy"
        self.delimiter        = Character(t.delimiter ?? ",")
        self.amountMode       = Int(t.amountMode)
        self.currencyFallback = t.currencyFallback ?? "USD"

        if let data = t.columnMap,
           let m = try? JSONDecoder().decode([ImportField:String].self, from: data) {
            self.map = m
        }
    }

    func saveTemplate() {
        guard table != nil else { return }
        let t = ImportTemplate(context: moc)
        t.uuid = UUID()
        t.name = promptName(defaultsTo: suggestedTemplateName())
        t.headerSignature = detectedSignature
        t.dateFormat = dateFormat
        t.delimiter = String(delimiter)
        t.amountMode = Int16(amountMode)
        t.currencyFallback = currencyFallback
        t.columnMap = try? JSONEncoder().encode(map)
        try? moc.save()
    }

    private func autoMapHeaders() {
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        }
        func pick(_ names: [String]) -> String? {
            headers.first { names.contains(norm($0)) }
        }

        var tmp: [ImportField:String] = [:]
        if let v = pick(["date","transactiondate","posteddate"])       { tmp[.date] = v }
        if let v = pick(["amount","amt","transactionamount"])          { tmp[.amount] = v }
        if let v = pick(["debit","withdrawal"])                        { tmp[.debit] = v }
        if let v = pick(["credit","deposit"])                          { tmp[.credit] = v }
        if let v = pick(["description","memo","details","note"])       { tmp[.note] = v }
        if let v = pick(["type","drcr","transactiontype"])             { tmp[.type] = v }
        if let v = pick(["category"])                                  { tmp[.category] = v }
        if let v = pick(["currency","currencycode","cur"])             { tmp[.currency] = v }

        for (k, v) in tmp { map[k] = v }

        if map[.amount] == nil, (map[.debit] != nil || map[.credit] != nil) {
            amountMode = 1
        }
    }

    func suggestedTemplateName() -> String { "My Bank CSV" }
    func promptName(defaultsTo: String) -> String { defaultsTo }
}

// MARK: - Import into Core Data

private extension CSVImportView {

    // Robust amount parser for "Single Amount" mode
    private func parseSingleAmount(_ amountString: String, typeString: String?) -> (amount: Decimal, kind: TxKind)? {
        var s = amountString.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: ",", with: "")
             .replacingOccurrences(of: " ", with: "")
             .replacingOccurrences(of: "$", with: "")
             .replacingOccurrences(of: "€", with: "")
             .replacingOccurrences(of: "£", with: "")

        var isNegative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { isNegative = true; s = String(s.dropFirst().dropLast()) }
        if s.hasSuffix("-") { isNegative = true; s.removeLast() }
        if s.hasPrefix("-") { isNegative = true; s.removeFirst() }

        guard let val = Decimal(string: s) else { return nil }

        if let t = typeString?.lowercased() {
            let expenseHints = ["expense","debit","withdrawal","dr","charge","purchase","payment sent"]
            let incomeHints  = ["income","credit","deposit","cr","refund","payment received"]
            if expenseHints.contains(where: { t.contains($0) }) { isNegative = true }
            if incomeHints.contains(where:  { t.contains($0) }) { isNegative = false }
        }

        return (abs(val), isNegative ? .expense : .income)
    }

    func runImport() {
        guard let df = table else { return }

        var imported = 0
        var skippedBad = 0
        var skippedDup = 0

        // Build header name -> column index
        let nameToIndex: [String:Int] = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })

        func cellString(_ row: DataFrame.Row, colName: String) -> String? {
            guard let idx = nameToIndex[colName] else { return nil }
            if let any = row[idx] { return String(describing: any) }
            return nil
        }

        func get(_ field: ImportField, from row: DataFrame.Row) -> String? {
            guard let col = map[field], !col.isEmpty else { return nil }
            return cellString(row, colName: col)
        }

        let fmt = DateFormatter()
        fmt.locale = .autoupdatingCurrent
        fmt.timeZone = .current
        fmt.dateFormat = dateFormat

        for row in df.rows {
            // Date
            guard let ds = get(.date, from: row),
                  let date = fmt.date(from: ds) else { skippedBad += 1; continue }

            // Amount & kind
            var amountDec: Decimal = 0
            var kind: TxKind = .expense

            if amountMode == 0 {
                guard let aStr = get(.amount, from: row) else { skippedBad += 1; continue }
                let typeStr = get(.type, from: row)
                guard let parsed = parseSingleAmount(aStr, typeString: typeStr) else { skippedBad += 1; continue }
                amountDec = parsed.amount
                kind      = parsed.kind
            } else {
                let debit  = Decimal(string: normalizedNumber(get(.debit, from: row) ?? "")) ?? 0
                let credit = Decimal(string: normalizedNumber(get(.credit, from: row) ?? "")) ?? 0
                if debit != 0 { amountDec = debit; kind = .expense }
                else if credit != 0 { amountDec = credit; kind = .income }
                else { skippedBad += 1; continue }
            }

            // Category (optional)
            var category: Category?
            if let catName = get(.category, from: row)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !catName.isEmpty {
                category = fetchOrCreateCategory(named: catName)
            }

            let currency = (get(.currency, from: row) ?? currencyFallback).uppercased()
            let note = get(.note, from: row)

            // Duplicate guard
            let hash = importHash(date: date, amount: amountDec, kind: kind, currency: currency, note: note ?? "")
            if fetchTransaction(byHash: hash) != nil { skippedDup += 1; continue }

            // Create Transaction
            let t = Transaction(context: moc)
            t.uuid = UUID()
            t.date = date
            t.amount = NSDecimalNumber(decimal: amountDec)
            t.kind = (kind == .expense ? 0 : 1)
            t.currencyCode = currency
            t.note = note
            t.category = category
            t.importHash = hash

            imported += 1
        }

        try? moc.save()

        importSummary = "Imported \(imported) • Skipped \(skippedBad) invalid • Skipped \(skippedDup) duplicates"
        showImportResult = true
    }

    func normalizedNumber(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
    }

    func fetchOrCreateCategory(named name: String) -> Category {
        let req: NSFetchRequest<Category> = Category.fetchRequest()
        req.predicate = NSPredicate(format: "name =[c] %@", name)
        req.fetchLimit = 1
        if let found = try? moc.fetch(req).first { return found }

        let c = Category(context: moc)
        c.uuid = UUID()
        c.name = name
        try? moc.save()
        return c
    }

    func fetchTransaction(byHash hash: String) -> Transaction? {
        let req: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        req.predicate = NSPredicate(format: "importHash == %@", hash)
        req.fetchLimit = 1
        return try? moc.fetch(req).first
    }

    func importHash(date: Date, amount: Decimal, kind: TxKind, currency: String, note: String) -> String {
        let base = "\(date.timeIntervalSince1970)|\(amount)|\(kind.rawValue)|\(currency)|\(note)"
        return String(base.hashValue)
    }

    var importReady: Bool {
        guard table != nil else { return false }
        guard let dateCol = map[.date], !dateCol.isEmpty else { return false }
        if amountMode == 0 {
            return (map[.amount]?.isEmpty == false)
        } else {
            return (map[.debit]?.isEmpty == false) || (map[.credit]?.isEmpty == false)
        }
    }
}




