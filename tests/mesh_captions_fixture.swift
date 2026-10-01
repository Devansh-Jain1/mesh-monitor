import Foundation

@main struct MeshCaptionsFixture {
    @MainActor static func main() {
        let rate = 16_000.0
        let voice = [Float](repeating: 0.08, count: 800)
        let silence = [Float](repeating: 0, count: 800)
        var segmenter = MeshCaptionSegmenter()
        // Several minutes of silence produce no requests and remain bounded.
        for _ in 0..<6_000 { assert(segmenter.append(silence, sampleRate: rate).isEmpty) }
        assert(segmenter.retainedSampleCount <= Int(rate * 0.35))
        var packets: [MeshCaptionPacket] = []
        for _ in 0..<65 { packets += segmenter.append(voice, sampleRate: rate) }
        assert(packets.contains { !$0.isFinal })
        for _ in 0..<16 { packets += segmenter.append(silence, sampleRate: rate) }
        assert(packets.filter(\.isFinal).count == 1)
        assert(Set(packets.map(\.utteranceID)).count == 1)
        assert(!segmenter.isSpeaking)
        var transcript = MeshCaptionTranscript()
        let partial = packets.first { !$0.isFinal }!
        let final = packets.first { $0.isFinal }!
        transcript.apply("hello", packet: partial)
        assert(transcript.partialText == "hello" && transcript.lines.isEmpty)
        transcript.apply("hello world", packet: final)
        transcript.apply("late partial should not reappear", packet: partial)
        assert(transcript.partialText.isEmpty && transcript.lines.map(\.text) == ["hello world"])
        transcript.apply("duplicate final", packet: final)
        assert(transcript.lines.count == 1)
        // Silence and invalid samples cannot create hallucinated requests.
        segmenter.reset()
        assert(segmenter.append([.nan, .infinity, -.infinity], sampleRate: rate).isEmpty)
        assert(segmenter.append(voice, sampleRate: .nan).isEmpty)
        assert(segmenter.append(voice, sampleRate: 0).isEmpty)
        // Continuous speech splits at a bounded duration and does not keep a growing recording.
        packets = []
        for _ in 0..<600 { packets += segmenter.append(voice, sampleRate: rate) }
        assert(packets.filter(\.isFinal).count >= 2)
        assert(packets.allSatisfy { $0.samples.count <= Int(rate * 10) + 2_048 })
        assert(segmenter.retainedSampleCount <= Int(rate * 10) + 2_048)
        // Text and history bounds also hold when a worker is verbose.
        for _ in 0..<150 {
            let packet = MeshCaptionPacket(utteranceID: UUID(), revision: 1,
                samples: [], sampleRate: rate, isFinal: true)
            transcript.apply(String(repeating: "x", count: 2_501), packet: packet)
        }
        assert(transcript.lines.count <= 120)
        assert(transcript.lines.reduce(0) { $0 + $1.text.count } <= 24_000)
        assert(transcript.lines.allSatisfy { $0.text.count <= 2_000 })
        transcript.clear(); assert(transcript.exportText.isEmpty)
        // Construction, stop, and clearing an inactive model are inert: no authorization,
        // capture, process launch, TTS, or files are requested on any of these paths.
        let model = MeshTranscription()
        assert(!model.isActive && model.lines.isEmpty && model.partialText.isEmpty)
        model.stop(); model.stop(); model.clear()
        assert(!model.isActive && model.level == 0 && model.exportText().isEmpty)
        assert(model.status == "Captions off")
        print("PASS: bounded silence, partial/final endpointing, stale-result suppression, continuous speech bounds, text retention, inert construction and idempotent stop. No sensors, workers, audio playback, or permissions invoked.")
    }
}
