//
//  Untitled.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

import Foundation
import CloudKit

@MainActor
final class CloudUser: ObservableObject {
    @Published var displayName: String = "there"

    private let container = CKContainer.default()
    private let formatter = PersonNameComponentsFormatter()

    init() { Task { await loadName() } }

    private func fallbackName() -> String {
        NSFullUserName().isEmpty
            ? (Host.current().localizedName ?? "there")
            : NSFullUserName()
    }

    func loadName() async {
        do {
            guard try await container.accountStatus() == .available else {
                displayName = fallbackName(); return
            }

            let myID = try await container.userRecordID()

            // On older OSes we still request discoverability permission.
            if #unavailable(macOS 14, iOS 17) {
                _ = try await container.requestApplicationPermission(.userDiscoverability)
            }

            let identity = try await fetchIdentity(for: myID)   // CKUserIdentity?
            if let comps = identity?.nameComponents {
                displayName = formatter.string(from: comps)
                return
            }

            displayName = fallbackName()
        } catch {
            print("[CloudUser] name fetch error:", error)
            displayName = fallbackName()
        }
    }

    // Wrap both APIs, always return optional
    private func fetchIdentity(for id: CKRecord.ID) async throws -> CKUserIdentity? {
        if #available(macOS 14, iOS 17, *) {
            // Some SDKs still type this as optional; treat it as optional either way
            let identity = try await container.userIdentity(forUserRecordID: id)
            return identity
        } else {
            return try await withCheckedThrowingContinuation { cont in
                container.discoverUserIdentity(withUserRecordID: id) { identity, error in
                    if let error = error { cont.resume(throwing: error) }
                    else { cont.resume(returning: identity) }
                }
            }
        }
    }
}



