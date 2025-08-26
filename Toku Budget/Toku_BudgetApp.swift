//
//  Toku_BudgetApp.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/16/25.
//

import SwiftUI
import CoreData
import CloudKit
import Charts   // keep if you use Charts in top-level views

// Core Data-friendly enums
enum TxKind: Int16 { case expense = 0, income = 1 }
enum BillingCycle: Int16 { case monthly = 0, yearly = 1 }

@MainActor
func iCloudStatus() async -> CKAccountStatus {
    (try? await CKContainer.default().accountStatus()) ?? .couldNotDetermine
}

@main
struct Toku_BudgetApp: App {
    // Appearance
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.light.rawValue
    @AppStorage("settings.appearance.accent") private var accentRaw = AccentChoice.blue.rawValue
    private var appAppearance: AppAppearance { AppAppearance(rawValue: appAppearanceRaw) ?? .light }
    private var accent: AccentChoice { AccentChoice(rawValue: accentRaw) ?? .blue }

    // Core Data
    let persistence = PersistenceController.shared
    private var viewContext: NSManagedObjectContext { persistence.container.viewContext }

    // Premium + lifecycle
    @StateObject private var premiumStore = PremiumStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, viewContext)
                .environmentObject(premiumStore)
                .preferredColorScheme(appAppearance.colorScheme)
                .applyAppTint(accent.color)

                // Start IAP watcher + migrate any legacy "system" value to .light
                .task {
                    if appAppearanceRaw == "system" {
                        appAppearanceRaw = AppAppearance.light.rawValue
                    }
                    premiumStore.start()
                }

                // Keep IAP entitlements fresh when returning to foreground
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task { await premiumStore.refreshEntitlements() }
                    }
                }
        }
        .commands { ImportExportCommands() }
    }
}

private extension View {
    @ViewBuilder
    func applyAppTint(_ color: Color) -> some View {
        if #available(iOS 15, macOS 12, *) { self.tint(color) } else { self.accentColor(color) }
    }
}







