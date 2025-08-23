//
//  Theme.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/16/25.
//

// Theme.swift
import SwiftUI

enum Theme {
  static let spacing: CGFloat = 16

  // Tunables
  private static let lightBG  = Color(white: 0.98)          // brighter than system
  private static let lightCard = Color.white                // crisp cards in light
  private static let lightBorder = Color.black.opacity(0.05)
  private static let lightShadow = Color.black.opacity(0.08)

  private static let darkBG  = Color(nsColor: .underPageBackgroundColor)
  private static let darkCard = Color(nsColor: .controlBackgroundColor)
  private static let darkBorder = Color.white.opacity(0.06)
  private static let darkShadow = Color.black.opacity(0.25)

  static func bg(_ scheme: ColorScheme) -> Color {
    scheme == .light ? lightBG : darkBG
  }
  static func card(_ scheme: ColorScheme) -> Color {
    scheme == .light ? lightCard : darkCard
  }
  static func cardBorder(_ scheme: ColorScheme) -> Color {
    scheme == .light ? lightBorder : darkBorder
  }
  static func shadow(_ scheme: ColorScheme) -> Color {
    scheme == .light ? lightShadow : darkShadow
  }
}


struct CardModifier: ViewModifier {
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    content
      .padding(16)
      .background(Theme.card(scheme))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder(scheme)))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .shadow(color: Theme.shadow(scheme), radius: 12, y: 4)
  }
}

extension View {
  func card() -> some View { modifier(CardModifier()) }
}

