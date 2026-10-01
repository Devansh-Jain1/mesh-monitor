import Foundation

@main
private struct MeshMorningFixtureTests {
    @MainActor
    static func main() throws {
        let parser = ISO8601DateFormatter()
        func date(_ string: String) -> Date { parser.date(from: string)! }
        let zone = TimeZone(identifier: "America/New_York")!
        var now = date("2026-09-19T08:00:00Z") // 4 AM; overnight preparation.
        let intended = date("2026-09-19T13:00:00Z")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-morning-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var paused = false
        var deliveries: [String] = []

        func artifact(day: String = "2026-09-19", timezone: String = "America/New_York",
                      generated: String = "2026-09-19T08:00:00Z", notBefore: String = "2026-09-19T13:00:00Z",
                      text: String = "Two Home events. Work on applications, then study.",
                      calendar: String = "Home", schema: String = "mesh.morning-brief.v1",
                      id: String = "home:2026-09-19:America/New_York") -> MeshMorningBriefArtifact {
            MeshMorningBriefArtifact(schema: schema, id: id, calendar: calendar, date: day,
                                     timezone: timezone, generatedAt: generated, notBefore: notBefore, text: text)
        }

        let morning = MeshMorningState(directory: directory, timeZone: zone, clock: { now })
        morning.intendedDate = intended
        assert(!morning.armed && !FileManager.default.fileExists(atPath: directory.path))
        assert(morning.prepare(artifact()))
        assert(!morning.arm(), "No pause binding must fail closed")
        morning.isPaused = { paused }
        assert(!morning.arm(), "No audio binding must fail closed")
        morning.onDelivery = { text in
            // This must already exist DURABLY before external audio is called.
            let data = try! Data(contentsOf: directory.appendingPathComponent("morning-receipts.jsonl"))
            let receipts = data.split(separator: 0x0A)
            assert(!receipts.isEmpty)
            let receipt = try! JSONDecoder().decode(MeshMorningAttemptReceipt.self, from: Data(receipts.last!))
            assert(receipt.outcome == "attempted_before_delivery")
            deliveries.append(text)
        }
        assert(morning.arm())
        let earlyArrival = UUID()
        assert(!morning.arrival(earlyArrival))
        assert(morning.armed && morning.status.contains("Waiting") && deliveries.isEmpty)
        now = intended
        assert(deliveries.isEmpty, "Time alone cannot trigger audio")
        assert(!morning.arrival(earlyArrival), "The same early arrival cannot become valid later")
        let freshArrival = UUID()
        assert(morning.arrival(freshArrival))
        assert(deliveries.count == 1 && !morning.armed && morning.deliveryState == .attempted)
        assert(!morning.replay(), "No overlapping delivery")
        morning.markDeliveryFailed("Speaker disconnected")
        assert(morning.deliveryState == .failed && !morning.arm())
        assert(!morning.arrival(UUID()) && deliveries.count == 1)

        let restarted = MeshMorningState(directory: directory, timeZone: zone, clock: { now })
        restarted.isPaused = { paused }
        restarted.onDelivery = { deliveries.append($0) }
        assert(!restarted.armed && restarted.hasAttemptForSelectedDay)
        assert(restarted.prepare(artifact(id: "changed-id-does-not-bypass-receipt")))
        assert(!restarted.arm() && !restarted.arrival(UUID()))
        assert(restarted.replay() && deliveries.count == 2, "Replay requires an explicit call")
        assert(restarted.lastAttempt?.manualReplay == true)
        restarted.markDeliveryFinished()
        assert(restarted.deliveryState == .finished)

        paused = true
        assert(!restarted.replay() && !restarted.armed && deliveries.count == 2)
        paused = false
        let before = deliveries.count
        assert(!restarted.prepare(artifact(calendar: "Family")))
        assert(!restarted.prepare(artifact(schema: "wrong")))
        assert(!restarted.prepare(artifact(day: "2026-09-18")))
        assert(!restarted.prepare(artifact(day: "2026-09-20")))
        assert(!restarted.prepare(artifact(timezone: "Europe/London")))
        assert(!restarted.prepare(artifact(generated: "2026-09-18T12:59:59Z")))
        assert(!restarted.prepare(artifact(generated: "2026-09-19T13:00:01Z")))
        assert(!restarted.prepare(artifact(notBefore: "2026-09-18T12:00:00Z")))
        assert(!restarted.prepare(artifact(text: "")))
        assert(!restarted.prepare(artifact(text: String(repeating: "x", count: 6001))))
        assert(!restarted.prepare(artifact(id: "")))
        assert(deliveries.count == before)

        let unavailable = MeshHomeDayBrief(state: .unavailable, date: intended, generatedAt: now, text: "Unknown", eventCount: 0)
        assert(!restarted.prepare(unavailable))
        let noPlan = MeshHomeDayBrief(state: .noPlan, date: intended, generatedAt: now, text: "No Home events are scheduled.", eventCount: 0)
        assert(restarted.prepare(noPlan), "A truthful no-plan brief is valid")

        // Explicit future-day preparation is permitted, but not future-day narration.
        let future = MeshMorningState(directory: directory.appendingPathComponent("future"), timeZone: zone, clock: { now })
        future.isPaused = { false }
        future.onDelivery = { deliveries.append($0) }
        future.intendedDate = date("2026-09-20T13:00:00Z")
        assert(future.prepare(artifact(day: "2026-09-20", generated: "2026-09-19T13:00:00Z", notBefore: "2026-09-20T13:00:00Z")))
        assert(future.arm() && !future.arrival(UUID()))
        assert(deliveries.count == before)
        now = date("2026-09-20T13:00:01Z")
        assert(!future.arrival(UUID()), "At delivery an overnight brief older than 24h is stale")
        assert(future.status.contains("24 hours"))
        future.disarm()
        assert(!future.armed)
        future.intendedDate = date("2026-09-21T13:00:00Z")
        assert(future.preparedBrief == nil && !future.armed)

        // Read-only import: bytes remain exactly unchanged.
        now = intended
        let imported = MeshMorningState(directory: directory.appendingPathComponent("import"), timeZone: zone, clock: { now })
        try FileManager.default.createDirectory(at: imported.defaultBriefURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(artifact())
        try bytes.write(to: imported.defaultBriefURL)
        assert(imported.importBrief())
        let afterImport = try Data(contentsOf: imported.defaultBriefURL)
        assert(afterImport == bytes)
        try Data("not-json".utf8).write(to: imported.defaultBriefURL)
        assert(!imported.importBrief() && imported.preparedBrief == nil)

        // An overnight arm may wait for publication; clock changes alone do nothing.
        now = date("2026-09-19T08:00:00Z")
        var queuedDeliveries = 0
        let queued = MeshMorningState(directory: directory.appendingPathComponent("queued"), timeZone: zone, clock: { now })
        queued.isPaused = { false }
        queued.onDelivery = { _ in queuedDeliveries += 1 }
        assert(queued.armAwaitingBrief() && queued.armed && queued.preparedBrief == nil)
        assert(!queued.refreshQueuedBrief() && queued.armed && queued.preparedBrief == nil)
        assert(!queued.arrival(UUID()) && queued.armed && queuedDeliveries == 0)
        try FileManager.default.createDirectory(at: queued.defaultBriefURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: queued.defaultBriefURL)
        assert(queued.refreshQueuedBrief() && queued.armed && queued.preparedBrief != nil)
        let beforeNineTrigger = UUID()
        assert(!queued.arrival(beforeNineTrigger) && queued.armed)
        try FileManager.default.removeItem(at: queued.defaultBriefURL)
        assert(!queued.refreshQueuedBrief() && queued.armed && queued.preparedBrief != nil,
               "A missing publisher file must not erase a valid cached Home plan")
        now = intended
        assert(queuedDeliveries == 0 && !queued.arrival(beforeNineTrigger))
        assert(queued.arrival(UUID()) && queuedDeliveries == 1)

        let corruptQueued = MeshMorningState(directory: directory.appendingPathComponent("bad-queue"), timeZone: zone, clock: { now })
        corruptQueued.isPaused = { false }
        corruptQueued.onDelivery = { _ in queuedDeliveries += 1 }
        assert(corruptQueued.prepare(artifact()) && corruptQueued.armAwaitingBrief())
        try FileManager.default.createDirectory(at: corruptQueued.defaultBriefURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: corruptQueued.defaultBriefURL)
        assert(!corruptQueued.refreshQueuedBrief() && !corruptQueued.armed && corruptQueued.preparedBrief == nil)
        assert(!corruptQueued.arrival(UUID()) && queuedDeliveries == 1)
        corruptQueued.intendedDate = date("2026-09-18T13:00:00Z")
        assert(!corruptQueued.armAwaitingBrief(), "Cannot arm a yesterday session even without a brief")

        // Before-nine bypass exists only on an explicit manual replay call.
        now = date("2026-09-19T08:00:00Z")
        let earlyTest = MeshMorningState(directory: directory.appendingPathComponent("early-manual"), timeZone: zone, clock: { now })
        earlyTest.isPaused = { false }
        earlyTest.onDelivery = { _ in queuedDeliveries += 1 }
        assert(earlyTest.prepare(artifact(notBefore: "2026-09-19T08:00:00Z")))
        assert(!earlyTest.replay())
        assert(earlyTest.replay(allowBeforeNine: true) && queuedDeliveries == 2)
        assert(earlyTest.lastAttempt?.manualReplay == true)
        earlyTest.markDeliveryFinished()
        assert(!earlyTest.armAwaitingBrief(), "Explicit early replay currently consumes this day's automatic delivery")

        // A proven physical/app Return button is explicit consent, independent
        // of 9AM publication timing. Automatic/camera arrivals keep their gate.
        let userReturnDirectory = directory.appendingPathComponent("user-return")
        var userReturns = 0
        var userPaused = false
        let explicitReturn = MeshMorningState(directory: userReturnDirectory, timeZone: zone, clock: { now })
        explicitReturn.isPaused = { userPaused }
        explicitReturn.onDelivery = { _ in userReturns += 1 }
        assert(explicitReturn.prepare(artifact(notBefore: "2026-09-19T08:00:00Z")))
        assert(!explicitReturn.userReturn(UUID()) && userReturns == 0, "A button still requires explicit arm")
        assert(explicitReturn.armAwaitingBrief())
        assert(!explicitReturn.arrival(UUID()) && userReturns == 0, "Camera arrival still waits until nine")
        userPaused = true
        assert(!explicitReturn.userReturn(UUID()) && !explicitReturn.armed)
        userPaused = false
        assert(explicitReturn.armAwaitingBrief())
        let physicalButtonID = UUID()
        assert(explicitReturn.userReturn(physicalButtonID) && userReturns == 1)
        assert(explicitReturn.lastAttempt?.trigger == "user_return")
        assert(explicitReturn.lastAttempt?.manualReplay == false)
        assert(!explicitReturn.userReturn(physicalButtonID) && !explicitReturn.userReturn(UUID()) && userReturns == 1)
        explicitReturn.markDeliveryFinished()
        let buttonRestart = MeshMorningState(directory: userReturnDirectory, timeZone: zone, clock: { now })
        buttonRestart.isPaused = { false }
        buttonRestart.onDelivery = { _ in userReturns += 1 }
        assert(buttonRestart.prepare(artifact()) && !buttonRestart.armed)
        assert(!buttonRestart.armAwaitingBrief() && !buttonRestart.userReturn(UUID()) && userReturns == 1)
        let futureButton = MeshMorningState(directory: directory.appendingPathComponent("future-button"), timeZone: zone, clock: { now })
        futureButton.isPaused = { false }
        futureButton.onDelivery = { _ in userReturns += 1 }
        futureButton.intendedDate = date("2026-09-20T13:00:00Z")
        assert(futureButton.prepare(artifact(day: "2026-09-20", notBefore: "2026-09-20T13:00:00Z")))
        assert(futureButton.armAwaitingBrief() && !futureButton.userReturn(UUID()) && userReturns == 1,
               "Explicit Return must never speak tomorrow's plan today")

        let availability = MeshMorningState(directory: directory.appendingPathComponent("availability"), timeZone: zone, clock: { now })
        availability.isPaused = { false }
        availability.onDelivery = { _ in userReturns += 1 }
        assert(availability.prepare(artifact(notBefore: "2026-09-19T12:00:00Z")))
        assert(availability.armAwaitingBrief())
        assert(!availability.userReturn(UUID()) && userReturns == 1, "Explicit return still respects a future notBefore")
        now = date("2026-09-19T12:00:00Z") // 8AM: artifact available, automatic floor still9AM.
        assert(!availability.arrival(UUID()) && userReturns == 1)
        assert(availability.userReturn(UUID()) && userReturns == 2)

        let lateAvailability = MeshMorningState(directory: directory.appendingPathComponent("late-availability"), timeZone: zone, clock: { now })
        lateAvailability.isPaused = { false }
        lateAvailability.onDelivery = { _ in userReturns += 1 }
        assert(lateAvailability.prepare(artifact(notBefore: "2026-09-19T14:00:00Z")))
        assert(lateAvailability.armAwaitingBrief())
        now = intended
        assert(!lateAvailability.arrival(UUID()) && userReturns == 2, "Automatic arrival waits for max(9AM,notBefore)")
        now = intended

        // Integration contract: arm overnight, publish atomically after nine,
        // explicitly refresh on Return/Home, deliver once, restart without replay.
        now = date("2026-09-19T08:00:00Z")
        let publishedDirectory = directory.appendingPathComponent("published-after-nine")
        var publishedDeliveries = 0
        let waiting = MeshMorningState(directory: publishedDirectory, timeZone: zone, clock: { now })
        waiting.isPaused = { false }
        waiting.onDelivery = { _ in publishedDeliveries += 1 }
        assert(waiting.armAwaitingBrief())
        now = date("2026-09-19T13:01:00Z")
        assert(publishedDeliveries == 0 && waiting.armed)
        try FileManager.default.createDirectory(at: publishedDirectory, withIntermediateDirectories: true)
        let publishedBytes = try JSONEncoder().encode(artifact(generated: "2026-09-19T13:00:00Z"))
        try publishedBytes.write(to: waiting.defaultBriefURL, options: .atomic)
        assert(waiting.refreshQueuedBrief() && waiting.armed)
        assert(waiting.arrival(UUID()) && publishedDeliveries == 1)
        waiting.markDeliveryFinished()
        let afterPublishRestart = MeshMorningState(directory: publishedDirectory, timeZone: zone, clock: { now })
        afterPublishRestart.isPaused = { false }
        afterPublishRestart.onDelivery = { _ in publishedDeliveries += 1 }
        assert(!afterPublishRestart.armed && afterPublishRestart.hasAttemptForSelectedDay)
        assert(afterPublishRestart.refreshQueuedBrief())
        assert(!afterPublishRestart.armAwaitingBrief() && !afterPublishRestart.arrival(UUID()))
        assert(publishedDeliveries == 1)

        let swapDirectory = directory.appendingPathComponent("date-swap")
        let swapped = MeshMorningState(directory: swapDirectory, timeZone: zone, clock: { now })
        swapped.isPaused = { false }
        swapped.onDelivery = { _ in publishedDeliveries += 1 }
        assert(swapped.prepare(artifact()) && swapped.armAwaitingBrief())
        try FileManager.default.createDirectory(at: swapDirectory, withIntermediateDirectories: true)
        let wrongDateBytes = try JSONEncoder().encode(artifact(day: "2026-09-20", generated: "2026-09-19T13:00:00Z", notBefore: "2026-09-20T13:00:00Z"))
        try wrongDateBytes.write(to: swapped.defaultBriefURL, options: .atomic)
        assert(!swapped.refreshQueuedBrief() && !swapped.armed && swapped.preparedBrief == nil)
        assert(!swapped.arrival(UUID()) && publishedDeliveries == 1)
        now = intended

        // Corrupt receipts fail closed instead of forgetting an earlier greeting.
        try Data("corrupt-receipt".utf8).write(to: directory.appendingPathComponent("morning-receipts.jsonl"))
        let corrupt = MeshMorningState(directory: directory, timeZone: zone, clock: { now })
        corrupt.isPaused = { false }
        corrupt.onDelivery = { deliveries.append($0) }
        assert(corrupt.storageError != nil)
        assert(corrupt.prepare(artifact()) && !corrupt.arm() && !corrupt.replay())

        // A receipt write failure must prevent the callback.
        let badDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: badDirectory)
        let unwritable = MeshMorningState(directory: badDirectory, timeZone: zone, clock: { now })
        unwritable.isPaused = { false }
        unwritable.onDelivery = { deliveries.append($0) }
        assert(unwritable.prepare(artifact()) && unwritable.arm())
        assert(!unwritable.arrival(UUID()) && unwritable.storageError != nil)
        assert(deliveries.count == before)
        print("PASS: morning explicit arm/pause, waiting for publisher, queued refresh, 9AM automatic gate, explicit early user-return gate, Home schema/date/timezone/freshness, receipt before callback, restart suppression, replay, corrupt storage and write failure. No sensors, TTS, EventKit, network, or timers.")
    }
}
