import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct ToolsDrivesTests {
    @Test func theDrivesAreWhatTheSourceMountsAtTheTimeOfTheRefresh() {
        var mounted = [ToolsModel.Drive(id: URL(fileURLWithPath: "/Volumes/Backup"), name: "Backup")]
        let tools = ToolsModel(mountedDrives: { mounted })
        #expect(tools.drives.isEmpty)
        tools.refreshDrives()
        #expect(tools.drives.map(\.name) == ["Backup"])
        mounted = []
        tools.refreshDrives()
        #expect(tools.drives.isEmpty)
    }
}
