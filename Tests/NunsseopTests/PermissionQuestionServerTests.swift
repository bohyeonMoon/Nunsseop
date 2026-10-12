import Combine
import Foundation
import Testing
@testable import Nunsseop

/// A question through the real hook, the server and the board.
@MainActor
struct PermissionQuestionServerTests {
    private typealias Q = QuestionFixtures

    private let questions = [Q.question("Which color?", options: [Q.option("Blue", "Calm"), Q.option("Re\u{430}d \"loud\"", "Loud")]),
                             Q.question("Which checks?", multiSelect: true, options: [Q.option("Unit"), Q.option("Types"), Q.option("Lint")])]

    private func hook(for server: PermissionTestServer, _ questions: [[String: Any]]) throws -> HookProcess {
        try HookProcess(command: server.hookCommand, home: server.home.url, stdin: Q.body(input: Q.input(questions)))
    }

    private func expected(_ picked: [Int: [Int]], _ questions: [[String: Any]]) throws -> String {
        Q.text(PermissionWire.decision(.answered(picked), suggestion: nil, questionInput: Q.input(questions)))
    }

    @Test func theAnswerReachesClaudeCodeThroughTheRealHookAsTheOriginalText() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server, questions)
        await eventually { server.events.prompts.count == 1 }
        let prompt = try #require(server.events.prompts.first)
        #expect(prompt.asking?.items.count == 2 && prompt.title == "Question")
        server.server.permissions.answer(prompt.id, .answered([0: [1], 1: [2, 0]]))
        let result = try #require(await process.finish())
        #expect(result.status == 0)
        #expect(result.stdout == (try expected([0: [1], 1: [2, 0]], questions)))
        let output = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PreToolUse" && specific["permissionDecision"] as? String == "allow")
        let updated = try #require(specific["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Which color?": "Re\u{430}d \"loud\"", "Which checks?": "Unit, Lint"])
        #expect((updated["questions"] as? [[String: Any]])?.count == 2)
        #expect(server.events.goneIDs.isEmpty)
    }

    @Test func theAnswerCarriesAProofOfTheSameNonceAndTheExactDecision() async throws {
        let server = try await PermissionTestServer()
        let client = try RawClient(port: server.port)
        let nonce = PermissionTestServer.nonce()
        client.send(server.request(body: Q.body(input: Q.input(questions)), nonce: nonce))
        await eventually { server.events.prompts.count == 1 }
        server.server.permissions.answer(try #require(server.events.prompts.first).id, .answered([0: [0], 1: [1]]))
        let text = String(decoding: await client.read(timeout: 5), as: UTF8.self)
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        let space = try #require(body.firstIndex(of: " "))
        let (proof, decision) = (String(body[..<space]), String(body[body.index(after: space)...]))
        #expect(decision == (try expected([0: [0], 1: [1]], questions)))
        #expect(proof == PermissionWire.responseProof(key: server.permissionKey, nonce: nonce, decision: Data(decision.utf8)))
    }

    @Test func answeringInTheTerminalPrintsNothingAndEndsTheHookAtOnce() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server, questions)
        await eventually { server.events.prompts.count == 1 }
        server.server.permissions.answer(try #require(server.events.prompts.first).id, .terminal)
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
    }

    @Test func aQuestionTakesNoApprovalAndAnApprovalNoAnswerAndTheTerminalAsksInstead() async throws {
        let server = try await PermissionTestServer()
        for (index, answer) in [PermissionAnswer.allow, .deny, .always].enumerated() {
            let process = try hook(for: server, questions)
            await eventually { server.events.prompts.count == index + 1 }
            server.server.permissions.answer(try #require(server.events.prompts.last).id, answer)
            let result = try #require(await process.finish())
            #expect(result.stdout == "" && result.status == 0, "\(answer)")
        }
        let approval = try HookProcess(command: server.hookCommand, home: server.home.url, stdin: PermissionTestServer.hookInput())
        await eventually { server.events.prompts.count == 4 }
        server.server.permissions.answer(try #require(server.events.prompts.last).id, .answered([0: [0]]))
        let result = try #require(await approval.finish())
        #expect(result.stdout == "" && result.status == 0)
    }

    @Test func anAnswerThatIsNotAnAnswerOfTheQuestionLeavesItToTheTerminal() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server, questions)
        await eventually { server.events.prompts.count == 1 }
        server.server.permissions.answer(try #require(server.events.prompts.first).id, .answered([0: [7], 1: [0]]))
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
    }

    @Test func otherToolsOfAPreToolUseAndMalformedQuestionsAreHandedBackToTheTerminal() async throws {
        let server = try await PermissionTestServer()
        let bodies = [Q.body(tool: "Bash", input: ["command": "ls"]), Q.body(input: Q.input([])), Q.body(input: Q.input([Q.question(options: [Q.option("only")])]))]
        for body in bodies {
            let client = try RawClient(port: server.port)
            client.send(server.request(body: body))
            #expect(await client.status() == "HTTP/1.1 204 No Content")
        }
        let process = try HookProcess(command: server.hookCommand, home: server.home.url, stdin: Q.body(tool: "Read", input: ["file_path": "/x"]))
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
        #expect(server.events.prompts.isEmpty)
    }

    @Test func aQuestionNeedsTheSameProofAsAnApproval() async throws {
        let server = try await PermissionTestServer()
        let body = Q.body(input: Q.input(questions))
        let client = try RawClient(port: server.port)
        client.send(server.request(body: body, proof: PermissionWire.requestProof(key: server.token, nonce: "x", body: body)))
        #expect(await client.status() == "HTTP/1.1 401 Unauthorized")
        #expect(server.events.prompts.isEmpty)
    }

    @Test func aHookKilledBecauseTheTerminalAnsweredTakesItsQuestionAway() async throws {
        let server = try await PermissionTestServer()
        let process = try hook(for: server, questions)
        await eventually { server.events.prompts.count == 1 }
        let id = try #require(server.events.prompts.first?.id)
        process.terminate()
        await eventually { server.events.goneIDs.contains(id) }
        #expect(server.events.goneIDs == [id])
    }

    // MARK: Through the board

    @Test func aClickOnTheBoardAnswersTheHook() async throws {
        let server = try await PermissionTestServer()
        let board = PermissionBoard()
        let links = PermissionLink.connect(board: board, gate: server.server.permissions,
                                           isOn: PassthroughSubject<Bool, Never>().eraseToAnyPublisher(), enabled: { true })
        let process = try hook(for: server, questions)
        await eventually { board.prompts.count == 1 }
        let prompt = try #require(board.current)
        // A real click: the gate has to open first, and a press has to begin after that.
        func click(_ action: QuestionAction) async throws {
            await eventually { board.gate.refresh(); return board.gate.isReady }
            board.gate.pressBegan()
            try await Task.sleep(for: .milliseconds(20))
            board.act(prompt, action)
            board.gate.pressEnded()
            try await Task.sleep(for: .milliseconds(50))
        }
        try await click(.pick(0))
        #expect(board.draft(for: prompt).step == 1)
        try await click(.toggle(1))
        try await click(.submit)
        #expect(board.current == nil)
        let result = try #require(await process.finish())
        #expect(result.stdout == (try expected([0: [0], 1: [1]], questions)))
        withExtendedLifetime(links) {}
    }

    @Test func twoQuestionsWaitingAtOnceEachGetTheirOwnAnswer() async throws {
        let server = try await PermissionTestServer()
        let board = PermissionBoard()
        let links = PermissionLink.connect(board: board, gate: server.server.permissions,
                                           isOn: PassthroughSubject<Bool, Never>().eraseToAnyPublisher(), enabled: { true })
        let seasons = [Q.question("Which season?", options: [Q.option("Spring"), Q.option("Autumn")])]
        let animals = [Q.question("Which animal?", options: [Q.option("Cat"), Q.option("Dog")])]
        let first = try hook(for: server, seasons)
        await eventually { board.prompts.count == 1 }
        let second = try hook(for: server, animals)
        await eventually { board.prompts.count == 2 }
        func click(_ action: QuestionAction, on prompt: PermissionPrompt) async throws {
            await eventually { board.gate.refresh(); return board.gate.isReady }
            board.gate.pressBegan()
            try await Task.sleep(for: .milliseconds(20))
            board.act(prompt, action)
            board.gate.pressEnded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let front = try #require(board.current)
        let back = try #require(board.prompts.last)
        // A click meant for the card behind does nothing while the other is in front.
        try await click(.pick(1), on: back)
        #expect(board.prompts.count == 2)
        try await click(.terminal, on: front)
        #expect(board.current?.id == back.id)
        try await click(.pick(1), on: back)
        #expect(board.prompts.isEmpty)
        let firstResult = try #require(await first.finish())
        let secondResult = try #require(await second.finish())
        #expect(firstResult.stdout == "" && firstResult.status == 0)
        #expect(secondResult.stdout == (try expected([0: [1]], animals)))
        withExtendedLifetime(links) {}
    }

    @Test func turningTheSettingOffLetsAQuestionsHookGoAndTakesItsCardDown() async throws {
        let server = try await PermissionTestServer()
        let board = PermissionBoard()
        let setting = PassthroughSubject<Bool, Never>()
        let links = PermissionLink.connect(board: board, gate: server.server.permissions, isOn: setting.eraseToAnyPublisher(), enabled: { true })
        let process = try hook(for: server, questions)
        await eventually { board.prompts.count == 1 }
        setting.send(false)
        #expect(board.prompts.isEmpty && board.drafts.isEmpty)
        let result = try #require(await process.finish())
        #expect(result.stdout == "" && result.status == 0)
        withExtendedLifetime(links) {}
    }
}
