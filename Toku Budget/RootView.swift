//
//  RootView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

import SwiftUI

struct RootView: View {
    // Default to Light now that "system" no longer exists
    @AppStorage("appAppearance") private var raw = AppAppearance.light.rawValue

    @Environment(\.managedObjectContext) private var moc
    @AppStorage(BillReminderDefaults.enabledKey)  private var remindersEnabled = true
    @AppStorage(BillReminderDefaults.leadDaysKey) private var leadDays = BillReminderDefaults.defaultLead

    // Coerce any legacy/unknown value (e.g. "system") to .light
    private var appearance: AppAppearance { AppAppearance(rawValue: raw) ?? .light }

    var body: some View {
        ContentView()
            .preferredColorScheme(appearance.colorScheme)
            .task {
                // One-time migration if a legacy "system" was stored
                if raw == "system" { raw = AppAppearance.light.rawValue }

                guard remindersEnabled else { return }
                BillReminder.shared.requestAuthorization()
                BillReminder.shared.rescheduleAll(context: moc, leadDays: leadDays)
            }
    }
}

