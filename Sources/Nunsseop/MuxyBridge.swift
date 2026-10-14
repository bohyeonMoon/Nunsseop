import AppKit

/// Muxy 2 has no call from outside to select a tab or open one, so Nunsseop ships a small Muxy extension ("nunsseop-bridge", in
/// `Resources/muxy-bridge`) that the user loads once (Muxy › Settings › Extensions › Load Unpacked…). Nunsseop and the extension talk
/// through the extension's own storage file, `Muxy 2/extension-storage/nunsseop-bridge.json`, which Muxy reads from disk on every call:
/// - `req` (written here): `{id, at, type: "focus", pane}` or `{id, at, type: "resume", folder, project?, command}`; `at` is epoch ms.
/// - `ack` (written by the extension): `{id, ok, error?}` once the request was done or refused.
/// - `alive` (written by the extension every ~5 s): epoch ms, so Nunsseop knows the extension is loaded, enabled and running.
/// The extension is the only writer of `ack` and `alive`, Nunsseop the only writer of `req`; Muxy rewrites the whole file on each of its
/// writes, so a `req` can be lost to one in flight, which is why `send` writes it again until it is acknowledged.
enum MuxyBridge {
    static let name = "nunsseop-bridge"
    /// A heartbeat older than this means the extension is not running.
    static let heartbeatLifetime: TimeInterval = 15

    /// Where everything is. Tests point it at a temporary folder.
    struct Locations: Equatable {
        /// Muxy 2's profile folder.
        var profile: URL
        /// Nunsseop's own folder in Application Support.
        var support: URL

        static var live: Locations {
            Locations(profile: Muxy.profile,
                      support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nunsseop", isDirectory: true))
        }

        var storageFolder: URL { profile.appendingPathComponent("extension-storage", isDirectory: true) }
        var storage: URL { storageFolder.appendingPathComponent("\(MuxyBridge.name).json") }
        /// Muxy lists the folders of the extensions loaded with Load Unpacked here, by name.
        var loadedFolders: URL { profile.appendingPathComponent("extension-folders.json") }
        /// The copy of the extension the user loads: a stable path, outside the app bundle that an update replaces.
        var extensionFolder: URL { support.appendingPathComponent("muxy-bridge", isDirectory: true) }
        /// The fixed script the extension's terminal command runs (see `resumeCommand`).
        var resumeScript: URL { support.appendingPathComponent("muxy-resume.sh") }
        /// Holds `job.sh` while a resume waits to be run by `resumeScript`; the job removes itself and this folder.
        var resumeJobFolder: URL { support.appendingPathComponent("muxy-resume", isDirectory: true) }
    }

    enum Status: Equatable {
        /// Not among the extensions Muxy has loaded.
        case notLoaded
        /// Loaded, but no recent heartbeat: it is off, or Muxy is not running.
        case loaded
        case running
    }

    // MARK: Install

    /// The extension inside the app bundle.
    static var bundled: URL? { Bundle.main.url(forResource: "muxy-bridge", withExtension: nil) }

    /// Makes `folder` hold the files of `source` (the extension is a flat folder), touching only those that differ. False when it can't.
    @discardableResult
    static func install(from source: URL, into folder: URL) -> Bool {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: source.path) else { return false }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in names where !name.hasPrefix(".") {
                let data = try Data(contentsOf: source.appendingPathComponent(name))
                let target = folder.appendingPathComponent(name)
                if (try? Data(contentsOf: target)) != data { try data.write(to: target, options: .atomic) }
            }
            // A file the extension no longer has goes; a folder stays: Muxy keeps the extension's log in `logs/`.
            for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where !names.contains(name) {
                let url = folder.appendingPathComponent(name)
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { try files.removeItem(at: url) }
            }
            return true
        } catch {
            return false
        }
    }

    /// Puts the bundled extension in Nunsseop's folder; nil when there is none (a build run outside an app bundle).
    @discardableResult
    static func installBundled(at locations: Locations = .live) -> URL? {
        guard let bundled, install(from: bundled, into: locations.extensionFolder) else { return nil }
        return locations.extensionFolder
    }

    // MARK: Status

    /// The storage file as a dictionary: [:] when there is none yet, nil when it is there but not an object (half written or foreign).
    static func readStorage(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return FileManager.default.fileExists(atPath: url.path) ? nil : [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func status(_ locations: Locations = .live, now: Date = .now) -> Status {
        if let beat = (readStorage(locations.storage)?["alive"] as? NSNumber)?.doubleValue,
           abs(now.timeIntervalSince1970 - beat / 1000) <= heartbeatLifetime { return .running }
        let loaded = (try? Data(contentsOf: locations.loadedFolders))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?[name] != nil
        return loaded ? .loaded : .notLoaded
    }

    static func isRunning(_ locations: Locations = .live, now: Date = .now) -> Bool { status(locations, now: now) == .running }

    // MARK: Requests

    struct Request: Equatable {
        enum Kind: Equatable {
            case focus(pane: String)
            /// `project` is the id of the Muxy project to open the tab in (none: the current one); `command` is what the new tab runs.
            case resume(folder: String, project: String?, command: String)
        }

        let id: String
        let kind: Kind

        /// An id or a pane as Muxy 2 writes them: a UUID without dashes.
        static func isMuxyID(_ value: String) -> Bool {
            value.utf8.count == 32 && value.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
        }

        /// nil when a part is not what it should be: nothing unchecked is written for the extension to act on.
        static func focus(pane: String, id: String = UUID().uuidString) -> Request? {
            isMuxyID(pane) ? Request(id: id, kind: .focus(pane: pane)) : nil
        }

        static func resume(folder: String, project: String?, command: String, id: String = UUID().uuidString) -> Request? {
            guard Resume.isSafeFolder(folder), project.map(isMuxyID) ?? true, MuxyBridge.isResumeCommand(command) else { return nil }
            return Request(id: id, kind: .resume(folder: folder, project: project, command: command))
        }

        func json(at moment: Date) -> [String: Any] {
            var object: [String: Any] = ["id": id, "at": (moment.timeIntervalSince1970 * 1000).rounded()]
            switch kind {
            case .focus(let pane):
                object["type"] = "focus"
                object["pane"] = pane
            case .resume(let folder, let project, let command):
                object["type"] = "resume"
                object["folder"] = folder
                object["command"] = command
                if let project { object["project"] = project }
            }
            return object
        }
    }

    /// Changes the storage file without touching its other keys, atomically: a temporary file next to it, mode 0600, renamed over it.
    /// False when the folder isn't there (the extension makes it: Nunsseop doesn't, so nothing is written into a Muxy that never ran the
    /// bridge) or the file isn't an object.
    @discardableResult
    static func updateStorage(_ locations: Locations, _ change: (inout [String: Any]) -> Void) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: locations.storageFolder.path, isDirectory: &isFolder), isFolder.boolValue,
              var object = readStorage(locations.storage) else { return false }
        change(&object)
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        let temporary = locations.storageFolder.appendingPathComponent(".nunsseop-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temporary.path, locations.storage.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }

    enum Outcome: Equatable {
        case done
        /// The extension refused or could not do it.
        case failed(String?)
        case timedOut
        /// The bridge is not running, or its storage can't be written.
        case unavailable
    }

    /// Time, so a test can stand in for the extension while `send` waits.
    struct Clock {
        var now: () -> Date
        var sleep: (TimeInterval) -> Void

        static let live = Clock(now: { .now }, sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    /// One request is in `req` at a time: two sends would overwrite each other's until one is acknowledged.
    private static let sending = NSLock()

    /// Writes the request and waits for the extension's `ack`, writing the request again whenever a write of Muxy's took it out of the
    /// file. A send that finds another one in flight waits for it for at most its own `timeout`. Call it off the main thread.
    static func send(_ request: Request, timeout: TimeInterval, at locations: Locations = .live, clock: Clock = .live) -> Outcome {
        guard isRunning(locations, now: clock.now()) else { return .unavailable }
        guard sending.lock(before: Date(timeIntervalSinceNow: timeout)) else { return .timedOut }
        defer { sending.unlock() }
        let deadline = clock.now().addingTimeInterval(timeout)
        while true {
            guard let stored = readStorage(locations.storage) else { return .unavailable }
            if let ack = stored["ack"] as? [String: Any], ack["id"] as? String == request.id {
                return ack["ok"] as? Bool == true ? .done : .failed(ack["error"] as? String)
            }
            if (stored["req"] as? [String: Any])?["id"] as? String != request.id {
                let object = request.json(at: clock.now())
                guard updateStorage(locations, { $0["req"] = object }) else { return .unavailable }
            }
            if clock.now() >= deadline { return .timedOut }
            clock.sleep(0.05)
        }
    }

    // MARK: Resume

    /// The terminal command the extension opens a tab with. It is always the same text, so Muxy's "Allow & Remember" holds for it:
    /// Muxy asks once per exact command.
    static func resumeCommand(_ locations: Locations = .live) -> String? {
        let path = locations.resumeScript.path
        let command = "sh '\(path)'"
        return isResumeCommand(command) && path.hasPrefix("/") ? command : nil
    }

    /// The only command the extension runs: `sh` and a quoted path of a `muxy-resume.sh` in a Nunsseop folder, nothing in the path that
    /// the quotes wouldn't hold in every shell.
    static func isResumeCommand(_ command: String) -> Bool {
        guard command.hasPrefix("sh '/"), command.hasSuffix("/Nunsseop/muxy-resume.sh'") else { return false }
        let path = command.dropFirst("sh '".count).dropLast()
        return !path.unicodeScalars.contains { $0 == "'" || $0 == "\\" || $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    /// What the fixed script runs: the job Nunsseop left, once. The job is Resume's own terminal script (it removes itself and its folder,
    /// then hands the line to the login shell as one argument).
    static let resumeLauncher = """
    #!/bin/sh
    job="$(dirname -- "$0")/muxy-resume/job.sh"
    [ -f "$job" ] || exit 0
    exec sh "$job"

    """

    /// How long a job that nobody ran stays before the next resume replaces it.
    static let jobLifetime: TimeInterval = 120

    /// Leaves the launcher and, in a private folder, the job for `line`. False when a recent job still waits or a file can't be written.
    static func writeJob(line: String, shell: String, at locations: Locations, now: Date = .now) -> Bool {
        let files = FileManager.default
        let folder = locations.resumeJobFolder
        do {
            try files.createDirectory(at: locations.support, withIntermediateDirectories: true)
            if let made = (try? files.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date {
                guard now.timeIntervalSince(made) > jobLifetime else { return false }
                try files.removeItem(at: folder)
            }
            if (try? String(contentsOf: locations.resumeScript, encoding: .utf8)) != resumeLauncher {
                try? files.removeItem(at: locations.resumeScript)
                guard files.createFile(atPath: locations.resumeScript.path, contents: Data(resumeLauncher.utf8), attributes: [.posixPermissions: 0o700]) else { return false }
            }
            try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard files.createFile(atPath: folder.appendingPathComponent("job.sh").path, contents: Data(Resume.terminalScript(line: line, shell: shell).utf8),
                                   attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            return true
        } catch {
            try? files.removeItem(at: folder)
            return false
        }
    }

    /// Brings Muxy to the front, from any thread.
    static let activateMuxy: () -> Void = { DispatchQueue.main.async { TerminalFocus.activate(bundleID: Muxy.bundleID) } }

    /// Opens the conversation in a new Muxy tab through the bridge, in the Muxy project that holds `cwd` when there is one. Waits for
    /// the extension's answer, which comes after the user allowed the command if Muxy asks; call it off the main thread.
    /// - activate: brings Muxy forward before the request (the "Allow & Remember" prompt and a background window can't be seen otherwise)
    ///   and again once it was done.
    static func resume(line: String, cwd: String, shell: String, at locations: Locations = .live, desktop: MuxyDesktop?, clock: Clock = .live,
                       timeout: TimeInterval = 70, activate: () -> Void = activateMuxy) -> Bool {
        guard isRunning(locations, now: clock.now()), let command = resumeCommand(locations),
              let request = Request.resume(folder: cwd, project: desktop?.project(enclosing: cwd)?.id, command: command),
              writeJob(line: line, shell: shell, at: locations, now: clock.now()) else { return false }
        activate()
        if send(request, timeout: timeout, at: locations, clock: clock) == .done {
            activate()
            return true
        }
        try? FileManager.default.removeItem(at: locations.resumeJobFolder)
        return false
    }

    /// Shows the extension's folder in Finder, to pick in Muxy's Load Unpacked…
    static func reveal(at locations: Locations = .live) {
        guard let folder = installBundled(at: locations) ?? (FileManager.default.fileExists(atPath: locations.extensionFolder.path) ? locations.extensionFolder : nil) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// What Nunsseop reads of `Muxy 2/desktop-state.json`: each project's folder and, for each terminal pane, the session in it. Muxy saves it
/// after every change. Session ids are 64-bit and decoded as `UInt64`: a JSON reader that goes through `Double` would round them.
struct MuxyDesktop: Equatable {
    struct Pane: Equatable {
        let id: String
        let tab: String
        let session: UInt64?
    }

    struct Project: Equatable {
        let id: String
        let name: String
        let folder: String
        let home: Bool
        let panes: [Pane]
    }

    var projects: [Project]

    static var stateFile: URL { Muxy.profile.appendingPathComponent("desktop-state.json") }

    static func read(_ url: URL = stateFile) -> MuxyDesktop? { (try? Data(contentsOf: url)).flatMap(parse) }

    static func parse(_ data: Data) -> MuxyDesktop? {
        (try? JSONDecoder().decode(Raw.self, from: data)).map { raw in
            MuxyDesktop(projects: raw.projects.compactMap { project in
                guard let id = project.id else { return nil }
                return Project(id: id, name: project.name ?? "", folder: project.directory?.path ?? "", home: project.home ?? false,
                               panes: (project.tabs ?? []).flatMap { tab in
                                   (tab.panes ?? []).compactMap { pane in pane.id.map { Pane(id: $0, tab: tab.id ?? "", session: pane.content?.session) } }
                               })
            })
        }
    }

    /// The project and the pane that hold a session. A session in no pane (detached) is in none.
    func pane(ofSession session: String) -> (project: Project, pane: Pane)? {
        guard let number = UInt64(session) else { return nil }
        for project in projects {
            if let pane = project.panes.first(where: { $0.session == number }) { return (project, pane) }
        }
        return nil
    }

    /// The project whose folder is `folder` or holds it, the innermost one. Home is not a project to open things in.
    func project(enclosing folder: String) -> Project? {
        let path = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
        return projects.filter { !$0.home && !$0.folder.isEmpty && (path == $0.folder || path.hasPrefix($0.folder.hasSuffix("/") ? $0.folder : $0.folder + "/")) }
            .max { $0.folder.count < $1.folder.count }
    }

    private struct Raw: Decodable {
        struct Folder: Decodable {
            let path: String

            /// Muxy writes a folder as the bytes of its path; a plain string is read too.
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let bytes = try? container.decode([UInt8].self) { path = String(decoding: bytes, as: UTF8.self) } else { path = try container.decode(String.self) }
            }
        }

        struct Content: Decodable {
            let session: UInt64?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                session = (try? container.decodeIfPresent(UInt64.self, forKey: .session)) ?? nil
            }

            enum Keys: String, CodingKey { case session }
        }

        struct PaneEntry: Decodable {
            let id: String?
            let content: Content?
        }

        struct Tab: Decodable {
            let id: String?
            let panes: [PaneEntry]?
        }

        struct ProjectEntry: Decodable {
            let id: String?
            let name: String?
            let directory: Folder?
            let home: Bool?
            let tabs: [Tab]?
        }

        let projects: [ProjectEntry]
    }
}

/// Going to a session in Muxy: its own tab through the bridge when the bridge runs, else its project's folder, which Muxy selects when
/// it is given a folder it already has (`open -a Muxy <folder>`: that selects the project, not a tab).
enum MuxyFocus {
    struct Target: Equatable {
        var pane: String?
        var folder: String?
    }

    /// The tool calls, so a test can run none.
    struct Actions {
        var focusPane: (String) -> Bool
        var openFolder: (String) -> Bool

        static var live: Actions {
            // Muxy comes forward right away, so the click shows at once; the bridge selects the tab while it does.
            Actions(focusPane: { pane in
                guard let request = MuxyBridge.Request.focus(pane: pane) else { return false }
                MuxyBridge.activateMuxy()
                return MuxyBridge.send(request, timeout: 3) == .done
            }, openFolder: { folder in
                guard Resume.isSafeFolder(folder), let app = Muxy.app else { return false }
                return TerminalFocus.run(Resume.openTool, ["-a", app.path, folder], environment: AgentSend.cleanEnvironment) != nil
            })
        }
    }

    /// - fallback: the project's folder as Muxy's activity has it, for a session in no pane of the desktop state (detached, or not saved yet).
    static func target(session: String, in desktop: MuxyDesktop?, fallback: String? = nil) -> Target {
        guard let found = desktop?.pane(ofSession: session) else { return Target(folder: fallback.flatMap { $0.isEmpty ? nil : $0 }) }
        return Target(pane: found.pane.id, folder: found.project.folder.isEmpty ? nil : found.project.folder)
    }

    /// The exact tab when the bridge runs and answers; else the project's folder. False when neither worked.
    static func run(session: String, folder: String? = nil, desktop: MuxyDesktop?, bridgeRunning: Bool, actions: Actions) -> Bool {
        let target = target(session: session, in: desktop, fallback: folder)
        if bridgeRunning, let pane = target.pane, actions.focusPane(pane) { return true }
        return target.folder.map(actions.openFolder) ?? false
    }

    @discardableResult
    static func run(session: String, folder: String? = nil) -> Bool {
        run(session: session, folder: folder, desktop: MuxyDesktop.read(), bridgeRunning: MuxyBridge.isRunning(), actions: .live)
    }
}
