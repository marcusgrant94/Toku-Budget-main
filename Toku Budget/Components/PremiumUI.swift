//
//  PremiumUI.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/24/25.
//

import SwiftUI

struct PremiumLockedCard<Content: View>: View {
    @EnvironmentObject private var premium: PremiumStore
    @State private var showPaywall = false

    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    init(title: String = "Upgrade to Premium",
         subtitle: String = "Personal financial tips",
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .blur(radius: premium.isPremium ? 0 : 6)

            if !premium.isPremium {
                overlay
                    .transition(.opacity)
                    .onTapGesture { showPaywall = true }
                    .allowsHitTesting(true) // capture taps so content underneath is inert
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(premium)
        }
    }

    private var overlay: some View {
        ZStack {
            // subtle frosted veil on top of the card
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)

            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text(title).bold()
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("See Plans") { showPaywall = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
