//
//  Untitled.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/17/25.
//

import CoreData

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "TokuBudget")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        // 🔗 Force this store to use your CK container
        let desc = container.persistentStoreDescriptions.first!
        desc.cloudKitContainerOptions = .init(containerIdentifier: "iCloud.random.Toku-Budget")
        print("[CK] bundle:", Bundle.main.bundleIdentifier ?? "nil")
        print("[CK] container in store desc:", desc.cloudKitContainerOptions?.containerIdentifier ?? "nil")

        container.loadPersistentStores { _, error in
            if let error = error { fatalError("CloudKit store load error: \(error)") }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}

