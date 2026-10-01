import Foundation

@main struct MeshCodexAdapterTests {
    @MainActor static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let base = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default
        func client(_ scenario: String, resume: Bool = false, turnTimeout: TimeInterval = 3) throws -> MeshCodexClient {
            let cwd = base.appendingPathComponent(scenario)
            try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
            return MeshCodexClient(executableURL: fixture, workingDirectory: cwd,
                resumeThreadID: resume ? "monitor-fixture-thread" : nil,
                requestTimeout: 2, turnTimeout: turnTimeout)
        }
        func wire(_ scenario: String) throws -> [[String: Any]] {
            let text = try String(contentsOf: base.appendingPathComponent(scenario).appendingPathComponent("wire.jsonl"), encoding: .utf8)
            return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
        func waitForMarker(_ scenario: String, _ name: String) async throws {
            let marker = base.appendingPathComponent(scenario).appendingPathComponent(name)
            let deadline = Date().addingTimeInterval(1.5)
            while !fm.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
            assert(fm.fileExists(atPath: marker.path), "Missing fixture marker: \(scenario)/\(name)")
        }
        func release(_ scenario: String, _ name: String) throws {
            try Data("released".utf8).write(to: base.appendingPathComponent(scenario).appendingPathComponent(name))
        }
        func waitForTurn(_ scenario: String) async throws {
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                if let values = try? wire(scenario), values.contains(where: { $0["method"] as? String == "turn/start" }) {
                    // The marker/log precedes the fragmented process read. Let the
                    // real client consume turn/started before the Stop action.
                    try await Task.sleep(nanoseconds: 20_000_000); return
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            assertionFailure("Fixture turn never started")
        }
        func mustFail(_ operation: () async throws -> Void) async -> Bool {
            do { try await operation(); return false } catch { return true }
        }
        let happy = try client("happy")
        var events: [String] = []
        happy.onEvent = { event in events.append(String(describing: event)) }
        let ready = try await happy.connect()
        assert(ready.authMode == "chatgpt")
        assert(ready.resolvedModel == "fixture-session-model" && ready.modelProvider == "fixture-provider")
        assert(happy.connection == ready && events.joined().contains("fixture-session-model"))
        let userWords = "Explain this exact sentence.\nKeep my words intact."
        let answer = try await happy.send(MeshAgentRequest(originalMessage: userWords,
            contextText: "Selected text: quoted source", observationText: "Uncertain gaze target"))
        assert(answer.text == "A precise answer 👀.", answer.text)
        assert(!events.joined().contains("never-expose"))
        let start = try wire("happy").first { $0["method"] as? String == "turn/start" }!
        let inputs = (start["params"] as! [String: Any])["input"] as! [[String: Any]]
        assert(inputs[0]["text"] as? String == userWords)
        assert((inputs[1]["text"] as! String).contains("uncertain_local_interpretation"))
        let threadStart = try wire("happy").first { $0["method"] as? String == "thread/start" }!
        assert((threadStart["params"] as! [String: Any])["sandbox"] as? String == "read-only")
        let imageURL = base.appendingPathComponent("evidence.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let imageInputs = try MeshCodexClient.inputItems(for: MeshAgentRequest(originalMessage: "This", localImageURLs: [imageURL]))
        assert(imageInputs.last?["type"] as? String == "localImage")
        assert(imageInputs.last?["path"] as? String == imageURL.standardizedFileURL.path)
        let badURL = await mustFail { _ = try MeshCodexClient.inputItems(for: MeshAgentRequest(originalMessage: "This", localImageURLs: [URL(string: "https://example.test/image.png")!])) }
        assert(badURL)
        happy.disconnect()
        print("PASS original message, evidence separation, chunked UTF-8, final/commentary, foreign events, early completion, account privacy")

        let brokenPipe = try client("closed_stdin")
        _ = try await brokenPipe.connect()
        let closedMarker = base.appendingPathComponent("closed_stdin/stdin-closed")
        for _ in 0..<100 where !fm.fileExists(atPath: closedMarker.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        assert(fm.fileExists(atPath: closedMarker.path), "Fixture did not close stdin")
        var disconnectedOnWrite = false
        do { _ = try await brokenPipe.send(MeshAgentRequest(originalMessage: "Do not crash on a closed request pipe")) }
        catch MeshCodexError.disconnected { disconnectedOnWrite = true }
        catch { assertionFailure("Expected a closed-pipe error, not a later timeout: \(error)") }
        assert(disconnectedOnWrite && brokenPipe.connection == nil)
        brokenPipe.disconnect()
        print("PASS child stdin closure returns failure without terminating the host")

        for scenario in ["busy_resume", "foreign_resume", "unauthenticated"] {
            let c = try client(scenario, resume: scenario != "unauthenticated")
            let failed = await mustFail { _ = try await c.connect() }
            assert(failed)
            let scenarioWire = try wire(scenario)
            assert(!scenarioWire.contains { ["thread/resume", "turn/start"].contains($0["method"] as? String ?? "") })
            c.disconnect()
        }
        let resumed = try client("resume", resume: true)
        let resumedConnection = try await resumed.connect()
        assert(resumedConnection.resolvedModel == "fixture-resumed-model" && resumedConnection.modelProvider == "fixture-provider")
        let resumeWire = try wire("resume")
        assert(resumeWire.contains { $0["method"] as? String == "thread/resume" })
        resumed.disconnect()
        print("PASS dedicated resume, active/foreign thread refusal, authentication gate")

        for scenario in ["missing_model", "invalid_model_metadata", "blank_model_metadata", "unsafe_model_metadata", "partial_model_metadata"] {
            let unknown = try client(scenario)
            let value = try await unknown.connect()
            assert(value.resolvedModel == nil, "Missing/invalid model must not be inferred from thread data or defaults")
            assert(value.modelProvider == (scenario == "partial_model_metadata" ? "custom-provider" : nil))
            unknown.disconnect()
        }
        let unspecified = MeshAgentConnection(threadID: "other-backend", authMode: "fixture")
        assert(unspecified.resolvedModel == nil && unspecified.modelProvider == nil)
        print("PASS resolved session model metadata, resume response authority, and unknown values without guessing")

        let approval = try client("approval")
        var blocked = false
        approval.onEvent = { if case .approvalBlocked = $0 { blocked = true } }
        let failedApproval = await mustFail { _ = try await approval.send(MeshAgentRequest(originalMessage: "Help")) }
        assert(failedApproval && blocked)
        let rejection = try wire("approval").first { $0["id"] as? String == "approval-fixture" }!
        assert((rejection["result"] as! [String: Any])["decision"] as? String == "cancel")
        approval.disconnect()
        let earlyApproval = try client("approval_preack")
        var earlyBlocked = false
        earlyApproval.onEvent = { if case .approvalBlocked = $0 { earlyBlocked = true } }
        let earlyApprovalFailed = await mustFail { _ = try await earlyApproval.send(MeshAgentRequest(originalMessage: "Approval before acknowledgement")) }
        assert(earlyApprovalFailed && earlyBlocked && earlyApproval.connection == nil)
        earlyApproval.disconnect()
        print("PASS approval request cancelled, visible, and no hanging turn, including before start acknowledgement")

        let cancellation = try client("cancel")
        _ = try await cancellation.connect()
        let running = Task { try await cancellation.send(MeshAgentRequest(originalMessage: "Wait")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await cancellation.cancelCurrentTurn()
        let cancelled = await mustFail { _ = try await running.value }
        assert(cancelled)
        let cancelWire = try wire("cancel")
        assert(cancelWire.contains { $0["method"] as? String == "turn/interrupt" })
        cancellation.disconnect()
        let timed = try client("timeout", turnTimeout: 0.15)
        let timedOut = await mustFail { _ = try await timed.send(MeshAgentRequest(originalMessage: "Wait")) }
        assert(timedOut && timed.connection == nil)
        print("PASS cancellation and bounded turn timeout")

        let connecting = try client("connect_cancel")
        let pending = Task { try await connecting.connect() }
        try await Task.sleep(nanoseconds: 100_000_000)
        pending.cancel()
        let connectFailed = await mustFail { _ = try await pending.value }
        assert(connectFailed && connecting.connection == nil)
        print("PASS connect task cancellation shuts down owned process")
        for scenario in ["disconnect_reconnect", "cancel_reconnect"] {
            let retry = try client(scenario)
            var connectionEvents = 0
            retry.onEvent = { if case .connected = $0 { connectionEvents += 1 } }
            let old = Task { try await retry.connect() }
            try await waitForMarker(scenario, "first-initialize-held")
            if scenario == "cancel_reconnect" { old.cancel() }
            // Do not yield between Stop and beginning a replacement attempt. Old
            // catch/defer/onCancel are deliberately still queued on MainActor.
            let connectingStop = retry.beginCancelCurrentTurn()
            assert(connectingStop == nil, "An unconnected startup stops synchronously")
            let replacement = Task { try await retry.connect() }
            try await waitForMarker(scenario, "second-initialize-held")
            let oldFailed = await mustFail { _ = try await old.value }
            assert(oldFailed && retry.connection == nil)
            var stillConnecting = false
            do { _ = try await retry.connect() }
            catch MeshCodexError.busy { stillConnecting = true }
            catch { assertionFailure("Old defer corrupted replacement startup: \(error)") }
            assert(stillConnecting, "Only the replacement owns connecting state")
            try release(scenario, "release-initialize")
            let replacementValue = try await replacement.value
            assert(retry.connection == replacementValue && connectionEvents == 1)
            let reply = try await retry.send(MeshAgentRequest(originalMessage: "New connection survives old cleanup"))
            assert(reply.text == "A precise answer 👀.")
            retry.disconnect()
        }
        print("PASS delayed connect Stop/immediate reconnect, old catch/defer/cancel isolation and fresh connection ownership")

        let eventStop = try client("event_disconnect")
        var firstConnected = true
        var eventReplacement: Task<MeshAgentConnection, Error>?
        eventStop.onEvent = { event in
            if case .connected = event, firstConnected {
                firstConnected = false
                eventStop.disconnect()
                eventReplacement = Task { try await eventStop.connect() }
            }
        }
        let stoppedAtPublication = await mustFail { _ = try await eventStop.send(MeshAgentRequest(originalMessage: "Must not cross connection ownership")) }
        assert(stoppedAtPublication && eventReplacement != nil)
        let afterEvent = try await eventReplacement!.value
        let eventWire = try wire("event_disconnect")
        assert(!eventWire.contains { $0["method"] as? String == "turn/start" }, "Disconnected send never continues onto replacement server")
        let eventReply = try await eventStop.send(MeshAgentRequest(originalMessage: "Explicit fresh request"))
        assert(eventReply.text == "A precise answer 👀." && eventStop.connection == afterEvent)
        eventStop.disconnect()
        print("PASS reentrant connected event cannot transfer an old send into the replacement connection")

        let drain = try client("interrupt_drain")
        _ = try await drain.connect()
        let oldTurn = Task { try await drain.send(MeshAgentRequest(originalMessage: "Wait for Stop")) }
        try await waitForTurn("interrupt_drain")
        let firstStop = drain.beginCancelCurrentTurn()
        let repeatedStop = drain.beginCancelCurrentTurn()
        assert(firstStop != nil && repeatedStop != nil)
        oldTurn.cancel() // Same old turn cancellation must join, not add an interrupt.
        let nextTurn = Task { try await drain.send(MeshAgentRequest(originalMessage: "Immediate next question")) }
        try await waitForMarker("interrupt_drain", "interrupt-held")
        var beforeRelease = try wire("interrupt_drain")
        assert(beforeRelease.filter { $0["method"] as? String == "turn/start" }.count == 1,
               "Replacement must wait while old interrupt is pending")
        assert(beforeRelease.filter { $0["method"] as? String == "turn/interrupt" }.count == 1,
               "Duplicate Stop and cancelled send coalesce")
        try release("interrupt_drain", "release-interrupt")
        let oldTurnFailed = await mustFail { _ = try await oldTurn.value }
        let newReply = try await nextTurn.value
        await firstStop?.value; await repeatedStop?.value
        assert(oldTurnFailed && newReply.text == "A precise answer 👀." && drain.connection != nil)
        beforeRelease = try wire("interrupt_drain")
        assert(beforeRelease.filter { $0["method"] as? String == "turn/interrupt" }.count == 1)
        drain.disconnect()
        print("PASS interrupt drain prevents busy retry; duplicate user/send cancellations coalesce")

        let ackFirst = try client("interrupt_ack_first")
        var ackFirstEvents: [String] = []
        ackFirst.onEvent = { ackFirstEvents.append(String(describing: $0)) }
        _ = try await ackFirst.connect()
        let beforeAck = Task { try await ackFirst.send(MeshAgentRequest(originalMessage: "Old turn")) }
        try await waitForTurn("interrupt_ack_first")
        let ackStop = ackFirst.beginCancelCurrentTurn()
        var replacementFinished = false
        let afterAck = Task {
            let reply = try await ackFirst.send(MeshAgentRequest(originalMessage: "New turn"))
            replacementFinished = true
            return reply
        }
        try await waitForMarker("interrupt_ack_first", "interrupt-ack-sent")
        try await Task.sleep(nanoseconds: 80_000_000)
        let beforeTerminal = try wire("interrupt_ack_first")
        assert(beforeTerminal.filter { $0["method"] as? String == "turn/start" }.count == 1,
               "Interrupt ACK is not terminal: replacement must still wait")
        assert(!replacementFinished)
        try release("interrupt_ack_first", "release-old-terminal")
        try await waitForMarker("interrupt_ack_first", "replacement-start-held")
        try await Task.sleep(nanoseconds: 40_000_000)
        assert(!replacementFinished && !ackFirstEvents.joined().contains("STALE OLD OUTPUT"),
               "Old started/delta/completed events cannot bind, publish or finish a pre-ack replacement")
        assert(!fm.fileExists(atPath: base.appendingPathComponent("interrupt_ack_first/replacement-before-terminal").path))
        try release("interrupt_ack_first", "release-replacement-start")
        let stoppedBeforeAck = await mustFail { _ = try await beforeAck.value }
        let afterAckReply = try await afterAck.value
        await ackStop?.value
        assert(stoppedBeforeAck && afterAckReply.text == "A precise answer 👀." && ackFirst.connection != nil)
        assert(!ackFirstEvents.joined().contains("STALE OLD OUTPUT"))
        ackFirst.disconnect()
        print("PASS interrupt ACK before terminal drains correctly; stale pre-ack replacement notifications cannot bind or publish")

        let alreadyBound = try client("bound_turn_stale")
        var boundEvents: [String] = []
        alreadyBound.onEvent = { boundEvents.append(String(describing: $0)) }
        let boundReply = try await alreadyBound.send(MeshAgentRequest(originalMessage: "Only my acknowledged turn"))
        assert(boundReply.text == "A precise answer 👀." && !boundEvents.joined().contains("STALE OLD OUTPUT"))
        alreadyBound.disconnect()
        for scenario in ["preack_count_limit", "preack_byte_limit"] {
            let bounded = try client(scenario)
            var rejected = false
            do { _ = try await bounded.send(MeshAgentRequest(originalMessage: "Bound pre-ack evidence")) }
            catch MeshCodexError.invalidInput { rejected = true }
            catch { assertionFailure("Expected a bounded pre-ack rejection: \(error)") }
            assert(rejected && bounded.connection == nil)
            bounded.disconnect()
        }
        let unknownNotifications = try client("large_unknown_notification")
        let unknownReply = try await unknownNotifications.send(MeshAgentRequest(originalMessage: "Ignore unsupported notification methods"))
        assert(unknownReply.text == "A precise answer 👀.")
        unknownNotifications.disconnect()
        let invalidTerminal = try client("nonterminal_completion")
        var rejectedTerminal = false
        do { _ = try await invalidTerminal.send(MeshAgentRequest(originalMessage: "Require an actual terminal status")) }
        catch MeshCodexError.protocolError { rejectedTerminal = true }
        catch { assertionFailure("Expected protocol rejection for nonterminal completion: \(error)") }
        assert(rejectedTerminal && invalidTerminal.connection == nil)
        invalidTerminal.disconnect()
        print("PASS nested turn identity, bounded deferred bytes/count, unknown methods and terminal-status validation")

        for scenario in ["interrupt_timeout", "interrupt_ack_no_terminal"] {
        let interruptTimeout = try client(scenario, turnTimeout: 10)
        _ = try await interruptTimeout.connect()
        let waitingTurn = Task { try await interruptTimeout.send(MeshAgentRequest(originalMessage: "Old turn with missing interrupt acknowledgement")) }
        try await waitForTurn(scenario)
        let startedInterrupt = Date()
        let timedStop = interruptTimeout.beginCancelCurrentTurn()
        let afterTimeout = Task { try await interruptTimeout.send(MeshAgentRequest(originalMessage: "Retry after interrupt timeout")) }
        try await waitForMarker(scenario, "interrupt-held")
        let timeoutReply = try await afterTimeout.value
        let oldTimedOut = await mustFail { _ = try await waitingTurn.value }
        await timedStop?.value
        let drainSeconds = Date().timeIntervalSince(startedInterrupt)
        assert(oldTimedOut && timeoutReply.text == "A precise answer 👀." && interruptTimeout.connection != nil)
        assert(drainSeconds >= 4.5 && drainSeconds < 8, "Existing five-second interrupt deadline bounds the drain")
        interruptTimeout.disconnect()
        }
        print("PASS missing interrupt acknowledgement or terminal event drains by deadline and retry reconnects")

        for scenario in ["stale_send_cancel", "late_interrupt_failure"] {
            let retry = try client(scenario)
            _ = try await retry.connect()
            let old = Task { try await retry.send(MeshAgentRequest(originalMessage: "Old request")) }
            try await waitForTurn(scenario)
            var oldStop: Task<Void, Never>?
            if scenario == "late_interrupt_failure" {
                oldStop = retry.beginCancelCurrentTurn()
                try await waitForMarker(scenario, "interrupt-held")
            } else { old.cancel() }
            retry.disconnect()
            let newConnection = try await retry.connect()
            let oldFailed = await mustFail { _ = try await old.value }
            await oldStop?.value
            assert(oldFailed && retry.connection == newConnection,
                   "Old send/interrupt cancellation cannot disconnect the replacement")
            let reply = try await retry.send(MeshAgentRequest(originalMessage: "Fresh request survives"))
            assert(reply.text == "A precise answer 👀." && retry.connection == newConnection)
            retry.disconnect()
        }
        print("PASS stale send onCancel and late interrupt failure cannot affect a new connection")
        print("ALL OFFLINE ADAPTER TESTS PASSED")
    }
}
