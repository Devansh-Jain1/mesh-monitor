import Foundation

@main
struct MeshM1ReturnFixture {
    static let session = UUID(uuidString: "3fdf1304-f336-4d47-924d-e50f729d63e5")!
    static let peer = "100.64.0.10"
    static let base = 1_790_000_000.0
    static func date(_ offset: Double) -> Date { Date(timeIntervalSince1970: base + offset) }
    static func gate(expires: Double = 100) -> MeshM1ReturnGate {
        MeshM1ReturnGate(sessionID: session, piName: "raspberrypi", piAddresses: [peer],
                         armedAt: date(0), expiresAt: date(expires))
    }
    static func sample(_ at: Double, _ mode: String, epoch: String = "1:start",
                       reason: String = "button_receipt", event: Bool = false,
                       edit: ((inout [String: Any]) -> Void)? = nil,
                       dataEdit: ((inout [String: Any]) -> Void)? = nil) -> MeshM1StationSample {
        let id = "raspberrypi-b8b3ad1e-d97f-47a7-99a9-c342c2c73867"
        var origin: [String: Any] = ["authenticated": true, "physical_pi": true, "peer_ip": peer,
            "pi": "raspberrypi", "detected_at": base + at - 0.5, "sent_at": base + at - 0.25,
            "previous_mode": "dark", "monitor_session_id": session.uuidString.lowercased()]
        edit?(&origin)
        let receipt: [String: Any] = ["event_id": id, "requested_action": "toggle", "target_mode": mode,
            "status": reason == "button_pending" ? "pending" : "final", "changed": true,
            "result": ["ok": true, "event_id": id, "mode": mode, "active": mode != "dark", "changed": true,
                       "return_origin": origin]]
        var data: [String: Any] = ["schema_version": 2, "source_epoch": epoch, "sampled_at": base + at,
            "mode": mode, "active": mode != "dark", "reason": reason, "ts": base + at,
            "receipts": event ? [receipt] : []]
        dataEdit?(&data)
        return try! JSONDecoder().decode(MeshM1StationSample.self, from: JSONSerialization.data(withJSONObject: data))
    }
    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func main() {
        var g = gate()
        expect(g.consume(sample(1, "dark"), now: date(1)) == nil, "initial Dark is baseline only")
        let proof = g.consume(sample(2, "desktop", event: true), now: date(2))
        expect(proof?.origin.peer_ip == peer && proof?.sessionID == session, "authenticated physical edge provides original proof")
        expect(proof?.sourceEpoch == "1:start", "return proof carries its receiver epoch")
        expect(g.sessionActive && !g.sessionEnded, "delivered return owns an active session")
        expect(g.consume(sample(3, "desktop", event: true, edit: { $0["detected_at"] = base + 1.5; $0["sent_at"] = base + 1.75 }), now: date(3)) == nil, "repeated Desktop does not emit")
        expect(g.sessionActive && g.activeReceiptID == proof?.receiptID && g.activeSourceEpoch == "1:start",
               "same-epoch fresh desktop poll keeps original physical session alive")
        _ = g.consume(sample(4, "dark"), now: date(4))
        expect(!g.sessionActive && g.sessionEnded, "fresh Dark ends the active session")
        expect(g.consume(sample(5, "desktop", event: true), now: date(5)) == nil, "same receipt cannot replay")
        expect(g.sessionEnded, "return after ending never auto-rearms")

        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        _ = g.consume(sample(2, "desktop", event: true), now: date(2)); g.disconnected()
        expect(g.sessionEnded && !g.sessionActive, "disconnect ends active session immediately")
        expect(g.consume(sample(3, "desktop", event: true), now: date(3)) == nil, "reconnect cannot resume stopped voice")
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        _ = g.consume(sample(2, "desktop", event: true), now: date(2))
        _ = g.consume(sample(3, "dark", epoch: "2:restart"), now: date(3))
        expect(g.sessionEnded, "fresh Dark from restarted source stops safely")
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        _ = g.consume(sample(2, "desktop", event: true), now: date(2))
        _ = g.consume(sample(3, "desktop", epoch: "2:restart"), now: date(3))
        expect(g.sessionEnded, "source restart cannot preserve unverifiable active voice")
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        _ = g.consume(sample(2, "desktop", event: true), now: date(2))
        _ = g.consume(sample(3, "desktop"), now: date(20))
        expect(g.sessionEnded, "stale read ends active session")
        g = gate(expires: 3); _ = g.consume(sample(1, "dark"), now: date(1))
        _ = g.consume(sample(2, "desktop", event: true), now: date(2))
        _ = g.consume(sample(3, "desktop"), now: date(3))
        expect(g.sessionEnded, "expiry ends active session")


        // A Desktop poll alone is insufficient: preserve the original proof and continuous history.
        let returned = sample(2, "desktop", event: true)
        let originalReceipts = (try! JSONSerialization.jsonObject(with: JSONEncoder().encode(returned)) as! [String: Any])["receipts"] as! [[String: Any]]
        func stillDesktop(_ at: Double, extra: [[String: Any]] = [], reason: String = "button_receipt") -> MeshM1StationSample {
            sample(at, "desktop", reason: reason, dataEdit: { value in
                value["ts"] = base + 2
                value["receipts"] = originalReceipts + extra
            })
        }
        func changedReceipt(mode: String, status: String = "final") -> [String: Any] {
            let id = "raspberrypi-\(UUID().uuidString.lowercased())"
            return ["event_id": id, "requested_action": "toggle", "target_mode": mode,
                "status": status, "changed": true,
                "result": ["ok": true, "event_id": id, "mode": mode, "active": mode != "dark", "changed": true]]
        }
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1)); _ = g.consume(returned, now: date(2))
        _ = g.consume(stillDesktop(5), now: date(5))
        expect(g.sessionActive && !g.sessionEnded, "fresh exact original receipt remains live")
        _ = g.consume(stillDesktop(19), now: date(19))
        expect(g.sessionEnded && !g.sessionActive, "more than twelve seconds between polls ends session even with fresh Desktop state")

        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1)); _ = g.consume(returned, now: date(2))
        _ = g.consume(stillDesktop(4, extra: [changedReceipt(mode: "dark"), changedReceipt(mode: "desktop")]), now: date(4))
        expect(g.sessionEnded && !g.sessionActive, "unseen Dark to Desktop bounce cannot preserve the old session")

        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1)); _ = g.consume(returned, now: date(2))
        _ = g.consume(sample(3, "desktop"), now: date(3))
        expect(g.sessionEnded, "receipt retention loss ends the session")

        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1)); _ = g.consume(returned, now: date(2))
        _ = g.consume(stillDesktop(3, reason: "button_pending"), now: date(3))
        expect(g.sessionEnded, "pending station transition stops active speech without waiting for completion")

        for mode in ["camera", "hud"] {
            g = gate(); _ = g.consume(sample(1, "dark"), now: date(1)); _ = g.consume(returned, now: date(2))
            _ = g.consume(sample(3, mode, dataEdit: { $0["receipts"] = originalReceipts }), now: date(3))
            expect(g.sessionEnded, "leaving Desktop ends active session even without a Dark sample")
        }

        g = gate()
        expect(g.consume(sample(1, "desktop", event: true), now: date(1)) == nil, "cold Desktop does not emit")
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1)); g.disconnected()
        expect(g.consume(sample(2, "desktop", event: true), now: date(2)) == nil, "reconnect is baseline only")
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        expect(g.consume(sample(2, "desktop", epoch: "2:restart", event: true), now: date(2)) == nil, "receiver restart is baseline only")
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        expect(g.consume(sample(15, "desktop", event: true), now: date(15)) == nil, "long poll gap is baseline only")
        g = gate(); _ = g.consume(sample(2, "dark"), now: date(2))
        expect(g.consume(sample(1, "desktop", event: true), now: date(3)) == nil, "out of order sample resets baseline")
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        expect(g.consume(sample(2, "desktop", event: true), now: date(20)) == nil, "stale read cannot emit")
        expect(g.consume(sample(21, "desktop", event: true), now: date(21)) == nil, "recovery after stale read cannot emit")

        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        expect(g.consume(sample(2, "desktop", reason: "button_pending", event: true), now: date(2)) == nil, "pending mode cannot emit")
        expect(g.consume(sample(3, "desktop", event: true), now: date(3)) != nil, "final receipt after pending edge emits once")
        g = gate(); _ = g.consume(sample(1, "dark", event: true), now: date(1))
        expect(g.consume(sample(2, "desktop", event: true), now: date(2)) == nil, "preexisting receipt cannot emit")

        let rejected: [(String, (inout [String: Any]) -> Void)] = [
            ("unauthenticated", { $0["authenticated"] = false }),
            ("synthetic", { $0["physical_pi"] = false }),
            ("wrong peer", { $0["peer_ip"] = "192.168.1.37" }),
            ("wrong device", { $0["pi"] = "laptop" }),
            ("wrong session", { $0["monitor_session_id"] = UUID().uuidString }),
            ("wrong previous mode", { $0["previous_mode"] = "camera" }),
            ("before arm", { $0["detected_at"] = base - 1 }),
            ("future detected", { $0["detected_at"] = base + 10; $0["sent_at"] = base + 10 }),
            ("future sent", { $0["sent_at"] = base + 10 }),
        ]
        for (label, edit) in rejected {
            g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
            expect(g.consume(sample(2, "desktop", event: true, edit: edit), now: date(2)) == nil, label)
        }
        for mode in ["hud", "camera"] {
            g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
            expect(g.consume(sample(2, mode, event: true), now: date(2)) == nil, "other mode is not Desktop return")
        }
        g = gate(); _ = g.consume(sample(1, "dark"), now: date(1))
        expect(g.consume(sample(2, "desktop", reason: "startup_reconciled", event: true), now: date(2)) == nil, "startup reconciliation cannot emit")
        g = gate(expires: 2); _ = g.consume(sample(1, "dark"), now: date(1))
        expect(g.consume(sample(2, "desktop", event: true), now: date(2)) == nil, "date arm expires before any edge")
        print("PASS: synthetic physical-return gate: baseline, Desktop, proof, replay, continuous same-epoch liveness, missed bounce, receipt retention, disconnect, restart, stale, pending, origin, expiry")
    }
}
