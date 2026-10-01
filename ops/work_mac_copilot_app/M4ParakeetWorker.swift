@preconcurrency import AVFoundation
import FluidAudio
import Foundation

private struct WorkerRequest: Decodable {
    let id: String
    let input: String
}

private struct WorkerResponse: Encodable {
    let id: String?
    let event: String?
    let ok: Bool?
    let text: String?
    let confidence: Float?
    let durationMS: Int?
    let inferenceMS: Int?
    let engine: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, event, ok, text, confidence, engine, error
        case durationMS = "duration_ms"
        case inferenceMS = "inference_ms"
    }
}

private func writeLine(_ response: WorkerResponse) {
    guard let data = try? JSONEncoder().encode(response) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

@main
struct M4ParakeetWorker {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            writeLine(WorkerResponse(
                id: nil, event: nil, ok: false, text: nil, confidence: nil,
                durationMS: nil, inferenceMS: nil, engine: nil,
                error: "usage: M4ParakeetWorker <model-directory>"
            ))
            return
        }

        let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        let manager = AsrManager(config: ASRConfig(
            tdtConfig: TdtConfig(blankId: AsrModelVersion.v3.blankId),
            encoderHiddenSize: AsrModelVersion.v3.encoderHiddenSize,
            melChunkContext: true,
            dualDecodeArbitration: false
        ))
        do {
            let models = try await AsrModels.load(
                from: modelDirectory,
                version: .v3,
                encoderPrecision: .int8
            )
            try await manager.loadModels(models)
            writeLine(WorkerResponse(
                id: nil, event: "ready", ok: true, text: nil,
                confidence: nil, durationMS: nil, inferenceMS: nil,
                engine: "fluidaudio_parakeet_tdt_0.6b_v3_int8", error: nil
            ))
        } catch {
            writeLine(WorkerResponse(
                id: nil, event: "failed", ok: false, text: nil,
                confidence: nil, durationMS: nil, inferenceMS: nil,
                engine: "fluidaudio_parakeet_tdt_0.6b_v3_int8",
                error: error.localizedDescription
            ))
            return
        }

        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONDecoder().decode(WorkerRequest.self, from: data)
            else { continue }
            let startedAt = Date()
            do {
                var decoderState = TdtDecoderState.make(
                    decoderLayers: await manager.decoderLayerCount
                )
                let result = try await manager.transcribe(
                    URL(fileURLWithPath: request.input),
                    decoderState: &decoderState,
                    language: .english
                )
                writeLine(WorkerResponse(
                    id: request.id, event: nil, ok: true,
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: result.confidence,
                    durationMS: Int(result.duration * 1_000),
                    inferenceMS: Int(Date().timeIntervalSince(startedAt) * 1_000),
                    engine: "fluidaudio_parakeet_tdt_0.6b_v3_int8", error: nil
                ))
            } catch {
                writeLine(WorkerResponse(
                    id: request.id, event: nil, ok: false, text: nil,
                    confidence: nil, durationMS: nil,
                    inferenceMS: Int(Date().timeIntervalSince(startedAt) * 1_000),
                    engine: "fluidaudio_parakeet_tdt_0.6b_v3_int8",
                    error: error.localizedDescription
                ))
            }
        }
        await manager.cleanup()
    }
}
