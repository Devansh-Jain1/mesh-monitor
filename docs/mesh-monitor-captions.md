# Local captions and transcription

`MeshTranscription` is a separate input mode. Opening its page, constructing the model, showing captions, and launching Mesh Monitor do not request permission, capture audio, start a model, or speak. Only an explicit **Start captions** action starts capture. Root coordination must stop conversation before starting captions and stop captions on Voice, Night, Pause, app termination, or the physical AIY session ending.

- **Microphone** transcribes the M4's current microphone input using AVAudioEngine. It requests microphone access on explicit start when needed.
- **Mac audio** uses ScreenCaptureKit system audio. It excludes Mesh Monitor's own process audio, registers only an audio output, and does not receive image frames or call screenshot APIs. macOS requires Screen & System Audio Recording permission for this API; missing access is explained and surfaced on explicit start. It currently captions the Mac audio mix, not a separately selected app.
- English transcription uses the bundled Parakeet worker and existing local model. There is no TTS, agent request, network request, or automatic clipboard/export behavior.

A lightweight level gate keeps silence out of inference. Cumulative utterance audio produces revisable partial text after approximately two seconds, with final text after 0.7 seconds of silence or a ten-second maximum utterance. These are scheduling parameters, not measured end-to-end latency. Music, noise, names, and overlapping speech can still transcribe incorrectly. This is a local ASR transcript, not a verified closed-caption track.

Only one inference is active. Obsolete queued partials are coalesced; the four-item queue fails visibly if inference falls behind. Finals are not silently dropped to mask overload. A 45-second worker startup/request deadline surfaces an error. The model exposes input level, partial text, final lines, status, and last inference time.

Raw audio is bounded in memory and written only for the active local worker request, in a fresh private 0700 temporary directory with 0600 WAVs. A completed request removes its WAV. Stop immediately rejects capture/callbacks, stops capture and the owned worker, clears queued audio, and removes the session directory. It discards unfinished partial text. Captions retain at most 120 finalized lines / 24,000 characters in memory, with a 2,000-character cap per line. Copy/export uses finalized text only, initiated by an explicit UI action. Clear invalidates outstanding work so a late response cannot repopulate the cleared transcript.

The presentation API includes `largeText` and `highContrast` (both default on). The UI can expose final text with selectable text, revisable partials separately, and a floating captions panel. Showing a panel must not start capture by itself.

## Verification

`tests/mesh_captions_fixture.swift` runs synthesized numeric samples and inert model lifecycle checks. It verifies silence bounds, partial/final separation, final deduplication, stale partial suppression, ten-second audio bounds, text limits, and inactive construction / repeated stop / clear. It performs no sensor access, model launch, permission prompts, audio playback, or network access.

```sh
xcrun swiftc -module-cache-path /private/tmp/mesh-caption-module-cache \
  -target arm64-apple-macos14.0 -parse-as-library \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
  ops/work_mac_copilot_app/MeshCaptionCore.swift \
  ops/work_mac_copilot_app/MeshTranscription.swift \
  tests/mesh_captions_fixture.swift -o /private/tmp/mesh-captions-fixture
/private/tmp/mesh-captions-fixture
```

Build/typecheck and synthetic tests pass. Microphone and Mac-audio physical acceptance are deliberately pending the user's wake test; no overnight capture or playback was performed.

API reference: [Apple ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos).
