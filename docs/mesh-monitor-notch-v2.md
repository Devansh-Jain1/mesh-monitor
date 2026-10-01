# Mesh Monitor notch: P0 restoration

## September 22 disclosure repair

The physical-notch caret remained unresponsive despite the earlier hosted-view
tests. Its glyph is painted by SwiftUI, while the native image-only NSButton has
no image. NSButtonCell returned an empty hit result for a real mouse event; the
external-display button, which has an image, returned a trackable result. The
previous tests used view hit testing plus `performClick`, bypassing that gate.

The new `MeshNotchPressCell` defines a trackable content area across the existing
44-point target, with disabled/hidden/outside rejection. A new cell-hit assertion
fails on the previous implementation and passes after this change in all four
hosted layouts. No appearance or sensor policy changes are needed.

The installed build 22 check then exposed a panel that enlarged while retaining
collapsed content. Build 23 commits `expanded` before resizing the panel, instead
of resizing from the property's `willSet` publisher. The controller fixture now
checks repeated expand/collapse rendering in an unshown panel. That hidden-panel
test also passes on the old resize path; installed UI verification is therefore
required to establish that the visible rendering problem is resolved.

These fixture events are constructed in memory and never posted to the OS.
The tests do not present windows, capture inputs, load models or play audio.

Installed verification: 0.6.11/build 23 was built from 47 hash-matched inputs,
signature-verified and installed with rollback. Computer Use activation of the
disclosure showed the actual Talk/Open app/Captions/Pause content, collapse
restored the compact view, repeated expansion worked, and Open app reopened the
dashboard. A screenshot confirmed the expanded rendering. Coordinate-based
pointer injection was unavailable for this nonstandard panel (`noWindowsAvailable`),
so these installed checks used the accessible button; the native mouse-cell gate
is covered separately by the failing-before/passing-after fixture. Physical
trackpad first-click and fullscreen behavior still need user confirmation.

Build receipt: `artifacts/mesh-monitor-build-20260922T051350Z-6ad57e/BUILD-RECEIPT.json`
(SHA-256 `081bf7db27a551451eb0f5ce0fa1c72045964839a7490c6022e22d278ac18dc3`).
The maintenance update left Mesh paused. No sensor, voice, model or wake-session
test was started. The user's task and history were retained.

## Findings from source and screenshots

The user-provided screenshots show the older green `M4 Local Realtime Voice Notch` shell, a displaced/clipped expanded panel, and an unresponsive right disclosure caret. Two concrete implementation issues were found:

1. **Right-wing hit testing is incorrect in the legacy shell.** `WorkMacNotchWingView.hitTest` compares `bounds.contains(point)` directly. AppKit supplies that point in the superview's coordinates. The left wing at x=0 can happen to work; the right wing at approximately x=windowWidth−34 rejects the ordinary click coordinates. The replacement converts the point from `superview` before testing it and accepts the first click while another app is active. An actual unattached AppKit button regression fixture covers this case.
2. **The full Mesh Monitor build did not include a notch.** Before this change, its build source list omitted the legacy notch and `MeshMonitorApp` never instantiated a notch controller. The new native app must explicitly own this controller rather than rely on a second, old app process.

The existing legacy source already includes `statusBar + 1`, `canJoinAllSpaces`, `canJoinAllApplications`, `fullScreenAuxiliary`, and `hidesOnDeactivate = false`. Therefore missing fullscreen flags are **not established as the historical cause** of the user's desktop-only behavior. Build identity, live window ordering, Spaces, and display placement still require the user's awake test. We do not claim that every fullscreen app or protected system surface was verified overnight.

Apple's relevant contracts: [NSView.hitTest](https://developer.apple.com/documentation/appkit/nsview/hittest(_:)) and [canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications).

## New controller

`ops/work_mac_copilot_app/MeshNotchController.swift` provides a nonactivating, transparent NSPanel with no implicit microphone or model startup. The design uses obsidian, cyan and violet, a compact state symbol, a large disclosure target, and a readable expanded card containing Talk, Open app, Captions, and Pause.

- Compact controls flank the physical cutout; hit areas are at least 44 points. Expanded content starts below the safe-area band.
- Display changes recompute geometry. The physical notch display is preferred unless the caller passes an explicit display ID. External displays get a centered software pill.
- Runtime states are explicit: mic off, starting, listening, thinking, speaking, captioning, paused, or needs attention. Root owns their truth and callbacks.
- Window policy joins normal Spaces and eligible other-app fullscreen spaces without activating Mesh Monitor. It stays below screen-saver/lock surfaces.
- Screen/session hiding notifications order the panel out. Read-only WindowServer session state also gates presentation; it never unlocks or wakes the display. A manual suspend is preserved across automatic session notifications.
- Controller initialization does not present anything. The quiet wake service must wait until an explicit permitted display event before calling `show`.
- No legacy x/y/width calibration is inherited; old offsets cannot displace the new panel.

## Integration API

```swift
let notch = MeshNotchController(actions: MeshNotchActions(
    onTalk: { /* explicit start/stop voice */ },
    onOpenApp: { /* open full application window */ },
    onCaptions: { /* open caption controls */ },
    onPause: { /* pause owned inputs and outputs */ }
))
notch.update(MeshNotchSnapshot(
    phase: .off,
    detail: "Press Talk to begin.",
    transcript: "",
    provider: "Codex",
    captionsEnabled: false,
    talkEnabled: true
))
notch.show()         // normal UI/user return only; constructor stays inert
notch.collapse()
notch.suspend()      // retains requested visibility; stays hidden
notch.resume()       // only re-presents in unlocked active session
notch.hide()         // clears requested visibility
```

Root must add this Swift file to the hashed build source list and retain the controller for the app lifetime. Refresh snapshots when runtime publishers change. There is no hard dependency on `MeshMonitor` and no microphone, camera, network, or process start in this module.

## Silent verification

```sh
swiftc -module-cache-path /private/tmp/mesh-notch-v2-module-cache \
  -target arm64-apple-macosx14.0 \
  ops/work_mac_copilot_app/MeshNotchController.swift \
  tests/mesh_notch_fixture.swift -o /private/tmp/mesh-notch-fixture
/private/tmp/mesh-notch-fixture
```

Fixture checks cutout avoidance, 44-point targets, expanded safe-area placement, negative-origin displays, display-size ranges, fullscreen/Spaces policy, appropriate window level, and the real offset-right-button hit-test regression. It creates no NSApplication or NSPanel, reads no current display, opens no window, and runs no audio.

Pending awake acceptance: correct compact location on the user's M4 display, caret click while Codex/another app is frontmost, continuity across normal/fullscreen Spaces, four explicit action callbacks, VoiceOver activation, and Talk's actual permission/listening/reply behavior. Do not label those live checks passed from fixture success.

## Build 24 repair checkpoint — 2026-09-22

Version 0.6.12/build 24 is installed. The user's recording showed that build 23's accessibility activation checks did not establish physical click success. `MeshNotchPressButton` now handles pointer press, drag cancellation, and release explicitly. The hosted interaction fixture passes release-inside activation, unmatched release rejection, drag-out cancellation, disabled-during-press cancellation, and independent accessibility activation across four layouts. These are component checks, not proof of WindowServer delivery from the user's trackpad.

`MeshApplicationChrome` creates standard menus when the maintenance/wake dashboard lacks them and removes menu-bar hiding presentation flags while Mesh Monitor is active in fullscreen. It leaves global macOS preferences untouched. Silent helper checks passed menu creation, idempotence, and preservation of unrelated presentation flags.

Build receipt: `artifacts/mesh-monitor-build-20260922T054419Z-5aabe4/BUILD-RECEIPT.json`. All 48 recorded source hashes matched before installation. Rollback/install receipt: `~/Library/Application Support/MeshMonitor/rollback/20260922T055153Z-9031f5e4f4834bd2ad7881e8d9759f0a/INSTALL-RECEIPT.json`.

Installed normal launch showed Paused, screen understanding Off, webcam not enabled, and the application menus present. Fullscreen was entered for inspection, but the captured app surface did not establish system-clock visibility. Further UI actions stopped when the app state changed during inspection. No voice, camera, or monitoring session was started. Physical caret clicks and fullscreen clock visibility remain unverified; do not report this candidate as fully accepted.
