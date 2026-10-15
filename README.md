# Mesh Monitor

A native macOS research prototype exploring local visual AI, voice interaction,
and user-controlled focus support. Built with Swift/AppKit and SwiftUI, it brings
screen observation, conversation, optional camera inputs, and explicit model and
permission state into a desktop companion.

## Local AI, with observable boundaries

- **Liquid AI vision:** `LFM2.5-VL-3B-Q4_K_M` with a separate vision projector,
  served locally through llama.cpp. Screen observations use a constrained JSON
  contract: `observation`, `relation`, and `reasoning`.
- **Grounded interpretation:** observations distinguish `on_task`,
  `possible_detour`, and `unclear`. The prompt explicitly rejects inferring
  emotion, comprehension, or task completion from a screen or face.
- **Voice:** local Parakeet speech input and Kokoro speech output, with distinct
  readiness and lifecycle states.
- **Provider choice:** local visual-model and Codex conversation adapters are
  separate. Selecting an off-device provider is not the same privacy boundary as
  local inference; review configuration before sharing screen or voice context.
- **Engineering:** bounded inputs, structured-output validation, stale-state
  handling, explicit permissions, recovery behavior, and focused regression
  fixtures rather than treating model output as unquestionable truth.

## Status and evidence

This is an inspectable development snapshot, **not a production-ready focus
detector or a one-command install**. Component tests do not prove that the app
improves attention or that every physical interaction works. Known gaps include
notch click delivery, attended gaze calibration, reminder-state integration, and
clean-machine resource provisioning. See [HANDOFF.md](HANDOFF.md) for the exact
boundaries and [VALIDATION.txt](VALIDATION.txt) for historical test output.

Publication-preparation check (October 15, 2026): the local-voice static suite
passed 11 of 12 checks; the remaining check could not run because this standalone
snapshot omits `contracts/voice-session-event.schema.json`. The historical
validation file is not a claim that every current test passes. No hardware or
installed-app validation was performed for this documentation update.

The project explores a practical question: how can a small local model provide
useful context without turning uncertain observations into claims about a person?

## Snapshot provenance

Current Mesh Monitor source snapshot, including uncommitted work, exported from the Mesh Factory development checkout on October 1, 2026. This is a standalone source handoff, not a release or a full backup of the parent repository. The source identifies version 0.6.23 / build 35.

Start with [HANDOFF.md](HANDOFF.md) for architecture, prompts, known defects, and next work. `SOURCE-MANIFEST.json` records the originating commit and per-file hashes. Earlier design documents are historical and are not proof of current behavior.

## Included

- Native macOS app, notch, focus coach, screen observation, conversation, local speech workers, calendar adapter, camera/NeoCursor adapters, M1 helpers, build/install scripts, and focused fixtures/tests.
- Legacy native source needed to understand the original voice/notch implementation and its tests.
- Current source changes that had not been committed in the parent checkout.

## Not included

Personal screenshots, audio/video, transcripts, calendar exports, trial observations, runtime state, credentials, device configuration, model weights, compiled apps, and unrelated Mesh Factory history are excluded. This repository does not grant access to those resources.

## Build prerequisites and limitations

Apple Silicon macOS with Xcode command-line tools is required for Swift/AppKit tests and builds. Python 3 and Node.js run the respective test suites.

The existing builder still requires a resource-donor app with bundle ID `com.devansh.m4-local-voice-notch`, containing `M4ParakeetWorker`, `kokoro.onnx`, `kokoro-config.json`, `af_bella.bin`, and `kokoro_onnx_worker.py`. These binaries/weights are not bundled here. Therefore this is NOT yet a clean-machine, one-command build. Provisioning and third-party license verification are outstanding.

```sh
python3 ops/build_mesh_monitor.py --resource-app '/path/to/Mesh Monitor.app'
python3 -m unittest discover -s tests -p 'test_mesh_focus_coach.py' -v
node --test tests/test_neocursor_calibration.cjs
```

Do not run installers or recovery-service scripts just to inspect the code. They can change the local installed app and background service. Installation requires the builder's receipt workflow; see script `--help`.

Source availability does not grant an open-source license to original project
code. No new license is granted here. Third-party components, SDKs, and model
weights remain subject to their respective terms; provision required assets
separately and review their licenses before redistribution.

Private peer addresses in code/examples were replaced with placeholder addresses in 100.64.0.0/10. Configure actual peers explicitly before using remote adapters.
