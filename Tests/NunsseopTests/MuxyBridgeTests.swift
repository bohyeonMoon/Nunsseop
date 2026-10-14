import Foundation
import Testing
@testable import Nunsseop

private let big = "1978299613479001934"
private let biggest = "18446744073709551615"
private let pane = "cbcef15ca9e243c3a6d39e003bf194e5"
private let tab = "8f074f0d13c34a0fbd206cd8bf291bfc"
private let dev = "aa2932bc99a44172845b99e03f715c77"
private let home = "e195adbf56564d6d8fc6962ab22542cb"
private let other = "0123456789abcdef0123456789abcdef"
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// A made-up machine: Muxy 2's profile and Nunsseop's folder in a scratch folder (named so that the launcher's path ends as the real
/// one does, `/Nunsseop/muxy-resume.sh`, and with a space in it, as `Application Support` has).
private final class Machine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nunsseop-muxy-\(UUID().uuidString.prefix(8))/Application Support", isDirectory: true)
    let files = FileManager.default
    var locations: MuxyBridge.Locations {
        MuxyBridge.Locations(profile: root.appendingPathComponent("Muxy 2", isDirectory: true), support: root.appendingPathComponent("Nunsseop", isDirectory: true))
    }

    init(storageFolder: Bool = true) {
        try? files.createDirectory(at: locations.profile, withIntermediateDirectories: true)
        if storageFolder { try? files.createDirectory(at: locations.storageFolder, withIntermediateDirectories: true) }
    }

    deinit { try? files.removeItem(at: root.deletingLastPathComponent()) }

    func store(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: locations.storage)
    }

    var stored: [String: Any] { (try? Data(contentsOf: locations.storage)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }

    /// The extension's heartbeat, `age` seconds before `epoch`.
    func beat(age: TimeInterval = 1) throws {
        var object = stored
        object["alive"] = (epoch.timeIntervalSince1970 - age) * 1000
        try store(object)
    }

    func registerLoaded() throws {
        try JSONSerialization.data(withJSONObject: [MuxyBridge.name: "/somewhere"]).write(to: locations.loadedFolders)
    }

    func mode(_ url: URL) -> Int? { (try? files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue }
}

/// Time that only moves when something sleeps, and what the "extension" does then.
private final class Time {
    var now = epoch
    var sleeps = 0
    var onSleep: (Int) -> Void = { _ in }
    var clock: MuxyBridge.Clock {
        MuxyBridge.Clock(now: { self.now }, sleep: { seconds in
            self.sleeps += 1
            self.now = self.now.addingTimeInterval(seconds)
            self.onSleep(self.sleeps)
        })
    }
}

struct MuxyBridgeStatusTests {
    @Test func notLoadedThenLoadedThenRunningByTheHeartbeat() throws {
        let machine = Machine()
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .notLoaded)
        try machine.registerLoaded()
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .loaded)
        try machine.beat(age: 2)
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .running && MuxyBridge.isRunning(machine.locations, now: epoch))
    }

    @Test func aHeartbeatThatStoppedMeansItIsNotRunning() throws {
        let machine = Machine()
        try machine.registerLoaded()
        try machine.beat(age: 16)
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .loaded)
        try machine.beat(age: 14)
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .running)
        // A heartbeat from the far future is no heartbeat either.
        try machine.beat(age: -3600)
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .loaded)
    }

    @Test func aHeartbeatAloneCountsEvenIfMuxyListsNoFolders() throws {
        let machine = Machine()
        try machine.beat()
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .running)
    }

    @Test func garbageInTheFilesIsNotLoadedAndNotRunning() throws {
        let machine = Machine()
        try Data("{".utf8).write(to: machine.locations.storage)
        try Data("[1]".utf8).write(to: machine.locations.loadedFolders)
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .notLoaded)
        try Data(#"{"alive":"soon"}"#.utf8).write(to: machine.locations.storage)
        #expect(MuxyBridge.status(machine.locations, now: epoch) == .notLoaded)
    }
}

struct MuxyBridgeInstallTests {
    @Test func theExtensionFolderIsCopiedAndOnlyChangedFilesAreWritten() throws {
        let machine = Machine()
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/muxy-bridge")
        let folder = machine.locations.extensionFolder
        #expect(MuxyBridge.install(from: resources, into: folder))
        for name in ["package.json", "background.js", "helper.html", "helper.js"] {
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == Data(contentsOf: resources.appendingPathComponent(name)), Comment(rawValue: name))
        }
        // Muxy keeps the extension's log in a folder of its own inside: it stays, and a file that is no longer shipped goes.
        let log = folder.appendingPathComponent("logs/output.log")
        try machine.files.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("log".utf8).write(to: log)
        try Data("old".utf8).write(to: folder.appendingPathComponent("retired.js"))
        try Data("edited".utf8).write(to: folder.appendingPathComponent("helper.js"))
        let untouched = try machine.files.attributesOfItem(atPath: folder.appendingPathComponent("background.js").path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        #expect(MuxyBridge.install(from: resources, into: folder))
        #expect(try Data(contentsOf: folder.appendingPathComponent("helper.js")) == Data(contentsOf: resources.appendingPathComponent("helper.js")))
        #expect(!machine.files.fileExists(atPath: folder.appendingPathComponent("retired.js").path) && machine.files.fileExists(atPath: log.path))
        #expect(try machine.files.attributesOfItem(atPath: folder.appendingPathComponent("background.js").path)[.modificationDate] as? Date == untouched)
    }

    @Test func aSourceThatIsNotThereInstallsNothing() {
        let machine = Machine()
        #expect(!MuxyBridge.install(from: machine.root.appendingPathComponent("nope"), into: machine.locations.extensionFolder))
        #expect(!machine.files.fileExists(atPath: machine.locations.extensionFolder.path))
    }

    @Test func theShippedManifestIsTheOneMuxyLoads() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/muxy-bridge")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("package.json"))) as? [String: Any])
        #expect(manifest["name"] as? String == MuxyBridge.name)
        let muxy = try #require(manifest["muxy"] as? [String: Any])
        #expect(Set(muxy["permissions"] as? [String] ?? []) == ["storage:read", "storage:write", "tabs:write", "projects:write"])
        #expect(muxy["background"] as? String == "background.js")
        for name in ["background.js", "helper.html", "helper.js"] {
            #expect(FileManager.default.fileExists(atPath: resources.appendingPathComponent(name).path), Comment(rawValue: name))
        }
    }
}

struct MuxyBridgeStorageTests {
    @Test func aWriteKeepsTheOtherKeysAndLeavesAPrivateFileAndNoTemporaryOne() throws {
        let machine = Machine()
        try machine.store(["alive": 123.0, "ack": ["id": "x", "ok": true]])
        #expect(MuxyBridge.updateStorage(machine.locations) { $0["req"] = ["id": "r1"] })
        let stored = machine.stored
        #expect(stored["alive"] as? Double == 123 && (stored["ack"] as? [String: Any])?["id"] as? String == "x" && (stored["req"] as? [String: Any])?["id"] as? String == "r1")
        #expect(machine.mode(machine.locations.storage) == 0o600)
        #expect(try machine.files.contentsOfDirectory(atPath: machine.locations.storageFolder.path) == ["nunsseop-bridge.json"])
    }

    @Test func aMissingFileIsCreatedButAMissingFolderIsNot() throws {
        let machine = Machine()
        #expect(MuxyBridge.updateStorage(machine.locations) { $0["req"] = ["id": "r1"] })
        #expect(machine.mode(machine.locations.storage) == 0o600)
        let bare = Machine(storageFolder: false)
        #expect(!MuxyBridge.updateStorage(bare.locations) { $0["req"] = 1 })
        #expect(!bare.files.fileExists(atPath: bare.locations.storageFolder.path))
    }

    @Test func aFileThatIsNotAnObjectIsLeftAlone() throws {
        let machine = Machine()
        try Data("[1,2".utf8).write(to: machine.locations.storage)
        #expect(!MuxyBridge.updateStorage(machine.locations) { $0["req"] = 1 })
        #expect(try String(contentsOf: machine.locations.storage, encoding: .utf8) == "[1,2")
    }

    @Test func requestsCarryOnlyCheckedParts() throws {
        #expect(MuxyBridge.Request.focus(pane: pane) != nil)
        for bad in ["", "abc", pane + "0", pane.uppercased(), "../" + String(pane.dropFirst(3)), pane.dropLast() + "'", "1978299613479001934"] {
            #expect(MuxyBridge.Request.focus(pane: String(bad)) == nil, Comment(rawValue: String(bad)))
        }
        let command = try #require(MuxyBridge.resumeCommand(Machine().locations))
        #expect(MuxyBridge.Request.resume(folder: "/Users/me/dev", project: dev, command: command) != nil)
        #expect(MuxyBridge.Request.resume(folder: "/Users/me/dev", project: nil, command: command) != nil)
        #expect(MuxyBridge.Request.resume(folder: "relative", project: nil, command: command) == nil)
        #expect(MuxyBridge.Request.resume(folder: "/a\nb", project: nil, command: command) == nil)
        #expect(MuxyBridge.Request.resume(folder: "/a", project: "nope", command: command) == nil)
        #expect(MuxyBridge.Request.resume(folder: "/a", project: nil, command: "rm -rf /") == nil)
        #expect(MuxyBridge.Request.resume(folder: "/a", project: nil, command: command + "; id") == nil)
    }

    @Test func theRequestsAreWrittenAsTheExtensionReadsThem() throws {
        let focus = try #require(MuxyBridge.Request.focus(pane: pane, id: "r1")).json(at: epoch)
        #expect(focus["id"] as? String == "r1" && focus["type"] as? String == "focus" && focus["pane"] as? String == pane)
        #expect(focus["at"] as? Double == 1_800_000_000_000)
        let machine = Machine()
        let command = try #require(MuxyBridge.resumeCommand(machine.locations))
        let resume = try #require(MuxyBridge.Request.resume(folder: "/Users/me/my dev", project: dev, command: command, id: "r2")).json(at: epoch)
        #expect(resume["type"] as? String == "resume" && resume["folder"] as? String == "/Users/me/my dev" && resume["project"] as? String == dev && resume["command"] as? String == command)
        #expect(try #require(MuxyBridge.Request.resume(folder: "/a", project: nil, command: command)).json(at: epoch)["project"] == nil)
    }
}

struct MuxyBridgeSendTests {
    private func request(_ id: String = "r1") throws -> MuxyBridge.Request { try #require(MuxyBridge.Request.focus(pane: pane, id: id)) }

    @Test func theRequestIsWrittenAndTheExtensionsAckEndsTheWait() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        time.onSleep = { _ in
            var stored = machine.stored
            #expect((stored["req"] as? [String: Any])?["id"] as? String == "r1")
            stored["ack"] = ["id": "r1", "ok": true]
            try? machine.store(stored)
        }
        #expect(try MuxyBridge.send(request(), timeout: 4, at: machine.locations, clock: time.clock) == .done)
        #expect(time.sleeps == 1)
    }

    @Test func aRefusalComesBackWithItsMessage() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        time.onSleep = { _ in
            var stored = machine.stored
            stored["ack"] = ["id": "r1", "ok": false, "error": "tab not found x"]
            try? machine.store(stored)
        }
        #expect(try MuxyBridge.send(request(), timeout: 4, at: machine.locations, clock: time.clock) == .failed("tab not found x"))
    }

    @Test func anAckOfAnOlderRequestIsNotTheAnswer() throws {
        let machine = Machine()
        try machine.store(["alive": (epoch.timeIntervalSince1970 - 1) * 1000, "ack": ["id": "old", "ok": true]])
        let time = Time()
        #expect(try MuxyBridge.send(request(), timeout: 1, at: machine.locations, clock: time.clock) == .timedOut)
        #expect(time.sleeps >= 4)
    }

    @Test func aRequestThatAWriteOfMuxysTookOutIsWrittenAgain() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        time.onSleep = { count in
            var stored = machine.stored
            if count == 1 {
                // Muxy wrote the file from what it read before the request came.
                stored["req"] = nil
            } else {
                #expect((stored["req"] as? [String: Any])?["id"] as? String == "r1")
                stored["ack"] = ["id": "r1", "ok": true]
            }
            try? machine.store(stored)
        }
        #expect(try MuxyBridge.send(request(), timeout: 4, at: machine.locations, clock: time.clock) == .done)
        #expect(time.sleeps == 2)
    }

    @Test func aSendWhileAnotherIsInFlightWaitsOnlyAsLongAsItsOwnTimeoutAndWritesNothing() throws {
        let machine = Machine()
        try machine.beat()
        let other = Machine()
        try other.beat()
        let time = Time()
        var second: MuxyBridge.Outcome?
        time.onSleep = { _ in
            // The first request is in the file and unanswered; a second one comes from another thread.
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                second = try? MuxyBridge.send(self.request("r2"), timeout: 0.2, at: other.locations, clock: Time().clock)
                done.signal()
            }
            done.wait()
            var stored = machine.stored
            stored["ack"] = ["id": "r1", "ok": true]
            try? machine.store(stored)
        }
        #expect(try MuxyBridge.send(request(), timeout: 4, at: machine.locations, clock: time.clock) == .done)
        #expect(second == .timedOut && other.stored["req"] == nil)
        // Once the first is answered the next one goes through.
        let later = Time()
        later.onSleep = { _ in
            var stored = other.stored
            stored["ack"] = ["id": "r3", "ok": true]
            try? other.store(stored)
        }
        #expect(try MuxyBridge.send(request("r3"), timeout: 4, at: other.locations, clock: later.clock) == .done)
    }

    @Test func noAnswerEndsAsATimeoutWithTheRequestLeftForTheExtension() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        #expect(try MuxyBridge.send(request(), timeout: 3, at: machine.locations, clock: time.clock) == .timedOut)
        #expect(time.now.timeIntervalSince(epoch) >= 3 && time.now.timeIntervalSince(epoch) < 3.5)
        #expect((machine.stored["req"] as? [String: Any])?["id"] as? String == "r1")
    }

    @Test func withoutARunningBridgeNothingIsWritten() throws {
        let machine = Machine()
        let time = Time()
        #expect(try MuxyBridge.send(request(), timeout: 3, at: machine.locations, clock: time.clock) == .unavailable)
        try machine.beat(age: 60)
        #expect(try MuxyBridge.send(request(), timeout: 3, at: machine.locations, clock: time.clock) == .unavailable)
        #expect(machine.stored["req"] == nil && time.sleeps == 0)
    }

    @Test func aFileOfMuxysThatIsNotAnObjectIsNotWrittenOver() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        time.onSleep = { _ in try? Data("{".utf8).write(to: machine.locations.storage) }
        #expect(try MuxyBridge.send(request(), timeout: 3, at: machine.locations, clock: time.clock) == .unavailable)
        #expect(try String(contentsOf: machine.locations.storage, encoding: .utf8) == "{")
    }
}

struct MuxyResumeJobTests {
    @Test func theCommandIsFixedAndNamesOnlyTheLauncher() throws {
        let machine = Machine()
        let command = try #require(MuxyBridge.resumeCommand(machine.locations))
        #expect(command == "sh '\(machine.locations.resumeScript.path)'")
        #expect(command.hasSuffix("/Nunsseop/muxy-resume.sh'") && command.contains("Application Support"))
        #expect(MuxyBridge.resumeCommand(machine.locations) == command)
        #expect(MuxyBridge.isResumeCommand(command))
        for bad in ["sh '/tmp/x.sh'", "sh /a/Nunsseop/muxy-resume.sh", "bash '/a/Nunsseop/muxy-resume.sh'", "sh '/a/Nunsseop/muxy-resume.sh' x",
                    "sh '/a/Nunsseop/muxy-resume.sh'; id", "sh '/a'b/Nunsseop/muxy-resume.sh'", "sh '/a\\/Nunsseop/muxy-resume.sh'",
                    "sh '/a\n/Nunsseop/muxy-resume.sh'", "sh 'a/Nunsseop/muxy-resume.sh'", "sh '/a/Nunsseop/muxy-resume.sh'\n"] {
            #expect(!MuxyBridge.isResumeCommand(bad), Comment(rawValue: bad))
        }
        // A home with a quote in its name gets no bridge command at all.
        let quoted = MuxyBridge.Locations(profile: machine.locations.profile, support: machine.root.appendingPathComponent("it's/Nunsseop"))
        #expect(MuxyBridge.resumeCommand(quoted) == nil)
    }

    @Test func theLauncherAndTheJobAreWrittenPrivately() throws {
        let machine = Machine()
        let locations = machine.locations
        #expect(MuxyBridge.writeJob(line: "echo hi", shell: "/bin/zsh", at: locations, now: epoch))
        #expect(try String(contentsOf: locations.resumeScript, encoding: .utf8) == MuxyBridge.resumeLauncher)
        #expect(machine.mode(locations.resumeScript) == 0o700 && machine.mode(locations.resumeJobFolder) == 0o700)
        let job = locations.resumeJobFolder.appendingPathComponent("job.sh")
        #expect(machine.mode(job) == 0o600)
        #expect(try String(contentsOf: job, encoding: .utf8) == Resume.terminalScript(line: "echo hi", shell: "/bin/zsh"))
    }

    @Test func aJobThatWaitsIsNotReplacedUntilItIsOld() throws {
        let machine = Machine()
        let locations = machine.locations
        #expect(MuxyBridge.writeJob(line: "echo one", shell: "/bin/zsh", at: locations, now: Date()))
        #expect(!MuxyBridge.writeJob(line: "echo two", shell: "/bin/zsh", at: locations, now: Date()))
        #expect(try String(contentsOf: locations.resumeJobFolder.appendingPathComponent("job.sh"), encoding: .utf8).contains("echo one"))
        #expect(MuxyBridge.writeJob(line: "echo three", shell: "/bin/zsh", at: locations, now: Date().addingTimeInterval(MuxyBridge.jobLifetime + 5)))
        #expect(try String(contentsOf: locations.resumeJobFolder.appendingPathComponent("job.sh"), encoding: .utf8).contains("echo three"))
    }

    /// The launcher as Muxy's terminal runs it, `sh '<path>'`, in a folder with a space in its name: it runs the job once and leaves nothing.
    @Test func theLauncherRunsTheJobOnceThroughTheLoginShellAndCleansUp() throws {
        let machine = Machine()
        let locations = machine.locations
        let marker = machine.root.appendingPathComponent("marker out.txt")
        let line = "printf '%s' \"$PWD\" > \(Resume.quote(marker.path))"
        #expect(MuxyBridge.writeJob(line: "cd -- \(Resume.quote(machine.root.path)) && \(line)", shell: "/bin/sh", at: locations, now: epoch))
        func launch() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [locations.resumeScript.path]
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try launch() == 0)
        // The folder the job went to, by whichever spelling the system gives it (/var is a link to /private/var).
        let reached = try String(contentsOf: marker, encoding: .utf8)
        #expect([machine.root.path, machine.root.resolvingSymlinksInPath().path].contains(reached), Comment(rawValue: reached))
        #expect(!machine.files.fileExists(atPath: locations.resumeJobFolder.path))
        // Run again with no job: nothing happens, and it is not an error.
        try? machine.files.removeItem(at: marker)
        #expect(try launch() == 0)
        #expect(!machine.files.fileExists(atPath: marker.path))
    }
}

struct MuxyResumeTests {
    private func desktop() throws -> MuxyDesktop { try #require(MuxyDesktop.parse(desktopState)) }

    @Test func theConversationIsHandedOverAndTheProjectThatHoldsItsFolderIsNamed() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        var seen: [String: Any] = [:]
        time.onSleep = { _ in
            var stored = machine.stored
            seen = stored["req"] as? [String: Any] ?? [:]
            stored["ack"] = ["id": seen["id"] ?? "", "ok": true]
            try? machine.store(stored)
        }
        #expect(MuxyBridge.resume(line: "echo hi", cwd: "/Users/namkun/Desktop/DEV/Nunsseop", shell: "/bin/zsh", at: machine.locations, desktop: try desktop(), clock: time.clock, activate: {}))
        #expect(seen["type"] as? String == "resume" && seen["folder"] as? String == "/Users/namkun/Desktop/DEV/Nunsseop" && seen["project"] as? String == dev)
        #expect(seen["command"] as? String == MuxyBridge.resumeCommand(machine.locations))
        #expect(machine.files.fileExists(atPath: machine.locations.resumeJobFolder.appendingPathComponent("job.sh").path))
    }

    @Test func muxyIsBroughtForwardBeforeTheRequestAndAgainOnceItWasDone() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        time.onSleep = { _ in
            var stored = machine.stored
            stored["ack"] = ["id": (stored["req"] as? [String: Any])?["id"] ?? "", "ok": true]
            try? machine.store(stored)
        }
        // The prompt that asks the user to allow the command can only be answered in a Muxy that is in front: it comes first.
        var seenRequest: [Bool] = []
        #expect(MuxyBridge.resume(line: "echo hi", cwd: "/Users/me", shell: "/bin/zsh", at: machine.locations, desktop: nil, clock: time.clock,
                                  activate: { seenRequest.append(machine.stored["req"] != nil) }))
        #expect(seenRequest == [false, true])
    }

    @Test func muxyIsBroughtForwardForARequestThatFailedToo() throws {
        let machine = Machine()
        try machine.beat()
        var asked = 0
        #expect(!MuxyBridge.resume(line: "echo hi", cwd: "/Users/me", shell: "/bin/zsh", at: machine.locations, desktop: nil, clock: Time().clock, timeout: 2,
                                   activate: { asked += 1 }))
        #expect(asked == 1)
        // Nothing to bring forward for a bridge that isn't running: nothing was asked of Muxy.
        var none = 0
        #expect(!MuxyBridge.resume(line: "echo hi", cwd: "/Users/me", shell: "/bin/zsh", at: Machine().locations, desktop: nil, clock: Time().clock, activate: { none += 1 }))
        #expect(none == 0)
    }

    @Test func aFolderOutsideEveryProjectOpensTheTabInTheCurrentOne() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        var seen: [String: Any] = [:]
        time.onSleep = { _ in
            var stored = machine.stored
            seen = stored["req"] as? [String: Any] ?? [:]
            stored["ack"] = ["id": seen["id"] ?? "", "ok": true]
            try? machine.store(stored)
        }
        // Home is a project, but not one a conversation's folder is looked for in.
        #expect(MuxyBridge.resume(line: "echo hi", cwd: "/Users/namkun/Documents", shell: "/bin/zsh", at: machine.locations, desktop: try desktop(), clock: time.clock, activate: {}))
        #expect(seen["project"] == nil)
    }

    @Test func aRefusedOrUnansweredRequestLeavesNoJobBehind() throws {
        let machine = Machine()
        try machine.beat()
        let time = Time()
        time.onSleep = { _ in
            var stored = machine.stored
            stored["ack"] = ["id": (stored["req"] as? [String: Any])?["id"] ?? "", "ok": false, "error": "user denied consent"]
            try? machine.store(stored)
        }
        #expect(!MuxyBridge.resume(line: "echo hi", cwd: "/Users/me", shell: "/bin/zsh", at: machine.locations, desktop: nil, clock: time.clock, activate: {}))
        #expect(!machine.files.fileExists(atPath: machine.locations.resumeJobFolder.path))
        let silent = Machine()
        try silent.beat()
        #expect(!MuxyBridge.resume(line: "echo hi", cwd: "/Users/me", shell: "/bin/zsh", at: silent.locations, desktop: nil, clock: Time().clock, timeout: 2, activate: {}))
        #expect(!silent.files.fileExists(atPath: silent.locations.resumeJobFolder.path))
    }

    @Test func withoutARunningBridgeNothingIsWrittenAnywhere() throws {
        let machine = Machine()
        #expect(!MuxyBridge.resume(line: "echo hi", cwd: "/Users/me", shell: "/bin/zsh", at: machine.locations, desktop: nil, clock: Time().clock, activate: {}))
        #expect(!machine.files.fileExists(atPath: machine.locations.support.path) && machine.stored["req"] == nil)
    }

    @Test func muxyIsAChoiceOnlyWhileItsBridgeRuns() {
        let app = URL(fileURLWithPath: "/Applications/Muxy.app")
        func offered(running: Bool, app hasApp: Bool = true) -> [ResumeTerminal] {
            ResumeTerminal.installed(appURL: { _ in hasApp ? app : nil }, weztermInstalled: false, kittyCLI: nil, kittySocket: nil, socketExists: { _ in false },
                                     muxyBridgeRunning: running)
        }
        #expect(offered(running: true).contains(.muxy))
        #expect(!offered(running: false).contains(.muxy))
        #expect(!offered(running: true, app: false).contains(.muxy))
        #expect(ResumeTerminal.installed(appURL: { _ in app }, weztermInstalled: false, kittyCLI: nil, kittySocket: nil, socketExists: { _ in false }) .contains(.muxy) == false)
        #expect(ResumeTerminal.muxy.bundleID == "com.muxy.app" && ResumeTerminal.muxy.name == "Muxy")
    }
}

/// What Muxy 2 saves: ids as 32 hex digits, folders as bytes, sessions as 64-bit numbers.
private let desktopState: Data = {
    func bytes(_ path: String) -> String { "[" + path.utf8.map(String.init).joined(separator: ",") + "]" }
    return Data(#"""
    {"version":3,"servers":{},"starting_directories":{},
     "window":{"active_pane":"\#(pane)","current_project":"\#(dev)","selected_tab":{"\#(dev)":"\#(tab)"}},
     "projects":[
       {"id":"\#(home)","home":true,"name":"Home","directory":\#(bytes("/Users/namkun")),"tabs":[]},
       {"id":"\#(dev)","home":false,"name":"DEV","directory":\#(bytes("/Users/namkun/Desktop/DEV")),"kind":null,"parent_id":null,"tabs":[
         {"id":"\#(tab)","custom_title":null,"panes":[
           {"id":"\#(pane)","title":"nunsseop","content":{"type":"terminal","session":\#(big)}},
           {"id":"\#(other)","title":"x","content":{"type":"terminal","session":\#(biggest)}},
           {"id":"1111111111111111111111111111111a","title":"web","content":{"type":"webview","owner":"todos"}},
           {"id":"2222222222222222222222222222222b","title":"fresh","content":{"type":"terminal"}}]}]}]}
    """#.utf8)
}()

struct MuxyDesktopTests {
    @Test func aSessionIsFoundByItsExactIdEvenAbove2To53() throws {
        let desktop = try #require(MuxyDesktop.parse(desktopState))
        let found = try #require(desktop.pane(ofSession: big))
        #expect(found.pane.id == pane && found.pane.tab == tab && found.project.id == dev && found.project.folder == "/Users/namkun/Desktop/DEV")
        #expect(desktop.pane(ofSession: biggest)?.pane.id == other)
        // The next numbers over, which a rounded 64-bit float could not tell apart.
        #expect(desktop.pane(ofSession: "1978299613479001935") == nil && desktop.pane(ofSession: "1978299613479001933") == nil)
        #expect(desktop.pane(ofSession: "18446744073709551614") == nil && desktop.pane(ofSession: "x") == nil && desktop.pane(ofSession: "99999999999999999999") == nil)
    }

    @Test func aPaneWithoutASessionOrOfAnotherKindHoldsNone() throws {
        let desktop = try #require(MuxyDesktop.parse(desktopState))
        let panes = try #require(desktop.projects.first { $0.id == dev }).panes
        #expect(panes.count == 4 && panes.filter { $0.session != nil }.count == 2)
    }

    @Test func theInnermostProjectThatHoldsAFolderIsFoundAndHomeIsNot() throws {
        let desktop = try #require(MuxyDesktop.parse(desktopState))
        #expect(desktop.project(enclosing: "/Users/namkun/Desktop/DEV")?.id == dev)
        #expect(desktop.project(enclosing: "/Users/namkun/Desktop/DEV/Nunsseop/Sources")?.id == dev)
        #expect(desktop.project(enclosing: "/Users/namkun/Desktop/DEV/")?.id == dev)
        // A sibling that only starts the same, the parent, and a folder only Home holds.
        #expect(desktop.project(enclosing: "/Users/namkun/Desktop/DEVELOP") == nil)
        #expect(desktop.project(enclosing: "/Users/namkun/Desktop") == nil && desktop.project(enclosing: "/Users/namkun/Documents") == nil)
        #expect(desktop.project(enclosing: "") == nil)
    }

    @Test func textThatIsNotTheStateIsNil() {
        for text in ["", "[]", "{", #"{"version":3}"#] { #expect(MuxyDesktop.parse(Data(text.utf8)) == nil, Comment(rawValue: text)) }
        #expect(MuxyDesktop.parse(Data(#"{"projects":[]}"#.utf8)) == MuxyDesktop(projects: []))
    }

    @Test func aFolderGivenAsPlainTextIsReadToo() throws {
        let text = #"{"projects":[{"id":"\#(dev)","name":"DEV","directory":"/Users/me/dev","tabs":[]}]}"#
        #expect(try #require(MuxyDesktop.parse(Data(text.utf8))).projects.first?.folder == "/Users/me/dev")
    }
}

struct MuxyFocusTests {
    private final class Calls {
        var panes: [String] = []
        var folders: [String] = []
        var paneWorks = true
        var folderWorks = true
        var actions: MuxyFocus.Actions {
            MuxyFocus.Actions(focusPane: { self.panes.append($0); return self.paneWorks }, openFolder: { self.folders.append($0); return self.folderWorks })
        }
    }

    private var desktop: MuxyDesktop? { MuxyDesktop.parse(desktopState) }

    @Test func withTheBridgeTheExactPaneIsAskedForAndNothingElseIsDone() {
        let calls = Calls()
        #expect(MuxyFocus.run(session: big, desktop: desktop, bridgeRunning: true, actions: calls.actions))
        #expect(calls.panes == [pane] && calls.folders.isEmpty)
    }

    @Test func withoutTheBridgeTheSessionsProjectFolderIsOpened() {
        let calls = Calls()
        #expect(MuxyFocus.run(session: big, desktop: desktop, bridgeRunning: false, actions: calls.actions))
        #expect(calls.panes.isEmpty && calls.folders == ["/Users/namkun/Desktop/DEV"])
    }

    @Test func aBridgeThatFailsFallsBackToTheFolder() {
        let calls = Calls()
        calls.paneWorks = false
        #expect(MuxyFocus.run(session: big, desktop: desktop, bridgeRunning: true, actions: calls.actions))
        #expect(calls.panes == [pane] && calls.folders == ["/Users/namkun/Desktop/DEV"])
        calls.folderWorks = false
        #expect(!MuxyFocus.run(session: big, desktop: desktop, bridgeRunning: true, actions: calls.actions))
    }

    @Test func aSessionInNoPaneGoesToTheProjectFolderMuxyListsItIn() {
        let calls = Calls()
        // Detached, or not saved to the desktop state yet: no pane to select, but activity names its project.
        #expect(MuxyFocus.run(session: "5", folder: "/Users/namkun/Desktop/DEV", desktop: desktop, bridgeRunning: true, actions: calls.actions))
        #expect(MuxyFocus.run(session: big, folder: "/Users/namkun/Desktop/DEV", desktop: nil, bridgeRunning: false, actions: calls.actions))
        #expect(calls.panes.isEmpty && calls.folders == ["/Users/namkun/Desktop/DEV", "/Users/namkun/Desktop/DEV"])
        #expect(MuxyFocus.target(session: "5", in: desktop, fallback: "/x") == MuxyFocus.Target(folder: "/x"))
        #expect(MuxyFocus.target(session: "5", in: desktop, fallback: "") == MuxyFocus.Target())
        // The desktop state is the better word: its pane and its project win.
        #expect(MuxyFocus.run(session: big, folder: "/elsewhere", desktop: desktop, bridgeRunning: true, actions: calls.actions))
        #expect(calls.panes == [pane] && calls.folders.count == 2)
    }

    @Test func aSessionInNoPaneOrAnUnreadableStateGoesNowhere() {
        let calls = Calls()
        #expect(!MuxyFocus.run(session: "5", desktop: desktop, bridgeRunning: true, actions: calls.actions))
        #expect(!MuxyFocus.run(session: big, desktop: nil, bridgeRunning: true, actions: calls.actions))
        #expect(calls.panes.isEmpty && calls.folders.isEmpty)
        #expect(MuxyFocus.target(session: big, in: desktop) == MuxyFocus.Target(pane: pane, folder: "/Users/namkun/Desktop/DEV"))
        #expect(MuxyFocus.target(session: "5", in: desktop) == MuxyFocus.Target())
    }
}

struct MuxyBridgeExtensionTests {
    /// The extension's own scripts, run against stand-ins for Muxy's `muxy` object (Tests/muxy-bridge/bridge.test.cjs).
    @Test(.enabled(if: NodeTool.available, NodeTool.reason))
    func theBackgroundScriptAndTheHelperPageDoWhatTheProtocolSays() throws {
        // The file, not its folder: Node 24 loads a folder argument as a module.
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("muxy-bridge").appendingPathComponent("bridge.test.cjs")
        let process = Process()
        process.executableURL = try #require(NodeTool.url)
        process.arguments = ["--test", tests.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        killer.cancel()
        #expect(process.terminationStatus == 0, Comment(rawValue: text))
        #expect(text.contains("fail 0") && !text.contains("pass 0"), Comment(rawValue: text))
    }
}

struct MuxyStringsTests {
    private static let keys = ["%@ in %@ needs input", "%@ needs input", "%@ in %@ finished", "%@ finished", "Muxy bridge", "Loaded, not running", "Not loaded",
                               "Show extension in Finder", "Muxy lists this session, so Nunsseop can take you to it but not type into it",
                               "Read from Muxy's own agent activity while it runs, so every agent in Muxy works without setup. Hidden while Muxy is in front, and skipped for tools connected above.",
                               "Lets Nunsseop open a session's own tab in Muxy and resume conversations there. In Muxy, open Settings › Extensions › Load Unpacked…, pick the folder shown in Finder, then turn the extension on."]

    @Test func everyMuxyStringIsTranslatedIntoEveryLanguageWithItsPlaceholders() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        func placeholders(_ text: String) -> Int { text.components(separatedBy: "%").count - 1 }
        for language in ["de", "es", "fr", "ja", "ko", "zh-Hans"] {
            let table = try #require(NSDictionary(contentsOfFile: resources.appendingPathComponent("\(language).lproj/Localizable.strings").path), Comment(rawValue: language))
            for key in Self.keys {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty && text != key, Comment(rawValue: "\(language): \(key)"))
                #expect(placeholders(text) == placeholders(key), Comment(rawValue: "\(language): \(key)"))
            }
            // Positional placeholders name both arguments, in whatever order the language wants.
            let both = table["%@ in %@ needs input"] as? String ?? ""
            #expect(both.contains("%1$@") && both.contains("%2$@"), Comment(rawValue: language))
            #expect(table["Read from Muxy's own notification list, so every agent and terminal in Muxy works without setup. Hidden while Muxy is in front, and skipped for tools connected above."] == nil,
                    Comment(rawValue: "\(language) still has the Muxy 1 sentence"))
        }
    }
}
