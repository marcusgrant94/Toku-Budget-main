//
//  PremiumStore.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

// PremiumStore.swift
import StoreKit
import Foundation

@MainActor
final class PremiumStore: ObservableObject {
    @Published var isPremium = false

    static let ids: Set<String> = ["year_premium", "month_premium"]
    static let coachCounterKey = "limits.coach.freePromptsUsed"   // 👈 free-counter key

    func start() {
        Task {
            await refreshEntitlements()
            await watchTransactions()
        }
    }

    func refreshEntitlements() async {
        var active = false
        for await ent in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = ent, Self.ids.contains(t.productID) {
                let ok = (t.revocationDate == nil) && (t.expirationDate ?? .distantFuture) > Date()
                if ok { active = true }
            }
        }
        isPremium = active

        // 👇 wipe free counters once the user upgrades
        if active { UserDefaults.standard.removeObject(forKey: Self.coachCounterKey) }
    }

    private func watchTransactions() async {
        for await update in StoreKit.Transaction.updates {
            if case .verified(let t) = update, Self.ids.contains(t.productID) {
                await t.finish()
                await refreshEntitlements()
            }
        }
    }
}




