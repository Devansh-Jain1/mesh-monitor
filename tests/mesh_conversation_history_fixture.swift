import Foundation
import Darwin

@main struct ConversationHistoryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        var checks = 0
        func store(_ name: String) -> MeshConversationHistory { MeshConversationHistory(directory: root.appendingPathComponent(name)) }
        func write(_ data: Data, to url: URL, mode: Int = 0o600) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        func check(_ condition: @autoclosure () throws -> Bool) throws { let value = try condition(); assert(value) }
        func rejects(_ action: () throws -> Void) {
            do { try action(); assertionFailure("Invalid history accepted") }
            catch { assert(error is MeshConversationHistoryError) }
            checks += 1
        }
        let source = MeshMessage(id: UUID(), role: "You", text: "Exact words 👀 日本語 e\u{301}\nsecond line",
            evidence: "Original message + 1 selected image(s) + task context · Codex",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let missing = store("missing")
        try check(try missing.load().messages.isEmpty)
        assert(!fm.fileExists(atPath: missing.directory.path)); checks += 1
        assert(!MeshConversationHistory.storageEnabled(arguments: ["app", "--render-design-preview", "/tmp/example"], environment: [:]))
        assert(!MeshConversationHistory.storageEnabled(arguments: ["app", "--render-ui"], environment: [:]))
        assert(!MeshConversationHistory.storageEnabled(arguments: ["app"], environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]))
        assert(MeshConversationHistory.storageEnabled(arguments: ["app", "--quiet-launch"], environment: [:])); checks += 1

        let saved = try missing.save([source])
        assert(saved.messages == [source] && !saved.hasExcerpts)
        try check(try store("missing").load().messages == [source]); checks += 1
        let file = missing.directory.appendingPathComponent(MeshConversationHistory.filename)
        let originalBytes = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: originalBytes) as! [String: Any]
        assert(Set(object.keys) == ["schemaVersion", "messages"])
        let record = (object["messages"] as! [[String: Any]])[0]
        assert(Set(record.keys) == ["id", "role", "text", "evidence", "createdAt", "savedExcerpt"]); checks += 1
        try check((try fm.attributesOfItem(atPath: missing.directory.path)[.posixPermissions] as! NSNumber).intValue == 0o700)
        try check((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue == 0o600); checks += 1

        let many = (0..<80).map { MeshMessage(role: "Codex", text: "Message \($0)", evidence: "No images retained") }
        let recent = try missing.save(many)
        assert(recent.messages == Array(many.suffix(60)))
        try check(try missing.load().messages == recent.messages); checks += 1
        _ = try missing.save([])
        try check(try missing.load().messages.isEmpty); checks += 1
        let huge = MeshMessage(role: "Codex", text: String(repeating: "👀", count: 40_000), evidence: "Text only")
        let excerpt = try missing.save([huge])
        assert(excerpt.hasExcerpts && excerpt.messages[0].id == huge.id)
        assert(excerpt.messages[0].text.hasSuffix("[Saved excerpt — local history limit]"))
        assert(excerpt.messages[0].text.utf8.count <= MeshConversationHistory.maximumTextBytes)
        assert(!excerpt.messages[0].text.contains("\u{FFFD}")); checks += 1
        let dense = (0..<60).map { MeshMessage(role: "Codex", text: String(repeating: "\u{1}", count: 131_072), evidence: "Text only \($0)") }
        let byteBound = try missing.save(dense)
        assert(byteBound.messages.count < 60 && byteBound.messages.last?.id == dense.last?.id)
        try check(try Data(contentsOf: file).count <= MeshConversationHistory.maximumFileBytes); checks += 1

        let invalids: [Data] = [Data(), Data([0xFF, 0xFE]), Data("[]".utf8),
            Data("{\"schemaVersion\":2,\"messages\":[]}".utf8), Data("{\"schemaVersion\":1,\"messages\":{}}".utf8)]
        for (index, invalid) in invalids.enumerated() {
            let candidate = store("corrupt-\(index)")
            let target = candidate.directory.appendingPathComponent(MeshConversationHistory.filename)
            try write(invalid, to: target)
            rejects { _ = try candidate.load() }
            rejects { _ = try candidate.save([source]) }
            try check(try Data(contentsOf: target) == invalid)
            try candidate.clear()
            try check(try candidate.load().messages.isEmpty); checks += 1
        }
        for key in ["text", "createdAt", "savedExcerpt"] {
            var invalidRecord = record; invalidRecord[key] = ["wrong": "type"]
            let invalid = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "messages": [invalidRecord]])
            let candidate = store("wrong-type-\(key)")
            try write(invalid, to: candidate.directory.appendingPathComponent(MeshConversationHistory.filename))
            rejects { _ = try candidate.load() }
        }
        let duplicate = store("duplicates")
        rejects { _ = try duplicate.save([source, source]) }
        assert(!fm.fileExists(atPath: duplicate.directory.path))

        let tooLarge = store("too-large")
        let oversize = Data(repeating: 0x20, count: MeshConversationHistory.maximumFileBytes + 1)
        try write(oversize, to: tooLarge.directory.appendingPathComponent(MeshConversationHistory.filename))
        rejects { _ = try tooLarge.load() }
        rejects { _ = try tooLarge.save([source]) }
        try tooLarge.clear()
        try check(try tooLarge.load().messages.isEmpty); checks += 1

        let publicFile = store("public-file")
        try write(originalBytes, to: publicFile.directory.appendingPathComponent(MeshConversationHistory.filename), mode: 0o644)
        rejects { _ = try publicFile.load() }
        rejects { _ = try publicFile.save([source]) }
        let publicDirectory = store("public-directory")
        try fm.createDirectory(at: publicDirectory.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        rejects { _ = try publicDirectory.load() }
        rejects { _ = try publicDirectory.save([source]) }

        let target = root.appendingPathComponent("target.json")
        try write(originalBytes, to: target)
        let symlink = store("symlink-file")
        try fm.createDirectory(at: symlink.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createSymbolicLink(at: symlink.directory.appendingPathComponent(MeshConversationHistory.filename), withDestinationURL: target)
        rejects { _ = try symlink.load() }
        rejects { _ = try symlink.save([source]) }
        rejects { try symlink.clear() }
        try check(try Data(contentsOf: target) == originalBytes)
        let directoryLink = store("symlink-directory")
        try fm.createSymbolicLink(at: directoryLink.directory, withDestinationURL: missing.directory)
        rejects { _ = try directoryLink.load() }
        rejects { _ = try directoryLink.save([source]) }

        let hardlink = store("hardlink")
        try fm.createDirectory(at: hardlink.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.linkItem(at: target, to: hardlink.directory.appendingPathComponent(MeshConversationHistory.filename))
        rejects { _ = try hardlink.load() }
        rejects { _ = try hardlink.save([source]) }
        rejects { try hardlink.clear() }
        let fifo = store("fifo")
        try fm.createDirectory(at: fifo.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        assert(mkfifo(fifo.directory.appendingPathComponent(MeshConversationHistory.filename).path, 0o600) == 0)
        rejects { _ = try fifo.load() }
        rejects { _ = try fifo.save([source]) }
        let lockLink = store("lock-link")
        try fm.createDirectory(at: lockLink.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createSymbolicLink(at: lockLink.directory.appendingPathComponent(".conversation.lock"), withDestinationURL: target)
        rejects { _ = try lockLink.save([source]) }
        print("PASS \(checks) offline conversation history fixtures; synthetic temporary files only")
    }
}
