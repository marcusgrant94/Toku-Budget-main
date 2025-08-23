//
//  ChatTipsView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/23/25.
//

import SwiftUI
import CoreData
import Foundation
import Security

// MARK: - Chat service protocol

protocol TipsChatService {
    func reply(to userMessage: String, context: TipsContext) async throws -> String
}

// Default env uses a smart wrapper that decides Local vs OpenAI at call-time.
private struct TipsChatServiceKey: EnvironmentKey {
    static let defaultValue: TipsChatService = SmartTipsService()
}
extension EnvironmentValues {
    var tipsChatService: TipsChatService {
        get { self[TipsChatServiceKey.self] }
        set { self[TipsChatServiceKey.self] = newValue }
    }
}

// MARK: - Data context passed to the “AI”

struct TipsContext {
    let currency: String
    let window: DateWindow
    let totalSpent: Double
    let perCategory: [(name: String, spent: Double)]
    let overspent: [(name: String, spent: Double, budget: Double)]
    let subsMonthlyTotal: Double
    let upcomingBills: [(name: String, due: Date, amount: Double)]
    let savingsGoalPerMonth: Double?
    let savingsGoalDeadline: Date?

    static func make(from txs: [Transaction],
                     budgets: [Budget],
                     subs: [Subscription],
                     window: DateWindow) -> TipsContext
    {
        let currency = txs.first?.currencyCode ?? "USD"
        let expenses = txs.filter { $0.kind == TxKind.expense.rawValue }

        // total spent
        let totalSpent = expenses
            .map { ($0.amount?.decimalValue ?? 0) as NSDecimalNumber }
            .map(\.doubleValue)
            .reduce(0, +)

        // per-category spend
        var catMap: [String: Double] = [:]
        for t in expenses {
            let name = (t.category?.name?.isEmpty == false) ? (t.category!.name!) : "—"
            let v = (t.amount?.decimalValue ?? 0) as NSDecimalNumber
            catMap[name, default: 0] += v.doubleValue
        }
        let perCategory = catMap.map { (k, v) in (name: k, spent: v) }
            .sorted { $0.spent > $1.spent }

        // overspent vs budget
        var overs: [(String, Double, Double)] = []
        if !budgets.isEmpty {
            var spentByCat: [NSManagedObjectID: Double] = [:]
            for t in expenses {
                if let cat = t.category {
                    let v = (t.amount?.decimalValue ?? 0) as NSDecimalNumber
                    spentByCat[cat.objectID, default: 0] += v.doubleValue
                }
            }
            for b in budgets {
                guard let cat = b.category else { continue }
                let spent = spentByCat[cat.objectID] ?? 0
                let budget = (b.amount ?? 0).doubleValue
                if budget > 0, spent > budget {
                    overs.append((cat.name ?? "—", spent, budget))
                }
            }
            overs.sort { ($0.1 - $0.2) > ($1.1 - $1.2) }
        }

        // subs monthly equivalent & upcoming 45 days
        var monthly: Double = 0
        var upcoming: [(String, Date, Double)] = []
        let cal = Calendar.current
        let soon = cal.date(byAdding: .day, value: 45, to: Date())!

        for s in subs {
            let amt = (s.amount ?? 0).doubleValue
            let cycle = BillingCycle(rawValue: s.billingCycle) ?? .monthly
            monthly += (cycle == .monthly) ? amt : (amt / 12.0)
            if let d = s.nextBillingDate, d <= soon {
                upcoming.append((s.name ?? "—", d, amt))
            }
        }
        upcoming.sort { $0.1 < $1.1 }

        // savings goal
        let store = SavingsGoalStore()
        let goal = store.read()
        var perMonth: Double? = nil
        var deadline: Date? = nil
        if let g = goal {
            deadline = g.targetDate
            let months = max(1, cal.dateComponents([.month], from: Date(), to: g.targetDate).month ?? 1)
            perMonth = (g.amount as NSDecimalNumber).doubleValue / Double(months)
        }

        return TipsContext(
            currency: currency,
            window: window,
            totalSpent: totalSpent,
            perCategory: perCategory,
            overspent: overs,
            subsMonthlyTotal: monthly,
            upcomingBills: upcoming,
            savingsGoalPerMonth: perMonth,
            savingsGoalDeadline: deadline
        )
    }
}

// MARK: - Local rule-based assistant (offline)

struct LocalRuleBasedTipsService: TipsChatService {
    func reply(to userMessage: String, context c: TipsContext) async throws -> String {
        var items: [(label: String, save: Double)] = []

        if let pm = c.savingsGoalPerMonth, pm > 0 {
            items.append(("auto-transfer to savings", pm))
        }

        for o in c.overspent.prefix(2) {
            let overage = max(0, o.spent - o.budget)
            let cut = max(5, min(overage, o.spent * 0.15))
            items.append(("trim \(o.name) 10–15%", cut))
        }

        if c.subsMonthlyTotal > 0 {
            items.append(("cancel one unused subscription", min(20, c.subsMonthlyTotal * 0.15)))
        }

        for row in c.perCategory.dropFirst().prefix(2) {
            let cut = max(5, (row.spent * 0.05).rounded())
            items.append(("reduce \(row.name) extras", cut))
        }

        // ✅ Use labeled tuple fields consistently
        items = Array(
            items
                .map { (label: $0.label, save: max(5, $0.save)) }
                .sorted { $0.save > $1.save }
                .prefix(5)
        )

        let bullets = items.map {
            let amt = $0.save.formatted(.currency(code: c.currency))
            return "• Save \(amt)/mo by \($0.label)"
        }.joined(separator: "\n")

        let total = items.reduce(0) { $0 + $1.save }
        let totalStr = total.formatted(.currency(code: c.currency))
        return "\(bullets)\n\n**Total: \(totalStr)/mo**"
    }
}



// MARK: - Smart wrapper (decides OpenAI vs Local every call)

struct SmartTipsService: TipsChatService {
    func reply(to userMessage: String, context: TipsContext) async throws -> String {
        if let key = OpenAIKey.defaultProvider(), !key.isEmpty {
            do {
                return try await OpenAITipsService(apiKey: key).reply(to: userMessage, context: context)
            } catch {
                // Log and fall back to local tips instead of throwing
                print("OpenAI failed:", error)
                let local = try await LocalRuleBasedTipsService().reply(to: userMessage, context: context)
                return "⚠️ Using local tips (online service unavailable).\n\n" + local
            }
        } else {
            return try await LocalRuleBasedTipsService().reply(to: userMessage, context: context)
        }
    }
}


// MARK: - OpenAI (Responses API) implementation

struct OpenAITipsService: TipsChatService {
    let apiKey: String

    func reply(to userMessage: String, context c: TipsContext) async throws -> String {
        let prompt = buildPrompt(userMessage: userMessage, ctx: c)

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host   = "api.openai.com"
        comps.path   = "/v1/responses"
        guard let url = comps.url else { throw NSError(domain: "OpenAI", code: -2) }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct ReqBody: Encodable { let model: String; let input: String; let temperature: Double }
        req.httpBody = try JSONEncoder().encode(ReqBody(model: "gpt-4o-mini", input: prompt, temperature: 0.2))

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "OpenAI", code: -3, userInfo: [NSLocalizedDescriptionKey:"No HTTP response"])
        }
        guard http.statusCode == 200 else {
            let txt = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenAI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(txt)"])
        }

        // new (handles both `output_text` and `output[].content[].text`)
        struct Resp: Decodable {
            let output_text: String?
            let output: [Out]?
            struct Out: Decodable {
                let content: [Content]?
            }
            struct Content: Decodable {
                let type: String?
                let text: String?
            }
        }

        let decoded = try JSONDecoder().decode(Resp.self, from: data)

        // 1) Prefer the convenience field if present
        if let t = decoded.output_text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            return t
        }

        // 2) Fallback to first non-empty text in output[].content[].text
        if let outs = decoded.output {
            for item in outs {
                if let piece = item.content?.first(where: { ($0.text ?? "").isEmpty == false }),
                   let t = piece.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !t.isEmpty {
                    return t
                }
            }
        }

        // 3) Last resort: show raw JSON (shortened) for debugging
        let raw = String(data: data, encoding: .utf8) ?? "(binary)"
        return "I didn’t get a text reply back. (Raw: \(raw.prefix(400)))"

    }

    // Simple prompt composer — compact, action-oriented
    private func buildPrompt(userMessage: String, ctx c: TipsContext) -> String {
        var lines: [String] = []
        lines.append("You are a budgeting assistant. Use the provided data to give concrete, personalized actions.")
        lines.append("Currency: \(c.currency)")
        lines.append("Window: \(c.window.start) to \(c.window.end)")
        lines.append("Total spent: \(c.totalSpent)")

        if !c.perCategory.isEmpty {
            lines.append("Per-category spent (top 8):")
            for (i, row) in c.perCategory.prefix(8).enumerated() {
                lines.append("\(i+1). \(row.name): \(row.spent)")
            }
        }
        if !c.overspent.isEmpty {
            lines.append("Overspent vs budget:")
            for o in c.overspent { lines.append("- \(o.name): spent \(o.spent) / budget \(o.budget)") }
        }
        if c.subsMonthlyTotal > 0 {
            lines.append("Subscriptions monthly total: \(c.subsMonthlyTotal)")
        }
        if let m = c.savingsGoalPerMonth, let d = c.savingsGoalDeadline {
            lines.append("Savings goal: needs \(m) per month until \(d).")
        }

        lines.append("User question: \(userMessage)")

        // 🔻 Output contract: tiny, scannable list only
        lines.append("""
        OUTPUT RULES:
        - Respond ONLY with a short Markdown list (no headings, no intro/outro).
        - Make 3–5 bullets. Each bullet ≤ 12 words.
        - Each bullet must follow: "• Save <amount>/mo by <action> (<category or source>)".
        - Amounts must be realistic for the user, using the data above.
        - Finish with a final line: "**Total: <amount>/mo**".
        """)
        return lines.joined(separator: "\n")
    }
}


// MARK: - Key management

enum OpenAIKey {
    /// Return key from ENV → Keychain → UserDefaults (in that order).
    static func defaultProvider() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        if let v = try? Keychain.shared.get("openai.api.key"), !v.isEmpty {
            return v
        }
        if let v = UserDefaults.standard.string(forKey: "openai.api.key"), !v.isEmpty {
            return v
        }
        return nil
    }

    static func saveToKeychain(_ key: String) throws {
        try Keychain.shared.set(key, for: "openai.api.key")
        UserDefaults.standard.set(key, forKey: "openai.api.key") // convenience fallback
    }
}

final class Keychain {
    static let shared = Keychain()
    enum KCError: Error { case notFound, unhandled(OSStatus) }

    func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data
        ]
        SecItemDelete(query as CFDictionary) // replace if exists
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KCError.unhandled(status) }
    }

    func get(_ key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key,
            kSecReturnData as String:       kCFBooleanTrue as Any,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else {
            throw KCError.notFound
        }
        return s
    }
}

// MARK: - Chat model & UI

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, system }
    let id = UUID()
    let role: Role
    let text: String
    let date = Date()
}

final class ChatVM: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var pendingUserQuery: String?

    func appendUser(_ t: String)      { messages.append(.init(role: .user,      text: t)) }
    func appendAssistant(_ t: String)  { messages.append(.init(role: .assistant, text: t)) }
    func appendSystem(_ t: String)     { messages.append(.init(role: .system,    text: t)) }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant || message.role == .system {
                bubble(alignment: .leading, isUser: false)
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble(alignment: .trailing, isUser: true)
            }
        }
    }

    private func bubble(alignment: HorizontalAlignment, isUser: Bool) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if message.role == .system {
                Label("Tip", systemImage: "lightbulb")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(.callout)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isUser ? Color.accentColor.opacity(0.20)
                             : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        )
    }
}

struct ChatTipsView: View {
    let window: DateWindow
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.tipsChatService) private var chatService

    @FetchRequest private var txs: FetchedResults<Transaction>
    @FetchRequest private var budgets: FetchedResults<Budget>
    @FetchRequest private var subs: FetchedResults<Subscription>

    @StateObject private var vm = ChatVM()
    @State private var draft = ""

    init(window: DateWindow) {
        self.window = window

        let tReq: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        tReq.predicate = NSPredicate(format: "date >= %@ AND date < %@", window.start as NSDate, window.end as NSDate)
        tReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        _txs = FetchRequest(fetchRequest: tReq)

        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: window.start))!
        let bReq: NSFetchRequest<Budget> = Budget.fetchRequest()
        bReq.predicate = NSPredicate(format: "periodStart == %@", monthStart as NSDate)
        bReq.sortDescriptors = [NSSortDescriptor(key: "uuid", ascending: true)]
        _budgets = FetchRequest(fetchRequest: bReq)

        let sReq: NSFetchRequest<Subscription> = Subscription.fetchRequest()
        sReq.sortDescriptors = [NSSortDescriptor(key: "nextBillingDate", ascending: true)]
        _subs = FetchRequest(fetchRequest: sReq)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { msg in
                            ChatBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: vm.messages.count) { _ in
                    if let id = vm.messages.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            inputBar
        }
        .onAppear {
            if vm.messages.isEmpty {
                vm.appendSystem("Ask about saving money, budgets, or subscriptions. I’ll use your data for this period.")
            }
        }
        .task(id: vm.pendingUserQuery) {
            guard let q = vm.pendingUserQuery else { return }
            let ctx = TipsContext.make(from: Array(txs), budgets: Array(budgets), subs: Array(subs), window: window)
            do {
                let reply = try await chatService.reply(to: q, context: ctx)
                vm.appendAssistant(reply)
            } catch {
                // show the real cause instead of a generic message
                print("Tips service error:", error)
                vm.appendAssistant("Network/auth error: \(error.localizedDescription)")
            }
            vm.pendingUserQuery = nil
        }

    }

    private var header: some View {
        HStack {
            Label("Coach", systemImage: "message.and.waveform")
                .font(.headline)
            Spacer()
            Text(window.start, format: .dateTime.month(.abbreviated).year())
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(12)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask for tips (e.g., How do I save $200 this month?)", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: vm.pendingUserQuery == nil ? "paperplane.fill" : "hourglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.pendingUserQuery != nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, vm.pendingUserQuery == nil else { return }
        vm.appendUser(text)
        vm.pendingUserQuery = text
        draft = ""
    }
}

// MARK: - Optional: small view to save an API key

struct ConnectOpenAIView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tempKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI API Key") {
                    SecureField("sk-...", text: $tempKey)
                        .textFieldStyle(.roundedBorder)
                    Text("Stored in Keychain. You can also set env var OPENAI_API_KEY.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect OpenAI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let k = tempKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { dismiss(); return }
                        do { try OpenAIKey.saveToKeychain(k) } catch { print("Keychain save failed:", error) }
                        dismiss()
                    }
                    .disabled(tempKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}




