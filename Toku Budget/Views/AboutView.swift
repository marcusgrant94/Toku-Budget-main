//
//  AboutView.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/26/25.
//

import SwiftUI


 struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
    private var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                AppIconLarge()
                    .padding(.top, 8)

                Text("Toku Budget \(version)")
                    .font(.headline)
                Text("Build \(build)")
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    LinkRow(title: "Privacy Policy",
                            systemImage: "lock.doc",
                            url: URL(string: "https://www.freeprivacypolicy.com/live/30f9fca1-8a18-4a49-8ba2-1ce1d1b43971")!)
                    LinkRow(title: "Terms and Conditions",
                            systemImage: "doc.text",
                            url: URL(string: "https://marcusgrant94.github.io/toku-budget-faq/terms.html")!)
                }
                .padding(.top, 6)

                Text("By Marcus Grant")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                Text("Thanks to everyone providing feedback and helping improve the app.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("About")
        .closeToolbar { dismiss() }
    }
}

private struct AppIconLarge: View {
    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 72, height: 72)
            .cornerRadius(16)
            .shadow(radius: 4, y: 1)
        #else
        Image(systemName: "app.fill")
            .font(.system(size: 56, weight: .regular))
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.thinMaterial))
        #endif
    }
}

private struct LinkRow: View {
    let title: String
    let systemImage: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                // Inline icon (so we don't depend on LeadingIcon)
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.18))
                    Image(systemName: systemImage)
                        .foregroundStyle(.blue)
                        .font(.system(size: 18, weight: .semibold))
                }
                .frame(width: 40, height: 40)

                Text(title).font(.headline)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08)))
    }
}

