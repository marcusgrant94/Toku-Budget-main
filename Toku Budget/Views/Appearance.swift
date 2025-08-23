//
//  Appearance.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var label: String { ["System","Light","Dark"][self == .system ? 0 : (self == .light ? 1 : 2)] }
}

struct AppearancePicker: View {
    @AppStorage("appAppearance") private var raw = AppAppearance.system.rawValue
    private var binding: Binding<AppAppearance> {
        Binding(get: { AppAppearance(rawValue: raw) ?? .system },
                set: { raw = $0.rawValue })
    }
    var body: some View {
        Picker("Appearance", selection: binding) {
            ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
    }
}
