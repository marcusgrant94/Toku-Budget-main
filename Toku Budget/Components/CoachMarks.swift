//
//  CoachMarks.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/24/25.
//

import SwiftUI

// MARK: - Targets you can point to

enum CoachTarget: Hashable {
    case transactionsAdd
    case budgetsNew
    case budgetsList
    case billsNew
    case billsList
    case overviewRecent
    case overviewBudgets
    case overviewBills
    case overviewSpendBars
    case overviewTips
    case overviewDeleteAll
}

// MARK: - Step + Manager

struct CoachStep: Identifiable, Equatable {
    let id = UUID()
    let key: CoachTarget
    let title: String
    let body: String
}

@MainActor
final class CoachTour: ObservableObject {
    @Published private(set) var steps: [CoachStep] = []
    @Published private(set) var index: Int? = nil

    private let storageKey: String  // e.g. "tour.transactions"

    init(storageKey: String) { self.storageKey = storageKey }

    var current: CoachStep? {
        guard let i = index, steps.indices.contains(i) else { return nil }
        return steps[i]
    }

    func startOnce(_ steps: [CoachStep]) {
        guard !UserDefaults.standard.bool(forKey: storageKey) else { return }
        self.steps = steps
        index = steps.isEmpty ? nil : 0
    }

    func show(_ steps: [CoachStep]) {   // manual replay
        self.steps = steps
        index = steps.isEmpty ? nil : 0
    }

    func next() {
        guard let i = index else { return }
        if i + 1 < steps.count {
            index = i + 1
        } else {
            finish()
        }
    }

    func skip() { finish() }

    private func finish() {
        UserDefaults.standard.set(true, forKey: storageKey)
        index = nil
        steps.removeAll()
    }
}

// MARK: - Anchor collection

private struct CoachAnchorsKey: PreferenceKey {
    static var defaultValue: [CoachTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [CoachTarget: Anchor<CGRect>],
                       nextValue: () -> [CoachTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Mark a view as a target we can point to.
    func coachAnchor(_ key: CoachTarget) -> some View {
        anchorPreference(key: CoachAnchorsKey.self, value: .bounds) { [key: $0] }
    }

    /// Overlay an onboarding “coach mark” flow (observes the `CoachTour`).
    func coachOverlay(_ tour: CoachTour) -> some View {
        overlayPreferenceValue(CoachAnchorsKey.self) { anchors in
            CoachOverlayContainer(tour: tour, anchors: anchors)
        }
    }
}

// MARK: - Overlay container that OBSERVES the tour

private struct CoachOverlayContainer: View {
    @ObservedObject var tour: CoachTour
    let anchors: [CoachTarget: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if let step = tour.current, let a = anchors[step.key] {
                let rect = proxy[a]
                CoachOverlayRect(
                    rect: rect,
                    step: step,
                    onNext: tour.next,
                    onSkip: tour.skip
                )
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: step.id)
            }
        }
    }
}

// MARK: - Visual overlay

private struct CoachOverlayRect: View {
    let rect: CGRect
    let step: CoachStep
    var onNext: () -> Void
    var onSkip: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Dim everything, punch a hole where the target is — tap anywhere to advance
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black)
                        .frame(width: rect.width + 10, height: rect.height + 10)
                        .position(x: rect.midX, y: rect.midY)
                        .blendMode(.destinationOut)
                )
                .compositingGroup()
                .contentShape(Rectangle())
                .onTapGesture { onNext() }

            // Highlight ring
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.75), lineWidth: 2)
                .frame(width: rect.width + 10, height: rect.height + 10)
                .position(x: rect.midX, y: rect.midY)

            // Bubble
            GeometryReader { geo in
                let placeBelow = rect.maxY + 140 < geo.size.height
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.title).font(.headline)
                    Text(step.body).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button("Skip") { onSkip() }
                        Spacer()
                        Button("Next") { onNext() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15))
                )
                .frame(maxWidth: 320)
                .position(
                    x: min(max(rect.midX, 170), geo.size.width - 170),
                    y: placeBelow ? rect.maxY + 80 : max(rect.minY - 80, 80)
                )
            }
        }
        .allowsHitTesting(true)
        .accessibilityAddTraits(.isModal)
    }
}

