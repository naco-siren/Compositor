import Foundation
import Testing
import UIKit
@testable import Compositor

/// A tab's project and its file on iPad.
@MainActor struct PadDocumentTests {
    /// A new canvas is written to its file as it's made, so the file is where the project starts, as an opened
    /// project's does: undo doesn't take the tab back to no canvas at all, and a file with nothing left to save.
    @Test func aNewCanvasStartsFromItsFile() async throws {
        let tab = EditorTab()
        tab.session.createNewProject(width: 64, height: 48)
        try await tab.createDocument(named: "PadDocumentTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!tab.session.canUndo)
        tab.session.undo()
        #expect(tab.session.document?.layers.count == 1)
        #expect(!tab.session.isModified)
        await tab.close()
    }
}
