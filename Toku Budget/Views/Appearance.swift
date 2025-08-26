//
//  Appearance.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

import SwiftUI

// Light/Dark only
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark
    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        }
    }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }
}

// Segmented control without "System"
// – defaults to Light the very first run
// – if a legacy "system" string exists, it is treated as .light
struct AppearancePicker: View {
    @AppStorage("appAppearance") private var raw = AppAppearance.light.rawValue

    private var binding: Binding<AppAppearance> {
        Binding(
            get: {
                // Coerce any legacy value (e.g. "system") to a supported case
                AppAppearance(rawValue: raw) ?? .light
            },
            set: { raw = $0.rawValue }
        )
    }

    var body: some View {
        Picker("Appearance", selection: binding) {
            ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
    }
}

