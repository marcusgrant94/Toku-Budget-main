//
//  RootView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

import SwiftUI

struct RootView: View {
    @AppStorage("appAppearance") private var raw = AppAppearance.system.rawValue
    @Environment(\.managedObjectContext) private var moc
       @AppStorage(BillReminderDefaults.enabledKey)  private var remindersEnabled = true
       @AppStorage(BillReminderDefaults.leadDaysKey) private var leadDays = BillReminderDefaults.defaultLead
    private var appearance: AppAppearance { AppAppearance(rawValue: raw) ?? .system }

    var body: some View {
        ContentView()
                   .preferredColorScheme(appearance.colorScheme)
                   .task {
                       guard remindersEnabled else { return }
                       BillReminder.shared.requestAuthorization()
                       BillReminder.shared.rescheduleAll(context: moc, leadDays: leadDays)
                   }
            .preferredColorScheme(appearance.colorScheme) 
    }
}
