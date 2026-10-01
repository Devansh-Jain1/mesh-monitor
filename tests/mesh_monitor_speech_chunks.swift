import Foundation
@main struct MeshSpeechChunkFixture {
    @MainActor static func main() {
        let longAnswer = (0..<2000).map { "word\($0)" }.joined(separator: " ")
        let paragraphs = "First paragraph.\n\nSecond paragraph.\tFinal sentence!"
        let unicode = String(repeating: "👩🏽‍💻café ", count: 300)
        for text in ["", "hello", paragraphs, longAnswer, unicode, String(repeating: "x", count: 2000)] {
            let chunks = MeshVoiceBridge.speechChunks(text)
            assert(chunks.allSatisfy { !$0.isEmpty && $0.count <= 480 })
            // Long words may be split for synthesis; no non-whitespace content disappears.
            let original = text.filter { !$0.isWhitespace }
            let recovered = chunks.joined().filter { !$0.isWhitespace }
            assert(recovered == original)
        }
        assert(MeshVoiceBridge.speechChunks(longAnswer).joined(separator: " ") == longAnswer)
        print("PASS full answers, paragraph whitespace, Unicode graphemes, long tokens and bounded nonempty chunks")
    }
}
