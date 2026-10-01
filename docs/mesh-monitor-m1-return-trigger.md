# Physical M1 return trigger

`MeshM1ReturnTrigger` is inert until `arm(sessionID:intendedDate:piName:piAddresses:)` is explicitly called. It does not capture a camera or microphone, invoke a model, press a button, change the M1 mode, or play audio. The parent owns the prepared brief, once-per-day delivery receipt, and voice activation after the physical return.

The selected day's arm writes one private, expiring marker on the known `mesh-m1` SSH target. The reviewed receiver hook must be installed first. While this marker is valid, a short physical AIY press from Dark routes to the actual desktop. HUD is a separate full-screen web surface and is not treated as the desktop. Invalid physical origin while armed must leave Dark unchanged; it must never fall back to launching a camera.

The observer polls an SSH-projected subset of `~/AIYStation/station-state.json` every two seconds. It validates a finalized, changed Dark → desktop receipt with the original short-toggle action, successful station result, authenticated Pi origin, exact expected peer, session ID, fresh detected/sent times, and event UUID. The SSH connection verifies the configured host key; no bearer token is read by Monitor. A receipt reflects the existing receiver's authentication decision, not independent hardware attestation.

Cold launch, first connection, reconnect, receiver restart, stale/out-of-order samples, long polling gaps, pending receipts, camera/HUD transitions, and repeated receipts do not emit a return event. A new baseline must be followed by a new physical edge. There is no 9 AM restriction: the parent can allow the user's explicit early return. `onReturn` includes the validated original origin for the existing Control Room session.

After that return, keep the observer armed for the active voice session. A fresh Dark observation ends the session through `onSessionEnded`, which the parent connects to stopping speech and microphone capture. Lost/invalid station reads, source restart, stale samples, expiry, or loss of the owned keep-awake process also end an active session. The observer stops before calling this hook, so reconnection cannot resume speech or listening. A new explicit arm is required. Before any successful return, reconnect still establishes a silent baseline.

Only while armed, an owned `caffeinate -i -w <MonitorPID>` prevents idle system sleep on the M4; it does not request display wake. `isReady` requires a fresh Dark baseline and the owned process. Disarm and end-of-day expiry stop observation and keep-awake, and remove only the matching session marker. An unreachable M1 retains its marker only until that marker's expiry. Closing or crashing Monitor never causes a synthetic return event.

Read-only preflight on September 19, 2026 verified M1 Python 3.9.6, working `zoneinfo`, America/New_York timezone, and the station remaining Dark/inactive. M1's current Tailscale inventory identified online `raspberrypi` at `100.64.0.10`. The checked-in Pi service targets M1 Tailscale `100.64.0.11:8791`; live Pi service inspection requires a Tailscale re-auth check and was not bypassed. No LAN peer was added from memory or guesswork.

The receiver patch must be reviewed, backed up, deployed, and reloaded separately. Verify the original source hash and Dark state immediately before replacing the file. Preserve a private timestamped backup, atomically install the generated source, then reload only `com.devansh.aiy-station-receiver`. Its source startup restores the persisted mode; shutdown ensures the private cover and stops its camera/HUD helpers. Read back the source hash, single receiver process, Dark/inactive state, and absent camera/HUD processes. Do not mutate station state or emulate the button as a deployment test. Rollback restores the source backup and reloads the same receiver while Dark.

Silent verification:

```sh
python3 -m unittest tests.test_mesh_m1_return -v
```

The fixture instantiates only the pure Swift gate with synthetic receipts. It does not instantiate the observer, open SSH, run caffeinate, read live apps, request sensor access, or produce audio. The physical wake test remains the user's next actual AIY short press.
