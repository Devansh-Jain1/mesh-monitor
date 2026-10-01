import Foundation

/// Pure audio endpointing. No device, process, disk, or permission work lives here.
struct MeshCaptionPacket: Sendable {
    let utteranceID: UUID
    let revision: Int
    let samples: [Float]
    let sampleRate: Double
    let isFinal: Bool
}

struct MeshCaptionSegmenter {
    private var sampleRate: Double = 0
    private var preRoll: [Float] = []
    private var samples: [Float] = []
    private var voiceFrames = 0
    private var silenceFrames = 0
    private var lastPartialCount = 0
    private var utteranceID = UUID()
    private var revision = 0
    private(set) var isSpeaking = false
    var retainedSampleCount: Int { samples.count + preRoll.count }

    mutating func append(_ input: [Float], sampleRate rate: Double) -> [MeshCaptionPacket] {
        guard rate.isFinite, rate >= 8_000, rate <= 192_000, !input.isEmpty else { return [] }
        if rate != sampleRate { reset(); sampleRate = rate }
        // Bound processing even if a producer unexpectedly submits a huge buffer.
        var results: [MeshCaptionPacket] = []
        for start in stride(from: 0, to: input.count, by: 2_048) {
            let chunk = Array(input[start..<min(start + 2_048, input.count)]).map { $0.isFinite ? $0 : 0 }
            let rms = sqrt(chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count))
            let audible = rms >= 0.006
            if !isSpeaking {
                preRoll += chunk
                let maximum = Int(rate * 0.35)
                if preRoll.count > maximum { preRoll.removeFirst(preRoll.count - maximum) }
                voiceFrames = audible ? voiceFrames + chunk.count : 0
                if voiceFrames >= Int(rate * 0.14) {
                    isSpeaking = true; samples = preRoll; preRoll.removeAll(keepingCapacity: true)
                    silenceFrames = 0
                }
            } else {
                samples += chunk
                silenceFrames = audible ? 0 : silenceFrames + chunk.count
                let final = silenceFrames >= Int(rate * 0.70) || samples.count >= Int(rate * 10)
                if final || samples.count - lastPartialCount >= Int(rate * 2) {
                    revision += 1
                    results.append(MeshCaptionPacket(utteranceID: utteranceID, revision: revision,
                        samples: samples, sampleRate: rate, isFinal: final))
                    lastPartialCount = samples.count
                    if final { resetUtterance() }
                }
            }
        }
        return results
    }

    mutating func reset() { sampleRate = 0; resetUtterance() }
    private mutating func resetUtterance() {
        preRoll.removeAll(keepingCapacity: false); samples.removeAll(keepingCapacity: false)
        voiceFrames = 0; silenceFrames = 0; lastPartialCount = 0
        isSpeaking = false; utteranceID = UUID(); revision = 0
    }
}

struct MeshCaptionLine: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let text: String
}

/// Guards against stale partials and bounds all retained text. Raw audio is never retained here.
struct MeshCaptionTranscript {
    private(set) var lines: [MeshCaptionLine] = []
    private(set) var partialText = ""
    private var finished: [UUID] = []
    private var currentID: UUID?
    private var revision = 0

    mutating func apply(_ text: String, packet: MeshCaptionPacket, now: Date = Date()) {
        guard !finished.contains(packet.utteranceID) else { return }
        if currentID == packet.utteranceID, packet.revision < revision { return }
        currentID = packet.utteranceID; revision = packet.revision
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        if packet.isFinal {
            partialText = ""; finished.append(packet.utteranceID)
            if finished.count > 128 { finished.removeFirst(finished.count - 128) }
            if !clean.isEmpty { lines.append(MeshCaptionLine(id: packet.utteranceID, timestamp: now, text: clean)) }
            while lines.count > 120 || lines.reduce(0, { $0 + $1.text.count }) > 24_000 { lines.removeFirst() }
        } else { partialText = clean }
    }
    mutating func discardPartial() { partialText = ""; currentID = nil; revision = 0 }
    mutating func clear() { self = Self() }
    var exportText: String { lines.map(\.text).joined(separator: "\n") }
}
