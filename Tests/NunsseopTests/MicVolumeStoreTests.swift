import Foundation
import Testing
@testable import Nunsseop

@MainActor
struct MicVolumeStoreTests {
    @Test func persistsPerDeviceAndClears() throws {
        let scratch = ScratchDefaults("MicVolumeStore")
        let defaults = scratch.defaults
        defer { scratch.remove() }

        #expect(ToolsModel.savedInputVolume(for: "mic-a", defaults: defaults) == nil)
        ToolsModel.setSavedInputVolume(0.6, for: "mic-a", defaults: defaults)
        ToolsModel.setSavedInputVolume(0.25, for: "mic-b", defaults: defaults)
        #expect(ToolsModel.savedInputVolume(for: "mic-a", defaults: defaults) == 0.6)
        #expect(ToolsModel.savedInputVolumes(defaults) == ["mic-a": 0.6, "mic-b": 0.25])

        ToolsModel.setSavedInputVolume(nil, for: "mic-a", defaults: defaults)
        #expect(ToolsModel.savedInputVolume(for: "mic-a", defaults: defaults) == nil)
        #expect(ToolsModel.savedInputVolume(for: "mic-b", defaults: defaults) == 0.25)

        ToolsModel.setSavedInputVolume(nil, for: "mic-b", defaults: defaults)
        #expect(defaults.object(forKey: "savedInputVolumes") == nil)
    }
}
