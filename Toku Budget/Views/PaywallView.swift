//
//  PaywallView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/22/25.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var store: PremiumStore   // ✅ real env object

    @State private var products: [Product] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isPurchasing = false
    @State private var purchasingID: String?

    // Use your store’s IDs
    private var productIDs: [String] { Array(PremiumStore.ids) }   // ✅ Set → [String]

    private var backgroundGradient: LinearGradient {
        let colors: [Color] = scheme == .dark
        ? [Color.black, Color.black.opacity(0.96)]
        : [Color(white: 0.97), Color(white: 0.99)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()
            VStack(spacing: 22) {
                // Close
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)

                LogoBadge()

                // Headline + subhead
                VStack(spacing: 8) {
                    Text("Unlock Premium Benefits")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("Achieve your budgeting goals without breaking the bank.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                .padding(.top, 2)

                FeaturePanel(features: [
                    "AI-powered budget assistant",
                    "Personalized money-saving tips",
                    "Track unlimited transactions with full history",
                    "Detailed charts and insights into your spending",
                    "Export your data (CSV)",
                    "Exclusive themes & accent colors",
                    "Support ongoing updates & new features"
                ])

                // Plans
                Group {
                    if isLoading {
                        ProgressView("Loading plans…").padding(.top, 8)
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else if products.isEmpty {
                        Text("No plans available right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(sortedProducts(products), id: \.id) { product in
                                Button {
                                    Task { await purchase(product) }
                                } label: {
                                    ZStack(alignment: .trailing) {
                                        PlanOption(
                                            product: product,
                                            isBest: isYearly(product)
                                        )
                                        if isPurchasing && purchasingID == product.id {
                                            ProgressView()
                                                .padding(.trailing, 12)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isPurchasing)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Button("Restore Purchases") { restorePurchases() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                Spacer(minLength: 12)

                Text("By subscribing, you agree to the Terms and Privacy Policy. Cancel anytime.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 540)
        }
        .task { await loadProducts() }
    }

    // MARK: - StoreKit

    @MainActor
    private func loadProducts() async {
        do {
            let fetched = try await Product.products(for: productIDs)
            products = sortedProducts(fetched)
            isLoading = false
        } catch {
            errorMessage = "Failed to load plans: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func restorePurchases() {
        Task {
            do { try await AppStore.sync() }
            catch { errorMessage = "Restore failed: \(error.localizedDescription)" }
            await store.refreshEntitlements()      // ✅ correct API
        }
    }

    @MainActor
    private func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        purchasingID = product.id
        defer { isPurchasing = false; purchasingID = nil }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await store.refreshEntitlements()    // ✅ correct API
                    dismiss()
                case .unverified(_, let err):
                    errorMessage = "Purchase could not be verified: \(err.localizedDescription)"
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Helpers

private func isYearly(_ p: Product) -> Bool {
    if let unit = p.subscription?.subscriptionPeriod.unit, unit == .year { return true }
    return p.id.localizedCaseInsensitiveContains("year")
}

private func sortedProducts(_ list: [Product]) -> [Product] {
    var items = list
    items.sort { (a, b) in
        switch (isYearly(a), isYearly(b)) {
        case (true, false):  return true
        case (false, true):  return false
        default:             return a.displayPrice < b.displayPrice
        }
    }
    return items
}

private func pricePerPeriod(_ product: Product) -> String {
    let price = product.displayPrice
    if let period = product.subscription?.subscriptionPeriod {
        switch period.unit {
        case .day:   return "\(price)/day"
        case .week:  return "\(price)/week"
        case .month: return "\(price)/mo"
        case .year:  return "\(price)/yr"
        @unknown default: return price
        }
    }
    return price
}

// MARK: - Subviews

private struct LogoBadge: View {
    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(width: 180, height: 180)
            .shadow(radius: 2)
            .accessibilityHidden(true)
    }
}

private struct FeaturePanel: View {
    let features: [String]
    private var fillColor: Color { Color.white.opacity(0.08) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(features, id: \.self) { FeatureRow(text: $0) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fillColor))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12)))
        .padding(.horizontal, 4)
    }
}

private struct FeatureRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.accentColor)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PlanOption: View {
    let product: Product
    let isBest: Bool

    private var titleText: String { isYearly(product) ? "Premium Yearly" : "Premium Monthly" }
    private var subtitleText: String { product.displayName }
    private var priceText: String { pricePerPeriod(product) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(titleText).font(.headline)
                    if isBest { BestBadge() }
                }
                Text(subtitleText).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(priceText).font(.title3).bold().monospacedDigit()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08)))
        .contentShape(Rectangle())
    }
}

private struct BestBadge: View {
    var body: some View {
        Text("Best value")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundColor(Color.accentColor)
    }
}









