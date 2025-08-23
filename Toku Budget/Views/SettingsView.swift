//
//  Untitled.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import SwiftUI
import UniformTypeIdentifiers
import CoreData

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

private extension View {
    /// Adds an X close button to a sheet/nav stack.
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

    // ✅ Use the same key your app already uses globally
    @AppStorage("appAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    private var appAppearance: AppAppearance { AppAppearance(rawValue: appAppearanceRaw) ?? .system }

    // Appearance (extra knobs still local to Settings)
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
    @State private var showPaywall = false          // ⬅️ NEW

    @State private var showCSVExporter = false
    @State private var csvDoc = CSVDocument(data: Data())
    @State private var showPDFExporter = false
    @State private var pdfDoc = PDFDocument(data: Data())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ⭐ Toku Budget Premium (tap to open paywall)
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

                // Data & Maintenance
                CardSection {
                    tappableRow(
                        action: { showSyncSheet = true },
                        icon: ("arrow.triangle.2.circlepath", .blue),
                        title: "Sync",
                        subtitle: iCloudEnabled ? "iCloud enabled" : "iCloud off"
                    )
                    RowDivider()
                    tappableRow(
                        action: { showCategoriesSheet = true },
                        icon: ("list.bullet.rectangle", .gray),
                        title: "Categories"
                    )
                    RowDivider()
                    tappableRow(
                        action: { exportCSV() },
                        icon: ("square.and.arrow.up.on.square", .green),
                        title: "Export"
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
                        title: "Sort Sheets By",
                        trailing: sortKey.short
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
        .closeToolbar { dismiss() }   // X to close Settings

        // Sheets (each with its own X)
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
                AppearanceSettingsView() // writes to @AppStorage("appAppearance")
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

        // ⬇️ NEW: Paywall sheet
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                PaywallView() // ← your existing paywall
                    .navigationTitle("Toku Budget Premium")
                    .closeToolbar { showPaywall = false }
            }
            .frame(minWidth: 640, minHeight: 560)   // macOS nice default; ignored on iOS
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
        .frame(minHeight: 56) // consistent touch/visual height
    }

    // MARK: - Actions

    private func exportCSV() {
        let data = Data("date,category,amount\n2025-08-01,Groceries,42.18\n".utf8)
        #if os(macOS)
        MacFileHelper.save(suggested: "Transactions.csv", data: data)
        #else
        csvDoc = CSVDocument(data: data); showCSVExporter = true
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

    private func mappedSizeCategory(uiScale: Double) -> ContentSizeCategory {
        switch uiScale {
        case ..<0.95: return .small
        case ..<1.00: return .medium
        case ..<1.05: return .large
        case ..<1.10: return .extraLarge
        default:      return .extraExtraLarge
        }
    }
}

// MARK: - Sub-screens (no PrintSettingsView anymore)

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

    // ✅ Bind directly to your global key
    @AppStorage("appAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appAppearanceRaw) ?? .system },
            set: { appAppearanceRaw = $0.rawValue }
        )
    }

    @AppStorage("settings.appearance.accent")  private var accent: AccentChoice = .blue
    @AppStorage("settings.appearance.uiScale") private var uiScale: Double = 1.0

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Accent Color"); Spacer()
                    Picker("", selection: $accent) {
                        ForEach(AccentChoice.allCases) { c in
                            HStack {
                                Circle().fill(c.color).frame(width: 12, height: 12)
                                Text(c.rawValue.capitalized)
                            }.tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("UI Scale"); Spacer()
                        Text("\(Int(uiScale * 100))%")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $uiScale, in: 0.9...1.2, step: 0.01)
                }
            } header: { Text("Appearance") }
        }
        .preferredColorScheme((AppAppearance(rawValue: appAppearanceRaw) ?? .system).colorScheme)
        .closeToolbar { dismiss() }
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
    @AppStorage("settings.sync.icloudEnabled") private var iCloudEnabled: Bool = true
    @AppStorage("settings.sync.lastRun")       private var lastSyncTimestamp: Double = 0
    var body: some View {
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
            Button { lastSyncTimestamp = Date().timeIntervalSince1970 }
            label: { Label("Sync Now", systemImage: "arrow.clockwise") }
            .disabled(!iCloudEnabled)
        }
        .padding()
        .closeToolbar { dismiss() }
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

    // MARK: - Batch delete

    private func nukeAllTransactions() async {
        isWorking = true
        defer { isWorking = false }

        let fetch: NSFetchRequest<NSFetchRequestResult> = Transaction.fetchRequest()
        let req = NSBatchDeleteRequest(fetchRequest: fetch)
        req.resultType = .resultTypeObjectIDs

        do {
            if let res = try moc.execute(req) as? NSBatchDeleteResult,
               let deletedIDs = res.result as? [NSManagedObjectID] {
                // Make existing FRCs / @FetchRequest update immediately
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









