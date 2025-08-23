//
//  ContentView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/16/25.
//

import SwiftUI
import CoreData

// MARK: - Local sidebar enum
private enum Section: Hashable {
    case overview, transactions, subscriptions, budgets, bills, stats, trends, coach
}

// MARK: - Environment hook so children can request navigation without seeing `Section`
private struct SuggestionNavigatorKey: EnvironmentKey {
    static let defaultValue: (SuggestionAction) -> Void = { _ in }
}
extension EnvironmentValues {
    var suggestionNavigator: (SuggestionAction) -> Void {
        get { self[SuggestionNavigatorKey.self] }
        set { self[SuggestionNavigatorKey.self] = newValue }
    }
}

// MARK: - Savings Goal change ping (so other views can refresh if they listen)
extension Notification.Name {
    static let savingsGoalUpdated = Notification.Name("SavingsGoalUpdated")
}

struct ContentView: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.colorScheme) private var scheme

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Category.name, ascending: true)],
        animation: .default
    ) private var categories: FetchedResults<Category>

    @State private var selection: Section? = .overview
    @State private var rangeMode: DateRangeMode = .month
    @State private var showGoalSheet = false
    @State private var showConnect = false

    private var window: DateWindow { DateWindow.make(for: rangeMode) }

    init() {}

    // Map SuggestionAction → local Section
    private func handleSuggestionAction(_ action: SuggestionAction) {
        switch action {
        case .openBudgets, .setBudget:
            selection = .budgets
        case .openSubscriptions:
            selection = .subscriptions
        case .openTrends:
            selection = .trends
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "rectangle.grid.2x2").tag(Section.overview)
                Label("Transactions", systemImage: "list.bullet.rectangle").tag(Section.transactions)
                Label("Subscriptions", systemImage: "square.stack.3d.up").tag(Section.subscriptions)
                Label("Bills", systemImage: "calendar.badge.clock").tag(Section.bills)
                Label("Budgets", systemImage: "chart.pie").tag(Section.budgets)
                Label("Stats", systemImage: "chart.pie.fill").tag(Section.stats)
                Label("Trends", systemImage: "chart.line.uptrend.xyaxis").tag(Section.trends)
                Label("Coach", systemImage: "message.and.waveform").tag(Section.coach)
            }
            .listStyle(.sidebar)
            .navigationTitle("Toku Budget")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            ZStack {
                Theme.bg(scheme).ignoresSafeArea()
                switch selection {
                case .overview:
                    OverviewView(window: window, mode: rangeMode)
                        .environment(\.suggestionNavigator, handleSuggestionAction)

                case .transactions:
                    TransactionsView(window: window)
                        .environment(\.suggestionNavigator, handleSuggestionAction)

                case .subscriptions:
                    SubscriptionsView()
                        .environment(\.suggestionNavigator, handleSuggestionAction)

                case .bills:
                    BillsView()
                        .environment(\.suggestionNavigator, handleSuggestionAction)

                case .budgets:
                    BudgetView()
                        .environment(\.suggestionNavigator, handleSuggestionAction)

                case .some(.stats):
                    StatsView(window: window)
                        .environment(\.suggestionNavigator, handleSuggestionAction)

                case .some(.trends):
                    TrendsView(window: window)
                        .environment(\.suggestionNavigator, handleSuggestionAction)

                case .some(.coach):
                    if let key = OpenAIKey.defaultProvider() {
                        ChatTipsView(window: window)
                            .environment(\.tipsChatService, OpenAITipsService(apiKey: key))
                    } else {
                        ChatTipsView(window: window)
                            .environment(\.tipsChatService, LocalRuleBasedTipsService())
                    }


                case .none:
                    Text("Select a section")
                }
            }
        }
        .task { try? seedIfNeeded() }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                DateRangePicker(mode: $rangeMode)
                CurrencyChips()
                AppearancePicker()
                Spacer(minLength: 0)
            }

            // Savings goal sheet
            ToolbarItem(placement: .automatic) {
                Button { showGoalSheet = true } label: {
                    Label("Savings Goal", systemImage: "scope") // target-like glyph
                }
            }

            // Connect OpenAI key (Keychain sheet)
            ToolbarItem(placement: .automatic) {
                Button { showConnect = true } label: {
                    Label("Connect OpenAI", systemImage: "bolt.horizontal")
                }
                .help("Store your OpenAI API key securely to unlock AI coaching")
            }

            #if os(macOS)
            // Import/Export menu
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import CSV…") { ImportCoordinator.presentImporter(moc) }
                    Button("Export CSV…") { ExportCoordinator.presentExporter(moc) }
                } label: {
                    Label("Import/Export", systemImage: "arrow.up.arrow.down.square")
                }
            }
            #endif
        }
        .sheet(isPresented: $showGoalSheet) {
            SavingsGoalSheet()
        }
        .sheet(isPresented: $showConnect) {
            ConnectOpenAIView()
        }
        .onChange(of: selection) { print("Sidebar selection ->", String(describing: $0)) }
    }

    // Dev-only seeding so UI has something to show
    private func seedIfNeeded() throws {
        if categories.isEmpty {
            ["Groceries","Transport","Entertainment","Utilities","Rent","Health","Shopping","Other"]
                .forEach { name in
                    let c = Category(context: moc)
                    c.name = name
                    c.icon = "tag"
                    c.colorHex = "#6B7280"
                }
            try moc.save()
        }
    }
}

// MARK: - Toolbar bits

struct DateRangePicker: View {
    @Binding var mode: DateRangeMode
    var body: some View {
        Picker("", selection: $mode) {
            ForEach(DateRangeMode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
    }
}

struct CurrencyChips: View {
    @State private var currency = "USD"
    var body: some View {
        HStack(spacing: 8) {
            Chip(title: "USD", selected: currency == "USD") { currency = "USD" }
            Chip(title: "JPY", selected: currency == "JPY") { currency = "JPY" }
        }
    }
}

struct Chip: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(selected ? Color.accentColor.opacity(0.12)
                                     : Theme.card(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.cardBorder(scheme))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Date range model

enum DateRangeMode: Int, CaseIterable, Identifiable {
    case month = 0, quarter = 1, year = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .month:   return "Month"
        case .quarter: return "Quarter"
        case .year:    return "Year"
        }
    }
}

struct DateWindow: Equatable {
    let start: Date
    let end: Date

    static func make(for mode: DateRangeMode,
                     anchor: Date = Date(),
                     cal: Calendar = .current) -> DateWindow {
        switch mode {
        case .month:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: anchor))!
            let end   = cal.date(byAdding: .month, value: 1, to: start)!
            return .init(start: start, end: end)

        case .quarter:
            let comps = cal.dateComponents([.year, .month], from: anchor)
            let month = comps.month ?? 1
            let qStartMonth = [1,4,7,10].last(where: { $0 <= month }) ?? 1
            var s = DateComponents()
            s.year  = comps.year
            s.month = qStartMonth
            let start = cal.date(from: s)!
            let end   = cal.date(byAdding: .month, value: 3, to: start)!
            return .init(start: start, end: end)

        case .year:
            let comps = cal.dateComponents([.year], from: anchor)
            let start = cal.date(from: comps)!
            let end   = cal.date(byAdding: .year, value: 1, to: start)!
            return .init(start: start, end: end)
        }
    }
}

// MARK: - Savings Goal Sheet

private struct SavingsGoalSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Decimal = 0
    @State private var targetDate: Date = Calendar.current.date(byAdding: .month, value: 12, to: Date())!
    @State private var hasExisting = false

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("Amount to save", value: $amount, format: .number)
                DatePicker("Target date", selection: $targetDate, displayedComponents: .date)
            } footer: {
                Text("Suggestions will use this to propose monthly/weekly saving targets and category trims.")
            }

            if hasExisting {
                SwiftUI.Section {
                    Button(role: .destructive) {
                        clearGoal()
                    } label: {
                        Label("Remove Goal", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Savings Goal")
        .frame(minWidth: 380, minHeight: 220)
        .onAppear {
            if let g = SavingsGoalStore().read() {
                amount = g.amount
                targetDate = g.targetDate
                hasExisting = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { saveGoal() }.disabled(amount <= 0)
            }
        }
    }

    private func saveGoal() {
        let store = SavingsGoalStore()
        store.write(SavingsGoal(amount: amount, targetDate: targetDate))
        NotificationCenter.default.post(name: .savingsGoalUpdated, object: nil)
        dismiss()
    }

    private func clearGoal() {
        UserDefaults.standard.set(0.0, forKey: "goal_amount")
        UserDefaults.standard.set(0.0, forKey: "goal_date")
        NotificationCenter.default.post(name: .savingsGoalUpdated, object: nil)
        dismiss()
    }
}







// MARK: - Preview

//#Preview {
//    let preview = PersistenceController(inMemory: true)
//    return ContentView()
//        .environment(\.managedObjectContext, preview.container.viewContext)
//}

