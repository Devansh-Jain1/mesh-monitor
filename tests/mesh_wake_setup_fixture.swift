import Darwin
import Foundation

@main
private struct MeshWakeSetupFixture {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/mesh-wake-setup-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = ISO8601DateFormatter().date(from: "2026-09-19T14:00:00Z")!
        let id = UUID()
        let arguments = ["fixture", "--consume-wake-setup", id.uuidString]
        assert(try! !MeshWakeSetup.consume(arguments: ["fixture"], directory: directory, now: now))
        assert(!FileManager.default.fileExists(atPath: directory.path))
        let descriptor = try MeshControlRoomFiles.directory(directory, create: true)
        defer { Darwin.close(descriptor) }
        func publish(idOverride: UUID? = nil, date: String = "2026-09-19", age: Double = 10,
                     lifetime: Double = 120, schema: String = "mesh.wake-setup.v1") throws {
            let formatter = ISO8601DateFormatter()
            let created = now.addingTimeInterval(-age)
            let value = MeshWakeSetup.Request(schema: schema, id: (idOverride ?? id).uuidString,
                date: date, createdAt: formatter.string(from: created),
                expiresAt: formatter.string(from: created.addingTimeInterval(lifetime)))
            try MeshControlRoomFiles.publish(JSONEncoder().encode(value), name: "pending-wake-setup.json", directoryFD: descriptor)
        }
        func rejected(_ operation: () throws -> Void) {
            do { try operation(); assertionFailure("Expected rejection") } catch { }
        }
        for args in [["fixture", "--consume-wake-setup"], ["fixture", "--consume-wake-setup", "invalid"],
                     arguments + ["--consume-wake-setup", id.uuidString]] {
            rejected { _ = try MeshWakeSetup.consume(arguments: args, directory: directory, now: now) }
        }
        for candidate in 0..<7 {
            switch candidate {
            case 0: try publish(idOverride: UUID())
            case 1: try publish(date: "2026-09-18")
            case 2: try publish(age: -1)
            case 3: try publish(age: 121)
            case 4: try publish(lifetime: 121)
            case 5: try publish(age: 10, lifetime: 10)
            default: try publish(schema: "another-schema")
            }
            rejected { _ = try MeshWakeSetup.consume(arguments: arguments, directory: directory, now: now) }
            assert(unlinkat(descriptor, "pending-wake-setup.json", 0) == 0)
        }
        try publish()
        let pendingPath = directory.appendingPathComponent("pending-wake-setup.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pendingPath.path)
        rejected { _ = try MeshWakeSetup.consume(arguments: arguments, directory: directory, now: now) }
        try FileManager.default.removeItem(at: pendingPath)
        try FileManager.default.createSymbolicLink(at: pendingPath, withDestinationURL: directory.appendingPathComponent("missing"))
        rejected { _ = try MeshWakeSetup.consume(arguments: arguments, directory: directory, now: now) }
        try FileManager.default.removeItem(at: pendingPath)
        try MeshControlRoomFiles.publish(Data(repeating: 0x20, count: 4_097), name: "pending-wake-setup.json", directoryFD: descriptor)
        rejected { _ = try MeshWakeSetup.consume(arguments: arguments, directory: directory, now: now) }
        try FileManager.default.removeItem(at: pendingPath)
        try publish()
        assert(try! MeshWakeSetup.consume(arguments: arguments, directory: directory, now: now))
        assert(try! !MeshWakeSetup.consume(arguments: arguments, directory: directory, now: now))
        try publish()
        rejected { _ = try MeshWakeSetup.consume(arguments: arguments, directory: directory, now: now) }
        assert(unlinkat(descriptor, "pending-wake-setup.json", 0) == 0)

        try MeshWakeSetup.publishStatus(["ready": false, "updatedAt": "synthetic"], directory: directory)
        try MeshWakeSetup.publishStatus(["ready": true, "updatedAt": "synthetic"], directory: directory)
        let bytes = try MeshControlRoomFiles.read("wake-readiness.json", directoryFD: descriptor, maximumBytes: 16_384)!
        assert((try! JSONSerialization.jsonObject(with: bytes) as! [String: Any])["ready"] as? Bool == true)
        try MeshWakeSetup.publishShutdown(["termination": "deadline", "m1Disarm": "unconfirmed"], directory: directory)
        let shutdown = try MeshControlRoomFiles.read("shutdown-receipt.json", directoryFD: descriptor, maximumBytes: 16_384)!
        assert((try! JSONSerialization.jsonObject(with: shutdown) as! [String: Any])["m1Disarm"] as? String == "unconfirmed")
        assert(try! MeshControlRoomFiles.read("wake-readiness.json", directoryFD: descriptor, maximumBytes: 16_384) == bytes)
        rejected { try MeshWakeSetup.publishStatus(["value": String(repeating: "x", count: 17_000)], directory: directory) }
        let target = directory.appendingPathComponent("wake-readiness.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        rejected { try MeshWakeSetup.publishStatus(["ready": false], directory: directory) }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: directory.appendingPathComponent("nonexistent"))
        rejected { try MeshWakeSetup.publishStatus(["ready": false], directory: directory) }
        print("PASS: no-flag no writes; explicit UUID/date/freshness gates; atomic one-shot consumption; no relaunch replay; bounded private atomic status. Synthetic temporary files only, no runtime actions.")
    }
}
