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
    let persistence = PersistenceController.shared


    var body: some Scene {
            WindowGroup {
                RootView()
                    .environment(\.managedObjectContext, persistence.container.viewContext)
//                PaywallView()
//                SettingsRootView()
            }
            .commands {
                ImportExportCommands()
            }
        }
    }




