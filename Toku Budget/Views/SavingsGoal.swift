//
//  Untitled.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import Foundation
import SwiftUI

struct SavingsGoal {
    var amount: Decimal   // total amount to save
    var targetDate: Date  // deadline
}

final class SavingsGoalStore {
    // Simple storage for now. Replace with Core Data later if you prefer.
    @AppStorage("goal_amount") private var rawAmount: Double = 0
    @AppStorage("goal_date")   private var rawDate: Double   = 0  // timeIntervalSince1970

    func read() -> SavingsGoal? {
        guard rawAmount > 0, rawDate > 0 else { return nil }
        return SavingsGoal(amount: Decimal(rawAmount), targetDate: Date(timeIntervalSince1970: rawDate))
    }

    func write(_ goal: SavingsGoal) {
        rawAmount = (goal.amount as NSDecimalNumber).doubleValue
        rawDate   = goal.targetDate.timeIntervalSince1970
    }

    // Quick helper for tests:
    static func seed(amount: Double, monthsFromNow: Int = 12) {
        let d = Calendar.current.date(byAdding: .month, value: monthsFromNow, to: Date())!
        UserDefaults.standard.set(amount, forKey: "goal_amount")
        UserDefaults.standard.set(d.timeIntervalSince1970, forKey: "goal_date")
    }
}
