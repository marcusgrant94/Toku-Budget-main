//
//  Untitled.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import SwiftUI
import UniformTypeIdentifiers
import CoreData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Small helpers

private struct LeadingIcon: View {
    let systemName: String
    let color: Color
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.18))
            Image(systemName: systemName)
                .foregroundStyle(color)
                .font(.system(size: 18, weight: .semibold))
        }
        .frame(width: 40, height: 40)
    }
}

private struct CardSection<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.thinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.08)))
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 64)
    }
}

extension View {
    func closeToolbar(_ action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: action) { Image(systemName: "xmark.circle.fill") }
                    .help("Close")
            }
        }
    }
}

// MARK: - FileDocument helpers (iOS/iPadOS)

struct CSVDocument: FileDocument, Identifiable {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let id = UUID()
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

struct PDFDocument: FileDocument, Identifiable {
    static var readableContentTypes: [UTType] { [.pdf] }
    let id = UUID()
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

#if os(macOS)
import AppKit
enum MacFileHelper {
    static func save(suggested: String, data: Data) {
        let p = NSSavePanel()
        p.nameFieldStringValue = suggested
        p.begin { resp in
            guard resp == .OK, let url = p.url else { return }
            try? data.write(to: url)
        }
    }
}
#endif

// MARK: - Settings Root

struct SettingsRootView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var premium: PremiumStore
    @Environment(\.managedObjectContext) private var moc   // ⬅️ for real CSV export

    // Global appearance key (AppAppearance is defined elsewhere)
    @AppStorage("appAppearance") private var appAppearanceRaw: String = AppAppearance.light.rawValue
    private var appAppearance: AppAppearance { AppAppearance(rawValue: appAppearanceRaw) ?? .light }

    // Appearance
    @AppStorage("settings.appearance.accent")  private var accent: AccentChoice = .blue
    @AppStorage("settings.appearance.uiScale") private var uiScale: Double = 1.0

    // Other prefs
    @AppStorage("settings.sheets.sortKey")      private var sortKey: SheetsSortKey = .dateDesc
    @AppStorage("settings.sync.icloudEnabled")  private var iCloudEnabled: Bool = true
    @AppStorage("settings.sync.lastRun")        private var lastSyncTimestamp: Double = 0

    // Sheets / exporters
    @State private var showCSVImportSheet = false
    @State private var showAppearanceSheet = false
    @State private var showCategoriesSheet = false
    @State private var showSyncSheet = false
    @State private var showSortSheet = false
    @State private var showTrashSheet = false
    @State private var showPaywall = false
    @State private var showAboutSheet = false   // ⬅️ NEW

    @State private var showCSVExporter = false
    @State private var csvDoc = CSVDocument(data: Data())
    @State private var showPDFExporter = false
    @State private var pdfDoc = PDFDocument(data: Data())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ⭐ Premium (only show if NOT subscribed)
                if !premium.isPremium {
                    Button { showPaywall = true } label: {
                        HStack {
                            LeadingIcon(systemName: "star.fill", color: .yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Toku Budget Premium").font(.headline)
                                Text("Unlock advanced reports and automation")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.thinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.08)))
                    .opacity(0.9)
                }

                // Data & Maintenance
                CardSection {
                    // 🔒 Sync locked unless Premium
                    tappableRow(
                        action: {
                            if premium.isPremium { showSyncSheet = true }
                            else { showPaywall = true }
                        },
                        icon: ("arrow.triangle.2.circlepath", premium.isPremium ? .blue : .gray),
                        title: "Sync",
                        subtitle: premium.isPremium
                            ? (iCloudEnabled ? "iCloud enabled" : "iCloud off")
                            : "Premium required",
                        trailing: premium.isPremium ? nil : "Premium"
                    )
                    RowDivider()
                    tappableRow(
                        action: { showCategoriesSheet = true },
                        icon: ("list.bullet.rectangle", .gray),
                        title: "Categories"
                    )
                    RowDivider()

                    // 🔒 CSV Export locked unless Premium
                    tappableRow(
                        action: {
                            if premium.isPremium { exportCSV() } else { showPaywall = true }
                        },
                        icon: ("square.and.arrow.up.on.square", premium.isPremium ? .green : .gray),
                        title: "Export",
                        subtitle: premium.isPremium ? nil : "Premium required",
                        trailing: premium.isPremium ? nil : "Premium"
                    )

                    RowDivider()
                    tappableRow(
                        action: { showCSVImportSheet = true },
                        icon: ("tray.and.arrow.down", .green.opacity(0.9)),
                        title: "Import"
                    )
                    RowDivider()
                    tappableRow(
                        action: { showTrashSheet = true },
                        icon: ("trash", .red),
                        title: "Trash"
                    )
                }

                // Appearance & Display
                CardSection {
                    tappableRow(
                        action: { showAppearanceSheet = true },
                        icon: ("moon.stars.fill", .indigo),
                        title: "Appearance",
                        trailing: appAppearance.label
                    )
                    RowDivider()
                    tappableRow(
                        action: { showSortSheet = true },
                        icon: ("arrow.up.arrow.down", .teal),
                        title: "Sort Transactions By",
                        trailing: sortKey.short
                    )
                }

                // 📨 Support
                CardSection {
                    tappableRow(
                        action: { sendFeedback() },
                        icon: ("paperplane.fill", .blue),
                        title: "Send Feedback"
                    )
                    RowDivider()
                    tappableRow(
                        action: { openFAQ() },
                        icon: ("questionmark.circle.fill", .blue),
                        title: "FAQ"
                    )
                    RowDivider()
                    tappableRow(                              // ⬅️ About row
                        action: { showAboutSheet = true },
                        icon: ("info.circle.fill", .blue),
                        title: "About"
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("Settings")
        .tint(accent.color)
        .preferredColorScheme(appAppearance.colorScheme)
        .environment(\.sizeCategory, mappedSizeCategory(uiScale: uiScale))
        .closeToolbar { dismiss() }

        // Sheets
        .sheet(isPresented: $showCSVImportSheet) {
            NavigationStack {
                CSVImportView()
                    .navigationTitle("Import CSV")
                    .padding()
                    .closeToolbar { showCSVImportSheet = false }
            }
            .frame(minWidth: 720, minHeight: 520)
        }
        .sheet(isPresented: $showAppearanceSheet) {
            NavigationStack {
                AppearanceSettingsView()
                    .padding()
                    .closeToolbar { showAppearanceSheet = false }
            }
            .frame(minWidth: 420, minHeight: 260)
        }
        .sheet(isPresented: $showCategoriesSheet) {
            NavigationStack {
                CategoriesSettingsView()
                    .padding()
                    .closeToolbar { showCategoriesSheet = false }
            }
            .frame(minWidth: 420, minHeight: 220)
        }
        .sheet(isPresented: $showSyncSheet) {
            NavigationStack {
                SyncSettingsView()
                    .padding()
                    .closeToolbar { showSyncSheet = false }
            }
            .frame(minWidth: 420, minHeight: 240)
        }
        .sheet(isPresented: $showSortSheet) {
            NavigationStack {
                SortSheetsView()
                    .padding()
                    .closeToolbar { showSortSheet = false }
            }
            .frame(minWidth: 420, minHeight: 220)
        }
        .sheet(isPresented: $showTrashSheet) {
            NavigationStack {
                TrashToolsView()
                    .padding()
                    .closeToolbar { showTrashSheet = false }
            }
            .frame(minWidth: 420, minHeight: 220)
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                PaywallView()
                    .navigationTitle("Toku Budget Premium")
                    .closeToolbar { showPaywall = false }
            }
            .frame(minWidth: 640, minHeight: 560)
        }
        // ⬇️ About sheet
        .sheet(isPresented: $showAboutSheet) {
            NavigationStack {
                AboutView()
                    .padding()
                    .closeToolbar { showAboutSheet = false }
            }
            .frame(minWidth: 420, minHeight: 520)
        }

        // Exporters (iOS/iPadOS)
        .fileExporter(isPresented: $showCSVExporter, document: csvDoc,
                      contentType: .commaSeparatedText, defaultFilename: "Transactions") { _ in }
        .fileExporter(isPresented: $showPDFExporter, document: pdfDoc,
                      contentType: .pdf, defaultFilename: "Overview") { _ in }
    }

    // MARK: - Row builders

    private func tappableRow(action: @escaping () -> Void,
                             icon: (String, Color),
                             title: String,
                             subtitle: String? = nil,
                             trailing: String? = nil) -> some View {
        Button(action: action) {
            row(icon: icon.0, color: icon.1, title: title, subtitle: subtitle, trailing: trailing)
        }
        .buttonStyle(.plain)
    }

    private func row(icon: String, color: Color, title: String,
                     subtitle: String? = nil, trailing: String? = nil) -> some View {
        HStack(spacing: 14) {
            LeadingIcon(systemName: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let s = subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let t = trailing { Text(t).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
    }

    // MARK: - Actions

    private func exportCSV() {
        #if os(macOS)
        // Use the shared macOS exporter (real data)
        ExportCoordinator.presentExporter(moc)
        #else
        // Build CSV from Core Data (real data) and invoke the file exporter
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

        let csv = makeCSV(rows)
        csvDoc = CSVDocument(data: Data(csv.utf8))
        showCSVExporter = true
        #endif
    }

    private func exportPDF() {
        let data = Data([0x25,0x50,0x44,0x46]) // %PDF (stub)
        #if os(macOS)
        MacFileHelper.save(suggested: "Overview.pdf", data: data)
        #else
        pdfDoc = PDFDocument(data: data); showPDFExporter = true
        #endif
    }

    // Minimal CSV writer (escapes quotes/commas/newlines)
    private func makeCSV(_ rows: [[String]]) -> String {
        func escape(_ s: String) -> String {
            if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) {
                return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return s
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n")
    }

    private func mappedSizeCategory(uiScale: Double) -> ContentSizeCategory {
        switch uiScale {
        case ..<0.95: return .small
        case ..<1.00: return .medium
        case ..<1.05: return .large
        case ..<1.10: return .extraLarge
        default:      return .extraExtraLarge
        }
    }

    private func sendFeedback() {
        let email = "grantmarcus1994@gmail.com"
        guard let url = URL(string: "mailto:\(email)") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    private func openFAQ() {
        guard let url = URL(string: "https://marcusgrant94.github.io/toku-budget-faq/") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Sub-screens (no PrintSettingsView)

enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, green, teal, orange, pink, purple, indigo, yellow
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue:   return .blue
        case .green:  return .green
        case .teal:   return .teal
        case .orange: return .orange
        case .pink:   return .pink
        case .purple: return .purple
        case .indigo: return .indigo
        case .yellow: return .yellow
        }
    }
}

enum SheetsSortKey: String, CaseIterable, Identifiable {
    case dateDesc, dateAsc, amountDesc, amountAsc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateDesc:   return "Date (Newest First)"
        case .dateAsc:    return "Date (Oldest First)"
        case .amountDesc: return "Amount (High → Low)"
        case .amountAsc:  return "Amount (Low → High)"
        }
    }
    var short: String {
        switch self {
        case .dateDesc:   return "Newest"
        case .dateAsc:    return "Oldest"
        case .amountDesc: return "High→Low"
        case .amountAsc:  return "Low→High"
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var premium: PremiumStore

    @AppStorage("appAppearance") private var appAppearanceRaw: String = AppAppearance.light.rawValue
    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appAppearanceRaw) ?? .light },
            set: { appAppearanceRaw = $0.rawValue }
        )
    }

    @AppStorage("settings.appearance.accent")  private var accent: AccentChoice = .blue
    @AppStorage("settings.appearance.uiScale") private var uiScale: Double = 1.0

    // Present paywall immediately from inside this sheet
    @State private var showPaywallLocal = false

    // Gate non-blue choices
    private var accentBinding: Binding<AccentChoice> {
        Binding(
            get: { accent },
            set: { newValue in
                if !premium.isPremium && newValue != .blue {
                    accent = .blue
                    showPaywallLocal = true       // ⬅️ present now
                } else {
                    accent = newValue
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Accent Color"); Spacer()
                    Picker("", selection: accentBinding) {
                        ForEach(AccentChoice.allCases) { c in
                            HStack(spacing: 8) {
                                Circle().fill(c.color).frame(width: 12, height: 12)
                                Text(c.rawValue.capitalized)
                                if !premium.isPremium && c != .blue {
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                }
                            }
                            .tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                if !premium.isPremium {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                        Text("Blue is free. Unlock more colors with Premium.")
                        Spacer()
                        Button("Upgrade") { showPaywallLocal = true } // ⬅️ immediate
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } header: { Text("Appearance") }
        }
        .preferredColorScheme((AppAppearance(rawValue: appAppearanceRaw) ?? .light).colorScheme)
        .closeToolbar { dismiss() }
        .sheet(isPresented: $showPaywallLocal) {
            NavigationStack {
                PaywallView()
                    .navigationTitle("Toku Budget Premium")
                    .closeToolbar { showPaywallLocal = false }
            }
            .frame(minWidth: 640, minHeight: 560)
        }
    }
}

struct CategoriesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Categories").font(.title2).bold()
            Text("Manage categories in **Budgets** and **Transactions**.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: 420, minHeight: 220)
        .padding()
        .closeToolbar { dismiss() }
    }
}

struct SyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var premium: PremiumStore

    @AppStorage("settings.sync.icloudEnabled") private var iCloudEnabled: Bool = true
    @AppStorage("settings.sync.lastRun")       private var lastSyncTimestamp: Double = 0

    @State private var showPaywallLocal = false

    var body: some View {
        Group {
            if premium.isPremium {
                Form {
                    Toggle("Sync with iCloud", isOn: $iCloudEnabled)
                    HStack {
                        Text("Last Sync"); Spacer()
                        Text(lastSyncTimestamp > 0
                             ? Date(timeIntervalSince1970: lastSyncTimestamp)
                                .formatted(date: .abbreviated, time: .shortened)
                             : "—")
                        .foregroundStyle(.secondary)
                    }
                    Button {
                        lastSyncTimestamp = Date().timeIntervalSince1970
                    } label: {
                        Label("Sync Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(!iCloudEnabled)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill").font(.largeTitle)
                    Text("Sync is a Premium feature").font(.title3).bold()
                    Text("Upgrade to enable iCloud sync and automatic updates.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    HStack(spacing: 12) {
                        Button("Not Now") { dismiss() }
                            .buttonStyle(.bordered)
                        Button("Upgrade") { showPaywallLocal = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(minWidth: 420, minHeight: 220)
                .padding()
            }
        }
        .navigationTitle("Sync")
        .closeToolbar { dismiss() }
        .sheet(isPresented: $showPaywallLocal) {
            NavigationStack {
                PaywallView()
                    .navigationTitle("Toku Budget Premium")
                    .closeToolbar { showPaywallLocal = false }
            }
            .frame(minWidth: 640, minHeight: 560)
        }
    }
}

struct SortSheetsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.sheets.sortKey") private var sortKey: SheetsSortKey = .dateDesc
    var body: some View {
        Form {
            Section {
                Picker("Sort by", selection: $sortKey) {
                    ForEach(SheetsSortKey.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } header: { Text("Sort Sheets By") }
        }
        .closeToolbar { dismiss() }
    }
}

struct TrashToolsView: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.dismiss) private var dismiss

    @State private var confirming = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Label("Delete All Transactions", systemImage: "trash")
                }
            } footer: {
                Text("This permanently removes every transaction. This cannot be undone.")
            }

            if let err = errorMessage {
                Section {
                    Text(err).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Trash")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .alert("Delete ALL transactions?", isPresented: $confirming) {
            Button("Delete", role: .destructive) { Task { await nukeAllTransactions() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .overlay {
            if isWorking {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Deleting…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                .frame(width: 160, height: 120)
            }
        }
    }

    private func nukeAllTransactions() async {
        isWorking = true
        defer { isWorking = false }

        let fetch: NSFetchRequest<NSFetchRequestResult> = Transaction.fetchRequest()
        let req = NSBatchDeleteRequest(fetchRequest: fetch)
        req.resultType = .resultTypeObjectIDs

    do {
            if let res = try moc.execute(req) as? NSBatchDeleteResult,
               let deletedIDs = res.result as? [NSManagedObjectID] {
                let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: deletedIDs]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [moc])
            }
            try? moc.save()
            dismiss()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}
















