import AppKit
import Foundation
import ImageIO

struct M4LocalVoiceReply {
    let text: String
    let brainID: String
    let screenContextUsed: Bool
    let inferenceMS: Int
    let screenEvidence: [String]
}
protocol M4LocalVoiceBrainPort { func respond(to transcript: String) async throws -> M4LocalVoiceReply }

@main struct FocusContractTests {
    static func main() throws {
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let valid: [String: Any] = ["observation": "Reading a task-related document.", "relation": "on_task", "reasoning": "The visible activity matches the supplied task."]
        var checks = 0
        func rejects(_ raw: String, finish: String? = "stop", errorContains: String? = nil) {
            do { _ = try M4FocusObservationContract.validate(raw, finishReason: finish); assertionFailure("Invalid fixture accepted") }
            catch { if let errorContains { assert(error.localizedDescription.contains(errorContains)) } }
            checks += 1
        }
        let accepted = try M4FocusObservationContract.validate(json(valid), finishReason: "stop")
        let decoded = try JSONSerialization.jsonObject(with: Data(accepted.utf8)) as! [String: String]
        assert(decoded["observation"] == valid["observation"] as? String); checks += 1
        for relation in ["on_task", "possible_detour", "unclear"] {
            var item = valid; item["relation"] = relation
            _ = try M4FocusObservationContract.validate(json(item), finishReason: "stop"); checks += 1
        }
        rejects(try json(valid), finish: "length", errorContains: "stopped before finishing")
        rejects(try json(valid), finish: nil)
        rejects(try json(valid), finish: "tool_calls")
        rejects("{\"observation\":\"truncated")
        rejects("```json\n" + (try json(valid)) + "\n```")
        rejects("[]")
        for field in ["observation", "relation", "reasoning"] {
            var item = valid; item.removeValue(forKey: field); rejects(try json(item))
            item = valid; item[field] = 12; rejects(try json(item))
        }
        for field in ["observation", "reasoning"] {
            var item = valid; item[field] = "  \n\t"; rejects(try json(item))
        }
        var item = valid; item["relation"] = "distracted"; rejects(try json(item))
        item = valid; item["extra"] = "not permitted"; rejects(try json(item))
        item = valid; item["observation"] = String(repeating: "a", count: 81); rejects(try json(item))
        item = valid; item["reasoning"] = String(repeating: "a", count: 113); rejects(try json(item))
        item = valid; item["observation"] = String(repeating: "e\u{301}", count: 41); rejects(try json(item))
        item = valid; item["observation"] = String(repeating: "界", count: 80)
        item["reasoning"] = String(repeating: "b", count: 112)
        _ = try M4FocusObservationContract.validate(json(item), finishReason: "stop"); checks += 1
        item = valid; item["observation"] = "A quoted \"diagram\" with 日本語."
        let escaped = try M4FocusObservationContract.validate(json(item), finishReason: "stop")
        let escapedDecoded = try JSONSerialization.jsonObject(with: Data(escaped.utf8)) as! [String: String]
        assert(escapedDecoded["observation"] == item["observation"] as? String); checks += 1
        // Exact model-template regression: response_format schemas are ignored
        // by LFM's specialized Jinja path, and top-level json_schema takes an
        // incompatible assistant-prefill path. Only an explicit USER grammar
        // reaches the sampler without consuming that prefix in llama.cpp 9430.
        var payload: [String: Any] = ["model": "lfm2.5-vl-3b-local", "max_tokens": 256,
            "response_format": ["type": "json_object"], "json_schema": ["type": "object"]]
        M4FocusObservationContract.applySamplingConstraint(to: &payload)
        let wire = try JSONSerialization.jsonObject(with: Data(json(payload).utf8)) as! [String: Any]
        assert(wire["response_format"] == nil && wire["json_schema"] == nil)
        assert(wire["model"] as? String == "lfm2.5-vl-3b-local" && wire["max_tokens"] as? Int == 256)
        assert(wire["grammar"] as? String == M4FocusObservationContract.samplingGrammar)
        checks += 1
        let grammar = M4FocusObservationContract.samplingGrammar
        assert(grammar.contains("character{1,80}") && grammar.contains("character{1,112}"))
        assert(!grammar.contains("<|im_start|>"))
        assert(grammar.contains(#"\"observation\""#) && grammar.contains(#"\"relation\""#) && grammar.contains(#"\"reasoning\""#))
        checks += 1
        // Retained raw synthetic failure from build13: finish_reason was stop,
        // but response_format had not enforced the required reasoning field.
        rejects(#"{"observation": "A Python test function is shown that checks if 2 + 2 equals 4.", "relation": "on_task"}"#)
        print("PASS \(checks) offline focus JSON contract fixtures; no model, network, capture, or audio")

        var imageChecks = 0
        func image(_ width: Int, _ height: Int, type: String = "public.jpeg", orientation: Int = 1, noise: Bool = false) -> Data {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let pixels: CGImage
            if noise {
                var bytes = [UInt8](repeating: 255, count: width * height * 4)
                var random: UInt32 = 7
                for index in 0..<(width * height) {
                    for channel in 0..<3 {
                        random = random &* 1_664_525 &+ 1_013_904_223
                        bytes[index * 4 + channel] = UInt8(truncatingIfNeeded: random >> 24)
                    }
                }
                pixels = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            } else {
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: Double(width) / 2, height: Double(height)))
                context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: Double(width) / 2, y: 0, width: Double(width) / 2, height: Double(height)))
                pixels = context.makeImage()!
            }
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: 0.98,
                kCGImagePropertyOrientation: orientation] as CFDictionary)
            assert(CGImageDestinationFinalize(destination))
            return data as Data
        }
        func decodedImage(_ bytes: Data) -> CGImage {
            CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(bytes as CFData, nil)!, 0, nil)!
        }
        func dominantColor(_ bytes: Data, x: Double, y: Double) -> String {
            let frame = decodedImage(bytes)
            let pixel = frame.cropping(to: CGRect(x: Int(Double(frame.width) * x), y: Int(Double(frame.height) * y), width: 1, height: 1))!
            let color = NSBitmapImageRep(cgImage: pixel).colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
            if color.redComponent > 0.7 && color.blueComponent < 0.3 { return "red" }
            if color.blueComponent > 0.7 && color.redComponent < 0.3 { return "blue" }
            return "other"
        }
        for (width, height, type, orientation) in [(320, 180, "public.jpeg", 1), (640, 480, "public.png", 1),
            (768, 384, "public.jpeg", 1), (1, 1, "public.png", 1), (320, 180, "public.jpeg", 6)] {
            let original = image(width, height, type: type, orientation: orientation)
            let prepared = try M4FocusImageBudget.prepare(original)
            assert(prepared == original, "A small image must retain its exact bytes")
            let frame = decodedImage(prepared)
            assert(frame.width == width && frame.height == height, "Small images must not be enlarged")
            imageChecks += 1
        }
        for (width, height, expectedWidth, expectedHeight) in [(1536, 768, 768, 384), (800, 1600, 384, 768), (1024, 1024, 768, 768)] {
            let original = image(width, height)
            let prepared = try M4FocusImageBudget.prepare(original)
            let frame = decodedImage(prepared)
            assert(frame.width == expectedWidth && frame.height == expectedHeight)
            assert(prepared != original && prepared.count <= M4FocusImageBudget.maximumResizedBytes)
            assert(CGImageSourceGetType(CGImageSourceCreateWithData(prepared as CFData, nil)!) as String? == "public.jpeg")
            imageChecks += 1
        }
        for (orientation, expectedTop) in [(6, "red"), (8, "blue")] {
            let prepared = try M4FocusImageBudget.prepare(image(1536, 768, orientation: orientation))
            let frame = decodedImage(prepared)
            assert(frame.width == 384 && frame.height == 768)
            assert(dominantColor(prepared, x: 0.5, y: 0.25) == expectedTop, "EXIF rotation must transform the pixels")
            let source = CGImageSourceCreateWithData(prepared as CFData, nil)!
            let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
            assert((metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
            imageChecks += 1
        }
        let mirrored = try M4FocusImageBudget.prepare(image(1536, 768, orientation: 2))
        assert(dominantColor(mirrored, x: 0.25, y: 0.5) == "blue", "EXIF mirroring must transform the pixels")
        imageChecks += 1
        for invalid in [Data(), Data("not an image".utf8), Data([0xFF, 0xD8, 0xFF, 0xDB]),
                        Data(repeating: 0, count: M4FocusImageBudget.maximumInputBytes + 1)] {
            do { _ = try M4FocusImageBudget.prepare(invalid); assertionFailure("Invalid image accepted") }
            catch { assert(error.localizedDescription.contains("could not be prepared")) }
            imageChecks += 1
        }
        let smallPNG = image(320, 180, type: "public.png")
        let pngURL = try M4FocusImageBudget.imageDataURL(M4FocusImageBudget.prepare(smallPNG))
        assert(pngURL == "data:image/png;base64," + smallPNG.base64EncodedString())
        imageChecks += 1
        let preparedJPEG = try M4FocusImageBudget.prepare(image(1536, 768))
        let jpegURL = try M4FocusImageBudget.imageDataURL(preparedJPEG)
        assert(jpegURL == "data:image/jpeg;base64," + preparedJPEG.base64EncodedString())
        imageChecks += 1
        do { _ = try M4FocusImageBudget.prepare(image(320, 180, type: "public.tiff")); assertionFailure("Unexpected image format admitted") }
        catch { assert(error.localizedDescription.contains("could not be prepared")) }
        imageChecks += 1
        let detailed = try M4FocusImageBudget.prepare(image(1024, 1024, noise: true))
        assert(detailed.count <= 512 * 1024 && decodedImage(detailed).width == 768)
        assert(detailed.base64EncodedString().utf8.count <= 699_052)
        imageChecks += 1
        print("PASS \(imageChecks) offline focus image budget fixtures; no model, network, capture, or audio")
    }
}
