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

// MARK: - Worker URL + model helper
enum CoachWorker {
    static func baseURL() -> URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "CoachWorkerURL") as? String,
           !s.isEmpty, let u = URL(string: s) { return u }
        // Fallback to your workers.dev URL
        return URL(string: "https://toku-coach.tokubudget.workers.dev")
    }
    static func model() -> String {
        if let s = Bundle.main.object(forInfoDictionaryKey: "CoachWorkerModel") as? String,
           !s.isEmpty { return s }
        return "gpt-5-mini" // safe default
    }
}

// MARK: - Chat service protocol + environment
protocol TipsChatService {
    func reply(to userMessage: String, context: TipsContext) async throws -> String
}
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
    let savingsGoalTotal: Double?

    static func make(from txs: [Transaction],
                     budgets: [Budget],
                     subs: [Subscription],
                     window: DateWindow) -> TipsContext
    {
        let currency = txs.first?.currencyCode ?? "USD"
        let expenses = txs.filter { $0.kind == TxKind.expense.rawValue }

        let totalSpent = expenses
            .map { ($0.amount?.decimalValue ?? 0) as NSDecimalNumber }
            .map(\.doubleValue)
            .reduce(0, +)

        var catMap: [String: Double] = [:]
        for t in expenses {
            let name = (t.category?.name?.isEmpty == false) ? (t.category!.name!) : "—"
            let v = (t.amount?.decimalValue ?? 0) as NSDecimalNumber
            catMap[name, default: 0] += v.doubleValue
        }
        let perCategory = catMap.map { (k, v) in (name: k, spent: v) }
            .sorted { $0.spent > $1.spent }

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

        // Savings goal (ceil months so partial months count as a whole)
        let store = SavingsGoalStore()
        let goal = store.read()
        var perMonth: Double? = nil
        var deadline: Date? = nil
        var total: Double? = nil
        if let g = goal {
            deadline = g.targetDate
            total = (g.amount as NSDecimalNumber).doubleValue

            var comps = cal.dateComponents([.month, .day], from: Date(), to: g.targetDate)
            let monthsFloor = comps.month ?? 0
            let monthsCeil = monthsFloor + ((comps.day ?? 0) > 0 ? 1 : 0)
            let months = max(1, monthsCeil)
            perMonth = total! / Double(months)
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
            savingsGoalDeadline: deadline,
            savingsGoalTotal: total
        )
    }
}

// MARK: - Worker-backed service (no secrets in the app)
struct WorkerTipsService: TipsChatService {
    func reply(to userMessage: String, context c: TipsContext) async throws -> String {
        let prompt = buildPrompt(userMessage: userMessage, ctx: c)

        guard let base = CoachWorker.baseURL() else {
            throw NSError(domain: "Worker", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Worker URL"])
        }

        var req = URLRequest(url: base, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // ✅ Include model; ❌ omit temperature
        struct ReqBody: Encodable { let model: String; let input: String }
        req.httpBody = try JSONEncoder().encode(ReqBody(model: CoachWorker.model(), input: prompt))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let txt = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Worker", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Worker error: \(txt)"])
        }

        // Try common response shapes
        struct Resp: Decodable {
            let output_text: String?
            let output: [Out]?
            struct Out: Decodable { let content: [Content]? }
            struct Content: Decodable { let type: String?; let text: String? }
        }
        if let decoded = try? JSONDecoder().decode(Resp.self, from: data) {
            if let t = decoded.output_text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
            if let outs = decoded.output {
                for item in outs {
                    if let piece = item.content?.first(where: { (($0.text ?? "").isEmpty == false) }),
                       let t = piece.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty { return t }
                }
            }
        }
        return String(data: data, encoding: .utf8) ?? "I didn’t get a text reply back."
    }

    // Compact, friendly prompt with goal total + monthly
    private func buildPrompt(userMessage: String, ctx c: TipsContext) -> String {
        let q = userMessage.lowercased()
        let isSavingsQ = q.contains("save") || q.contains("cut") || q.contains("reduce") || q.contains("$") || q.contains("¥")

        var lines: [String] = []
        lines.append("You are a budgeting assistant. Be practical and concise.")
        lines.append("Currency: \(c.currency)")
        lines.append("Window: \(c.window.start) to \(c.window.end)")
        lines.append("Total spent: \(Int(c.totalSpent))")

        if !c.perCategory.isEmpty {
            lines.append("Per-category spent (top 8):")
            for (i, row) in c.perCategory.prefix(8).enumerated() {
                lines.append("\(i+1). \(row.name): \(Int(row.spent))")
            }
        }
        if !c.overspent.isEmpty {
            lines.append("Overspent vs budget:")
            for o in c.overspent { lines.append("- \(o.name): spent \(Int(o.spent)) / budget \(Int(o.budget))") }
        }

        // ✅ Include concrete subscription names/dates/amounts for the next 45 days
        if !c.upcomingBills.isEmpty {
            lines.append("Upcoming subscriptions/bills in next 45 days:")
            for item in c.upcomingBills.prefix(20) {
                let amt = Int(item.amount.rounded())
                let due = item.due.formatted(.dateTime.month(.abbreviated).day())
                lines.append("- \(item.name): \(amt) due \(due)")
            }
        }

        if c.subsMonthlyTotal > 0 {
            lines.append("Subscriptions monthly total (equivalent): \(Int(c.subsMonthlyTotal))")
        }

        if let m = c.savingsGoalPerMonth, let d = c.savingsGoalDeadline {
            lines.append("Savings goal: needs \(Int(m)) per month until \(d).")
        }

        lines.append("User question: \(userMessage)")
        lines.append("Use ONLY the data above when listing subscriptions/bills; do not say you lack access.")

        if !isSavingsQ {
            lines.append("""
            MODE: general_advice
            OUTPUT:
            - Reply ONLY with 3–5 concise bullets that directly answer the question.
            - Use subscription/bill details above (names, dates, amounts) when relevant.
            - Do NOT invent dollar amounts not present above.
            - Keep each bullet ≤ 14 words.
            """)
            return lines.joined(separator: "\n")
        }

        let target = Int((c.savingsGoalPerMonth ?? (c.totalSpent * 0.05)).rounded())
        lines.append("Target monthly savings (upper bound): \(target)")

        var caps: [(String, Int)] = []
        for row in c.perCategory.prefix(8) {
            let over = c.overspent.first(where: { $0.name == row.name }).map { max(0, $0.spent - $0.budget) } ?? 0
            let pctCap = row.spent * 0.15
            let cap = max(5.0, min(pctCap, over > 0 ? over : pctCap))
            caps.append((row.name, Int(cap.rounded())))
        }
        if !caps.isEmpty {
            lines.append("Per-category max cuts:")
            for (name, cap) in caps { lines.append("- \(name): \(cap)") }
        }
        if c.subsMonthlyTotal > 0 {
            lines.append("Subscriptions max suggestion: up to \(Int(c.subsMonthlyTotal)) total this month.")
        }

        lines.append("""
        OUTPUT RULES:
        - Respond ONLY with a short Markdown list (no headings/intro/outro).
        - Make 3–5 bullets. Each bullet ≤ 12 words.
        - Each bullet must follow: "• Save <amount>/mo by <action> (<category or source>)".
        - Sum of amounts must be ≤ \(target).
        - Per-category amounts must not exceed the listed max cuts.
        - When asked about subscriptions/bills, list the items above with name + date + amount.
        - Finish with: "**Total: <amount>/mo**".
        """)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Smart wrapper (Worker → direct OpenAI; no local rules)
struct SmartTipsService: TipsChatService {
    func reply(to userMessage: String, context: TipsContext) async throws -> String {
        if CoachWorker.baseURL() != nil {
            do { return try await WorkerTipsService().reply(to: userMessage, context: context) }
            catch { print("Worker failed:", error) }
        }
        if let key = OpenAIKey.defaultProvider(), !key.isEmpty {
            return try await OpenAITipsService(apiKey: key).reply(to: userMessage, context: context)
        }
        throw NSError(domain: "SmartTips", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "No Worker or OpenAI key configured."])
    }
}

// MARK: - Direct OpenAI fallback (omit temperature)
struct OpenAITipsService: TipsChatService {
    let apiKey: String

    func reply(to userMessage: String, context c: TipsContext) async throws -> String {
        let (system, user) = buildMessages(userMessage: userMessage, ctx: c)

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host   = "api.openai.com"
        comps.path   = "/v1/chat/completions"
        guard let url = comps.url else {
            throw NSError(domain: "OpenAI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Msg: Encodable { let role: String; let content: String }
        struct ChatReq: Encodable {
            let model: String
            let messages: [Msg]
        }
        let body = ChatReq(
            model: "gpt-5-mini",
            messages: [ Msg(role: "system", content: system),
                        Msg(role: "user",   content: user) ]
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "OpenAI", code: -3, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard http.statusCode == 200 else {
            let txt = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenAI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(txt)"])
        }

        struct ChatResp: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]
        }
        if let decoded = try? JSONDecoder().decode(ChatResp.self, from: data),
           let t = decoded.choices.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty { return t }

        let raw = String(data: data, encoding: .utf8) ?? "(binary)"
        print("OpenAI raw chat response:\n\(raw)")
        return "I didn’t get a text reply back. (See console for raw response.)"
    }

    private func buildMessages(userMessage: String, ctx c: TipsContext) -> (system: String, user: String) {
        let q = userMessage.lowercased()
        let isSavingsQ = q.contains("save") || q.contains("cut") || q.contains("reduce") || q.contains("$") || q.contains("¥")

        var userLines: [String] = []
        userLines.append("Currency: \(c.currency)")
        userLines.append("Window: \(c.window.start) to \(c.window.end)")
        userLines.append("Total spent: \(Int(c.totalSpent))")
        if !c.perCategory.isEmpty {
            userLines.append("Top categories:")
            for (i, row) in c.perCategory.prefix(8).enumerated() {
                userLines.append("\(i+1). \(row.name): \(Int(row.spent))")
            }
        }
        if !c.overspent.isEmpty {
            userLines.append("Overspent vs budget:")
            for o in c.overspent {
                userLines.append("- \(o.name): spent \(Int(o.spent)) / budget \(Int(o.budget))")
            }
        }
        if !c.upcomingBills.isEmpty {
            userLines.append("Upcoming subscriptions/bills in next 45 days:")
            for item in c.upcomingBills.prefix(20) {
                let amt = Int(item.amount.rounded())
                let due = item.due.formatted(.dateTime.month(.abbreviated).day())
                userLines.append("- \(item.name): \(amt) due \(due)")
            }
        }
        if c.subsMonthlyTotal > 0 { userLines.append("Subscriptions monthly total: \(Int(c.subsMonthlyTotal))") }
        if let total = c.savingsGoalTotal { userLines.append("Savings goal total: \(Int(total)).") }
        if let m = c.savingsGoalPerMonth, let d = c.savingsGoalDeadline {
            userLines.append("Savings goal monthly needed: \(Int(m)) until \(d).")
        }
        userLines.append("User question: \(userMessage)")

        let system: String
        if !isSavingsQ {
            system =
            """
            You are a budgeting assistant. Be practical and concise.

            OUTPUT:
            - Reply ONLY with 3–5 concise bullets that directly answer the question.
            - Do NOT invent dollar amounts.
            - Keep each bullet ≤ 14 words.
            - When asked about subscriptions/bills, list the provided items (name, due date, amount).
            """
        } else {
            let target = Int((c.savingsGoalPerMonth ?? (c.totalSpent * 0.05)).rounded())
            var caps: [(String, Int)] = []
            for row in c.perCategory.prefix(8) {
                let over = c.overspent.first(where: { $0.name == row.name }).map { max(0, $0.spent - $0.budget) } ?? 0
                let pctCap = row.spent * 0.15
                let cap = max(5.0, min(pctCap, over > 0 ? over : pctCap))
                caps.append((row.name, Int(cap.rounded())))
            }
            var rules = """
            You are a budgeting assistant. Be practical and concise.

            Target monthly savings (upper bound): \(target)
            """
            if !caps.isEmpty {
                rules += "\nPer-category max cuts:\n"
                for (n, cap) in caps { rules += "- \(n): \(cap)\n" }
            }
            rules +=
            """
            OUTPUT:
            - Respond ONLY with a short Markdown list (no headings/intro/outro).
            - Make 3–5 bullets. Each bullet ≤ 12 words.
            - Each bullet must follow: "• Save <amount>/mo by <action> (<category or source>)".
            - Sum of amounts must be ≤ \(target).
            - Per-category amounts must not exceed the listed max cuts.
            - If asked about the savings goal, restate goal total and monthly needed first.
            - Finish with: "**Total: <amount>/mo**".
            """
            system = rules
        }

        return (system: system, user: userLines.joined(separator: "\n"))
    }
}

// MARK: - Optional key management (only for dev fallback)
enum OpenAIKey {
    static func defaultProvider() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
        if let v = try? Keychain.shared.get("openai.api.key"), !v.isEmpty { return v }
        if let v = UserDefaults.standard.string(forKey: "openai.api.key"), !v.isEmpty { return v }
        return nil
    }
    static func saveToKeychain(_ key: String) throws {
        try Keychain.shared.set(key, for: "openai.api.key")
        UserDefaults.standard.set(key, forKey: "openai.api.key")
    }
}
final class Keychain {
    static let shared = Keychain()
    enum KCError: Error { case notFound, unhandled(OSStatus) }
    func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KCError.unhandled(status) }
    }
    func get(_ key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { throw KCError.notFound }
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
    @Published var awaitingPrice: Bool = false
    var lastGoalQuery: String?
    func appendUser(_ t: String)      { messages.append(.init(role: .user,      text: t)) }
    func appendAssistant(_ t: String)  { messages.append(.init(role: .assistant, text: t)) }
    func appendSystem(_ t: String)     { messages.append(.init(role: .system,    text: t)) }
}

private struct ChatBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack {
            if message.role == .assistant || message.role == .system {
                bubble(alignment: .leading, isUser: false); Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40); bubble(alignment: .trailing, isUser: true)
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

            // Render Markdown nicely
            let attr: AttributedString = (try? AttributedString(
                markdown: message.text,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .full
                )
            )) ?? AttributedString(message.text)

            Text(attr)
                .font(.callout)
                .textSelection(.enabled)
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
    @EnvironmentObject private var vm: ChatVM
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.tipsChatService) private var chatService

    @FetchRequest private var txs: FetchedResults<Transaction>
    @FetchRequest private var budgets: FetchedResults<Budget>
    @FetchRequest private var subs: FetchedResults<Subscription>

    @State private var draft = ""
    @State private var isThinking = false

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
                        if isThinking {
                            TypingIndicatorBubble().id("typing")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: vm.messages.count) { _ in
                    if let id = vm.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
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
            // Capture once; avoid re-entrancy weirdness
            let query = vm.pendingUserQuery
            guard let q = query, !q.isEmpty else { return }

            isThinking = true
            defer {
                isThinking = false
                vm.pendingUserQuery = nil
            }

            let ctx = TipsContext.make(from: Array(txs), budgets: Array(budgets), subs: Array(subs), window: window)

            // Ask for target price if needed (no spinner gets stuck thanks to defer)
            if vm.awaitingPrice == false, needsPriceQuestion(q) {
                vm.lastGoalQuery = q
                vm.awaitingPrice = true
                vm.appendAssistant("To plan precisely, what's your **target out-the-door price** where you live? (e.g., **$45,000**)")
                return
            }

            // Parse the price response, then continue
            if vm.awaitingPrice == true {
                if let (value, currency) = extractPrice(q) {
                    let merged = (vm.lastGoalQuery ?? "I want to save for a purchase.") + "\nTarget price: \(Int(value)) \(currency)"
                    vm.awaitingPrice = false
                    vm.lastGoalQuery = nil
                    do {
                        let reply = try await chatService.reply(to: merged, context: ctx)
                        vm.appendAssistant(reply)
                    } catch {
                        print("Tips service error:", error)
                        vm.appendAssistant("Tips are unavailable right now.")
                    }
                } else {
                    vm.appendAssistant("Please reply with an amount like **$45,000**.")
                }
                return
            }

            // Normal path
            do {
                let reply = try await chatService.reply(to: q, context: ctx)
                vm.appendAssistant(reply)
            } catch {
                print("Tips service error:", error)
                vm.appendAssistant("Tips are unavailable right now.")
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Coach", systemImage: "message.and.waveform").font(.headline)
            Spacer()
            Text(window.start, format: .dateTime.month(.abbreviated).year())
                .foregroundStyle(.secondary).font(.caption)
        }
        .padding(12)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask for tips (e.g., How do I save $200 this month?)",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)

            Button(action: send) {
                if isThinking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isThinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isThinking, vm.pendingUserQuery == nil, !text.isEmpty else { return }
        vm.appendUser(text)
        vm.pendingUserQuery = text
        draft = ""
    }

    private struct TypingIndicatorBubble: View {
        var body: some View {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thinking…")
                        .font(.callout)
                    ProgressView()
                        .controlSize(.small)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12))
                )
                Spacer(minLength: 40)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Assistant is thinking")
        }
    }

    private func needsPriceQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let purchaseTriggers = ["buy", "purchase", "get", "afford", "save for", "down payment", "downpayment", "deposit"]
        let mentionsPurchase = purchaseTriggers.contains { lower.contains($0) }
        return mentionsPurchase && (extractPrice(text) == nil)
    }

    private func extractPrice(_ text: String) -> (value: Double, currency: String)? {
        // symbol-first: $45,000  €42000  £1,299  ¥5,000
        let sym = try! NSRegularExpression(pattern: #"([\$\€\£\¥])\s*([0-9][0-9,\.]{1,})"#)
        if let m = sym.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let symRange = Range(m.range(at: 1), in: text)!
            let numRange = Range(m.range(at: 2), in: text)!
            let symbol = String(text[symRange])
            let raw = String(text[numRange]).replacingOccurrences(of: ",", with: "")
            if let v = Double(raw) {
                let code: String = (symbol == "$") ? "USD"
                    : (symbol == "€") ? "EUR"
                    : (symbol == "£") ? "GBP"
                    : (symbol == "¥") ? "JPY" : "USD"
                return (v, code)
            }
        }
        // code-first: USD 45000, EUR 42,000, GBP 1299, JPY 5000000
        let code = try! NSRegularExpression(pattern: #"\b(USD|EUR|GBP|JPY|AUD|CAD)\s*([0-9][0-9,\.]{1,})\b"#, options: [.caseInsensitive])
        if let m = code.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let cRange = Range(m.range(at: 1), in: text)!
            let nRange = Range(m.range(at: 2), in: text)!
            let cur  = String(text[cRange]).uppercased()
            let raw  = String(text[nRange]).replacingOccurrences(of: ",", with: "")
            if let v = Double(raw) { return (v, cur) }
        }
        return nil
    }
}










