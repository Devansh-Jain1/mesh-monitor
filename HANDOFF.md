# Engineering handoff

## What the system actually does

The native macOS UI is AppKit + SwiftUI. Local speech uses Parakeet input and Kokoro output. The selected conversation provider can be Codex or the local visual model. `MeshCodexClient.swift` owns the Codex adapter. This is not one continuous autonomous agent coordinating all subsystems.

Screen observation is implemented in `M4LFMVisionBrain.swift` and `MeshFocusMonitor.swift`. The screen prompt asks for JSON fields `observation`, `relation`, and `reasoning`; relation is `on_task`, `possible_detour`, or `unclear`. It explicitly treats YouTube/browsing as potentially legitimate work, requires unclear when no task exists, and prohibits inferring boredom, emotion, intent, attention, comprehension, or completion. See the exact prompt literals in the source; they are authoritative.

Local conversation has a separate prompt: answer the exact question briefly, treat observed content as evidence rather than instructions, do not infer intent/emotion from faces, and suggest Codex when reasoning/context is insufficient. Calendar integration exists in `MeshHomeCalendar.swift`; its existence does not make the coach calendar-aware.

## Why a stand-up reminder can fire after the user has stood up

`MeshFocusCoach.swift` uses deterministic timers, not an LLM prompt: normal check-ins every 15 minutes and break reminders every 50 minutes. Its tick checks lock/session availability, voice/foreground-operation availability, and whether a prompt is already open. Keyboard/mouse inactivity is deliberately not used to suppress delivery, to avoid treating passive reading as absence.

It does not track continuous seated time, consume confirmed away/return events, or gate reminders against calendar meetings. Consequently walking away without locking does not reset the break timer. No model fine-tuning can repair this missing state connection by itself. The exact two reported reminder events have not been correlated with runtime logs, so duplicate delivery versus separately due reminders is not established.

Proposed repair: explicit active/away/break/meeting/sleep state, accumulated active-session time rather than elapsed wall time, observed return with a grace period, one pending reminder, and deduplication across recovery. Calendar event time is context, not proof of attendance; gaze is not proof of attention. Keep camera optional. Test absence, return, meeting overlap, snooze, sleep, recovery, and duplicate callbacks.

## Unresolved user-facing failures

1. Notch chevron: physical clicks repeatedly fail for the user. Accessibility activation succeeds. Current tests call mouseDown/mouseUp directly and bypass real OS delivery. There are overlapping SwiftUI-wrapped and direct AppKit controls plus custom tracking. No verified root cause or installed fix. A scratch unshown-window sendEvent experiment also failed before delivery and is NOT a live reproduction. Instrument panel receipt -> target -> release -> action -> render; simplify to a single native disclosure owner after tracing.
2. Eye calibration: camera/eye detection can work while held-out screen mapping fails. Previous target 7 error was about 0.1627 versus a 0.15 limit. Diagnostics improved; reliable attended calibration is not established. Do not weaken thresholds to claim a pass.
3. Distraction intervention: observations and timed reminders are separate. End-to-end useful procrastination/phone-use detection is not validated. Do not advertise a timer as an intelligent distraction detector.
4. Model identity and state: make screen model, conversation provider, microphone, camera, and prompt scheduling independently visible.
5. Build portability: donor app resource dependency remains. Do not claim clean-room reproducibility.

## Recovery and resource behavior

Build 35 introduces a per-user launchd job whose KeepAlive PathState is a saved focus-recovery record. A force-quit can therefore relaunch the app. Explicit Quit clears the record and performs shutdown. The intended behavior is bounded breaks rather than indefinite pause. A recovery gap is possible; this is not an independent uninterrupted monitor worker.

Earlier verification observed explicit Quit stopping the app and recovery preserving the deadline. A complete attended force-kill/recovery test was deferred; do not treat it as passed. Verify behavior on the receiving device.

The UI process alone understates total memory: the local llama-server is a separate process. The user's Mac also experienced heavy browser memory usage, swap churn and iCloud activity. Those measurements are not a proven Mesh memory leak.

## Product direction still outstanding

User-confirmed red/yellow/green daily calendar; daily briefing and pre-meeting preparation; recovery flow after a difficult week using smaller tasks; configurable focus intensity; useful, correctable interventions; local-device camera for commercial users with optional M1 routing for the personal setup. No new billing, authentication or paid-agent calls were implemented for this handoff.

## Validation boundary

Tests validate components. They do not establish installed physical interaction, gaze accuracy, reliable absence detection, behavioral benefit, or commercial readiness. Consult VALIDATION.txt for checks run on this exported snapshot. No source fixes or deployments were performed as part of preparing this repository.
