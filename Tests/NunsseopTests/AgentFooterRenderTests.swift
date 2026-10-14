import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Nunsseop

/// The Agents tab drawn offscreen with the demo's made-up sessions (never a real terminal).
@MainActor
struct AgentFooterRenderTests {
    private func demoModel(sender: AgentSender) -> AgentsTabModel {
        let board = AgentBoard()
        board.replace(source: "demo", with: AgentBoard.demoAgents())
        let model = AgentsTabModel(board: board, isConnected: { true }, sender: sender, clis: { AgentBoard.demoCLIs }, targets: AgentBoard.demoTargets)
        model.fixed = AgentBoard.demoTranscripts
        model.refresh()
        return model
    }

    private func settled(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(eventDeadline)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func render(_ model: AgentsTabModel, width: CGFloat, height: CGFloat) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AgentsTab(model: model).frame(width: width, height: height).background(Color.black)
            .environment(\.colorScheme, .dark))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// Pixels of the footer's line (the bottom 24 pt) that are the warning orange.
    private func orange(in bitmap: NSBitmapImageRep, footer: CGFloat = 24) -> Int {
        let scale = CGFloat(bitmap.pixelsHigh) / CGFloat(bitmap.size.height)
        let from = bitmap.pixelsHigh - Int(footer * scale)
        var count = 0
        for y in from..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.8, c.greenComponent > 0.4, c.greenComponent < 0.8, c.blueComponent < 0.5 { count += 1 }
            }
        }
        return count
    }

    /// A failed send's note is said in the footer while its row is still selected, even where the hints would not fit beside it.
    @Test func aFailedSendsNoteShowsInTheFooterWhileItsRowIsSelected() async throws {
        let model = demoModel(sender: AgentSender { _ in .failed })
        #expect(await settled { !model.verifying && model.rows.contains { $0.acceptsInput } })
        let row = try #require(model.rows.first { $0.acceptsInput })
        #expect(model.send(message: "hi", to: row))
        #expect(await settled { model.notes[row.id] != nil })
        model.select(row.id)
        for width: CGFloat in [560, 600] {
            let bitmap = try render(model, width: width, height: 165)
            #expect(orange(in: bitmap) > 40, "width \(width)")
        }
        // Without a note the same selection shows only the grey summary and hints.
        let quiet = demoModel(sender: AgentBoard.demoSender)
        #expect(await settled { !quiet.verifying && quiet.rows.contains { $0.acceptsInput } })
        quiet.select(try #require(quiet.rows.first { $0.acceptsInput }).id)
        #expect(orange(in: try render(quiet, width: 560, height: 165)) == 0)
    }
}
