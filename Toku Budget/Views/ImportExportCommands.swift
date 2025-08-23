//
//  ImportExportCommands.swift
//  Toku Budget
//
//  Created by Marcus Grant on 8/18/25.
//

import SwiftUI
import CoreData
import AppKit

struct ImportExportCommands: Commands {
    @Environment(\.managedObjectContext) private var moc

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import CSV…") { ImportCoordinator.presentImporter(moc) }
                .keyboardShortcut("i", modifiers: [.command])
            Button("Export CSV…") { ExportCoordinator.presentExporter(moc) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
