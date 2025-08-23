//
//  AITipsCard.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import SwiftUI
import CoreData

struct AITipsCard: View {
    let window: DateWindow
    var viewID: String = "stats"

    @FetchRequest private var txs: FetchedResults<Transaction>
    @FetchRequest private var budgets: FetchedResults<Budget>
    @FetchRequest private var subs: FetchedResults<Subscription>

    @State private var text: String = ""
    @State private var isLoading = false
    @State private var lastError: String?

    init(window: DateWindow, viewID: String = "stats") {
        self.window = window
        self.viewID = viewID

        let tReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        tReq.predicate = NSPredicate(format: "date >= %@ AND date < %@", window.start as NSDate, window.end as NSDate)
        tReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        _txs = FetchRequest(fetchRequest: tReq)

        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: window.start))!
        let bReq: NSFetchRequest<Budget> = Budget.fetchRequest()
        bReq.predicate = NSPredicate(format: "periodStart == %@", monthStart as NSDate)
        bReq.sortDescriptors = [
            NSSortDescriptor(key: "category.name", ascending: true),
            NSSortDescriptor(key: "uuid",          ascending: true)
        ]
        _budgets = FetchRequest(fetchRequest: bReq)

        let sReq: NSFetchRequest<Subscription> = Subscription.fetchRequest()
        sReq.sortDescriptors = [NSSortDescriptor(key: "nextBillingDate", ascending: true)]
        _subs = FetchRequest(fetchRequest: sReq)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tips", systemImage: "lightbulb.max")
                    .font(.headline)
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh tips")
            }

            // --- CONTENT STATES ---
            if let err = lastError {
                Text("Tips are unavailable right now.")
                    .foregroundStyle(.secondary)
                    .task { print("AITipsCard error:", err) }

            } else if isLoading && text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading tips...")
                        .foregroundStyle(.secondary)
                }

            } else if text.isEmpty {
                Text("No tips yet, try refreshing")
                    .foregroundStyle(.secondary)

            } else {
                Text(.init(text))
                    .font(.callout)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
        .task(id: window.start) { await refresh() }
    }

    // MARK: - Load tips

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        let ctx = TipsContext.make(from: Array(txs),
                                   budgets: Array(budgets),
                                   subs: Array(subs),
                                   window: window)
        let prompt = dashboardPrompt(viewID: viewID, ctx: ctx)

        do {
            text = try await callWorker(prompt: prompt)
        } catch {
            lastError = error.localizedDescription
            text = ""
        }
    }

    // MARK: - Prompt for non-interactive dashboards

    private func dashboardPrompt(viewID: String, ctx c: TipsContext) -> String {
        var lines: [String] = []

        lines.append("""
        ROLE: Budgeting assistant for a NON-INTERACTIVE dashboard screen named "\(viewID)".
        DO NOT ask questions, greet, thank, or acknowledge. No rhetorical phrases.
        OUTPUT ONLY 3–5 short, imperative bullets (≤ 14 words each).
        No headings or closing lines. No follow-up questions. Just the bullets.
        """)

        lines.append("Currency: \(c.currency)")
        lines.append("Window: \(c.window.start) to \(c.window.end)")
        lines.append("Total spent: \(Int(c.totalSpent))")

        if !c.perCategory.isEmpty {
            lines.append("Top categories (up to 6):")
            for (i, row) in c.perCategory.prefix(6).enumerated() {
                lines.append("\(i+1). \(row.name): \(Int(row.spent))")
            }
        }
        if !c.overspent.isEmpty {
            lines.append("Overspent vs budget:")
            for o in c.overspent { lines.append("- \(o.name): \(Int(o.spent)) / \(Int(o.budget))") }
        }
        if c.subsMonthlyTotal > 0 {
            lines.append("Subscriptions monthly total: \(Int(c.subsMonthlyTotal))")
        }
        if let m = c.savingsGoalPerMonth, let d = c.savingsGoalDeadline {
            lines.append("Savings goal needs \(Int(m)) per month until \(d).")
        }

        lines.append("""
        WRITE THE BULLETS NOW:
        • Each bullet must be a concrete action with optional amount/category.
        • Avoid “consider/try/you could”; prefer strong, direct phrasing.
        • Keep totals implicit; do not add a “Total” line.
        """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Worker call

    private func callWorker(prompt: String) async throws -> String {
        guard let url = CoachWorker.baseURL() else {
            throw NSError(domain: "AITipsCard", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Worker URL"])
        }
        struct ReqBody: Encodable { let model: String; let input: String }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ReqBody(model: CoachWorker.model(), input: prompt))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let t = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AITipsCard", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: t])
        }

        struct Resp: Decodable {
            let output_text: String?
            let output: [Out]?
            struct Out: Decodable { let content: [Content]? }
            struct Content: Decodable { let type: String?; let text: String? }
        }
        if let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            if let t = decoded.output_text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
            if let outs = decoded.output {
                for o in outs {
                    if let t = o.content?.first(where: { ($0.text ?? "").isEmpty == false })?.text?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        return t
                    }
                }
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}


