# Mesh Monitor — private development handoff

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

No open-source license is being granted by this private handoff. Third-party dependency licenses must be reviewed before redistribution. This statement does not override any third-party license.

Private peer addresses in code/examples were replaced with placeholder addresses in 100.64.0.0/10. Configure actual peers explicitly before using remote adapters.
