//
//  BillReminder.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/19/25.
//

import Foundation
import UserNotifications
import CoreData

enum BillReminderDefaults {
    static let enabledKey   = "billRemindersEnabled"
    static let leadDaysKey  = "billReminderLeadDays"
    static let defaultLead  = 2
}

final class BillReminder {
    static let shared = BillReminder()
    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            if let err = err { print("Notification auth error:", err) }
            if !granted { print("Notifications not granted") }
        }
    }

    func cancel(for sub: Subscription) {
        guard let id = sub.uuid?.uuidString else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.identifier(for: id)])
    }

    func schedule(for sub: Subscription, leadDays: Int = BillReminderDefaults.defaultLead) {
        guard let due = sub.nextBillingDate,
              let id  = sub.uuid?.uuidString else { return }

        // fire at 09:00 local, `leadDays` before due (skip if in the past)
        let cal = Calendar.current
        let fireBase = cal.date(byAdding: .day, value: -leadDays, to: due) ?? due
        var comps = cal.dateComponents([.year, .month, .day], from: fireBase)
        comps.hour = 9; comps.minute = 0
        guard let fire = cal.date(from: comps), fire > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = sub.name ?? "Bill due soon"
        let amount = (sub.amount?.doubleValue ?? 0)
        content.body  = "Due \(due.formatted(.dateTime.month(.abbreviated).day())) • \(amount.formatted(.currency(code: sub.currencyCode ?? "USD")))"
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: Self.identifier(for: id), content: content, trigger: trigger)

        // Replace any prior one
        cancel(for: sub)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { print("Schedule notif error:", err) }
        }
    }

    func rescheduleAll(context: NSManagedObjectContext, leadDays: Int = BillReminderDefaults.defaultLead) {
        context.perform {
            let req: NSFetchRequest<Subscription> = Subscription.fetchRequest()
            req.predicate = NSPredicate(format: "nextBillingDate != nil")
            if let subs = try? context.fetch(req) {
                subs.forEach { self.schedule(for: $0, leadDays: leadDays) }
            }
        }
    }

    private static func identifier(for uuid: String) -> String { "bill-\(uuid)" }
}
