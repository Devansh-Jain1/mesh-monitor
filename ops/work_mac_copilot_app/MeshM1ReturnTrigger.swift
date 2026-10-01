import Combine
import Darwin
import Foundation

struct MeshM1ReturnOrigin: Codable, Sendable, Equatable {
    let authenticated: Bool
    let physical_pi: Bool
    let peer_ip: String
    let pi: String
    let detected_at: Double
    let sent_at: Double
    let previous_mode: String
    let monitor_session_id: String
}

struct MeshM1ButtonResult: Codable, Sendable {
    let ok: Bool
    let event_id: String
    let mode: String?
    let active: Bool?
    let changed: Bool?
    let ignored: Bool?
    let return_origin: MeshM1ReturnOrigin?
}

struct MeshM1ButtonReceipt: Codable, Sendable {
    let event_id: String
    let requested_action: String
    let target_mode: String
    let status: String
    let changed: Bool
    let result: MeshM1ButtonResult?
}

struct MeshM1StationSample: Codable, Sendable {
    let schema_version: Int
    let source_epoch: String
    let sampled_at: Double
    let mode: String
    let active: Bool
    let reason: String
    let ts: Double
    let receipts: [MeshM1ButtonReceipt]
}

struct MeshM1ReturnEvent: Sendable {
    let receiptID: String
    let sessionID: UUID
    let occurredAt: Date
    let origin: MeshM1ReturnOrigin
    var sourceEpoch: String = ""
}

struct MeshM1ReturnLiveness: Sendable {
    let sessionID: UUID
    let receiptID: String
    let sourceEpoch: String
    let observedAt: Date
}

/// Observation-only transition gate. Reconnecting or cold-launching in Home never emits.
struct MeshM1ReturnGate {
    let sessionID: UUID
    let piName: String
    let piAddresses: Set<String>
    let armedAt: Date
    let expiresAt: Date?
    private(set) var lastMode: String?
    private(set) var sessionActive = false
    private(set) var sessionEnded = false
    private(set) var activeReceiptID: String?
    private(set) var activeOrigin: MeshM1ReturnOrigin?
    var activeSourceEpoch: String? { sessionActive ? lastSource : nil }
    private var lastSource: String?
    private var lastSampleAt: Double?
    private var lastReceivedAt: Date?
    private var knownReceipts: Set<String> = []
    private var deliveredReceipts: Set<String> = []

    init(sessionID: UUID, piName: String, piAddresses: Set<String>, armedAt: Date, expiresAt: Date? = nil) {
        self.sessionID = sessionID; self.piName = piName; self.piAddresses = piAddresses; self.armedAt = armedAt; self.expiresAt = expiresAt
    }

    mutating func disconnected() {
        if sessionActive { sessionActive = false; sessionEnded = true }
        lastMode = nil; lastSource = nil; lastSampleAt = nil; lastReceivedAt = nil; knownReceipts.removeAll()
    }

    mutating func consume(_ sample: MeshM1StationSample, now: Date) -> MeshM1ReturnEvent? {
        guard expiresAt.map({ now < $0 }) != false, sample.schema_version == 2, !sample.source_epoch.isEmpty,
              sample.sampled_at.isFinite, sample.ts.isFinite,
              (-1...10).contains(now.timeIntervalSince1970 - sample.sampled_at),
              ["dark", "hud", "camera", "desktop"].contains(sample.mode),
              sample.active == (sample.mode != "dark"), sample.receipts.count <= 64 else {
            disconnected(); return nil
        }
        // Stop is deliberately stricter than start: a fresh Dark state is enough,
        // including after a reconnect. An ended session can never re-arm itself.
        if sessionActive && sample.mode == "dark" {
            sessionActive = false; sessionEnded = true; lastMode = "dark"
            return nil
        }
        guard !sessionEnded else { return nil }
        let reset = lastSource == nil || lastSource != sample.source_epoch
            || lastReceivedAt.map({ !(0...12).contains(now.timeIntervalSince($0)) }) == true
            || lastSampleAt.map({ sample.sampled_at <= $0 }) == true
        if reset {
            if sessionActive { disconnected(); return nil }
            lastMode = sample.reason == "button_pending" ? nil : sample.mode
            lastSource = sample.source_epoch
            lastSampleAt = sample.sampled_at
            lastReceivedAt = now
            knownReceipts = Set(sample.receipts.map(\.event_id))
            return nil
        }
        lastSampleAt = sample.sampled_at
        lastReceivedAt = now
        if sessionActive {
            // Catch Dark -> Desktop bounces that both happened between polls.
            // Current mode alone cannot prove uninterrupted session continuity.
            guard sample.mode == "desktop", sample.reason != "button_pending",
                  let activeReceiptID, let activeOrigin,
                  let index = sample.receipts.firstIndex(where: { $0.event_id == activeReceiptID }),
                  sample.receipts[index].status == "final",
                  sample.receipts[index].result?.return_origin == activeOrigin,
                  sample.receipts[index].result?.ok == true,
                  !sample.receipts.dropFirst(index + 1).contains(where: { $0.status == "final" && $0.changed }) else {
                disconnected(); return nil
            }
        }
        // Desired mode changes before receipt finalization. Preserve Dark until the acknowledgement.
        guard sample.reason != "button_pending" else { return nil }
        let previous = lastMode
        lastMode = sample.mode
        defer { knownReceipts = Set(sample.receipts.filter { $0.status == "final" }.map(\.event_id)) }
        guard previous == "dark", sample.mode == "desktop", sample.reason == "button_receipt",
              sample.ts >= armedAt.timeIntervalSince1970,
              (-1...20).contains(now.timeIntervalSince1970 - sample.ts) else { return nil }
        for receipt in sample.receipts.reversed() {
            guard !knownReceipts.contains(receipt.event_id), !deliveredReceipts.contains(receipt.event_id),
                  receipt.status == "final", receipt.changed, receipt.target_mode == "desktop",
                  receipt.requested_action == "toggle",
                  let result = receipt.result, result.ok, result.ignored != true,
                  result.event_id == receipt.event_id, result.mode == "desktop", result.active == true,
                  result.changed == true, let origin = result.return_origin,
                  origin.authenticated, origin.physical_pi, origin.previous_mode == "dark",
                  origin.monitor_session_id.lowercased() == sessionID.uuidString.lowercased(),
                  origin.pi == piName, piAddresses.contains(origin.peer_ip),
                  origin.detected_at.isFinite, origin.sent_at.isFinite,
                  origin.detected_at >= armedAt.timeIntervalSince1970,
                  origin.sent_at >= origin.detected_at, origin.sent_at - origin.detected_at <= 30,
                  (-1...30).contains(now.timeIntervalSince1970 - origin.sent_at),
                  (-1...30).contains(now.timeIntervalSince1970 - origin.detected_at),
                  receipt.event_id.hasPrefix(piName + "-"),
                  UUID(uuidString: String(receipt.event_id.dropFirst(piName.count + 1))) != nil else { continue }
            deliveredReceipts.insert(receipt.event_id)
            sessionActive = true
            activeReceiptID = receipt.event_id; activeOrigin = origin
            return MeshM1ReturnEvent(receiptID: receipt.event_id, sessionID: sessionID,
                                     occurredAt: Date(timeIntervalSince1970: origin.detected_at), origin: origin,
                                     sourceEpoch: sample.source_epoch)
        }
        return nil
    }
}

enum MeshM1ReturnError: LocalizedError {
    case invalidSetup, unavailable, invalidState
    var errorDescription: String? {
        switch self {
        case .invalidSetup: "Choose today's morning session and the verified physical Pi address before arming."
        case .unavailable: "M1 return watcher cannot reach the installed station hook. No return was triggered."
        case .invalidState: "M1 station state could not be verified. Reconnecting establishes a new baseline only."
        }
    }
}

/// Injected by the offline lifecycle fixture; production uses only the fixed SSH operation below.
protocol MeshM1ReturnJob: AnyObject, Sendable {
    func run() async throws -> Data
    func cancel()
}

protocol MeshM1ReturnAwakeAssertion: AnyObject {
    var isRunning: Bool { get }
    func start() throws
    func cancel()
}

/// Explicitly armed, sensor-free observer of authenticated physical button receipts.
/// Does not press buttons, change modes, capture, play audio, or query a model.
@MainActor
final class MeshM1ReturnTrigger: ObservableObject {
    @Published private(set) var isArmed = false
    @Published private(set) var isReady = false
    @Published private(set) var status = "Physical M1 return trigger off"
    @Published private(set) var lastStationMode: String?
    @Published private(set) var lastSampleAt: Date?
    /// The remote acknowledgement outcome, separate from local capture/trigger shutdown.
    @Published private(set) var disarmStatus = "not_needed"
    var onReturn: ((MeshM1ReturnEvent) -> Void)?
    var onSessionEnded: (() -> Void)?
    var onSessionAlive: ((MeshM1ReturnLiveness) -> Void)?
    private var gate: MeshM1ReturnGate?
    private var sessionID: UUID?
    private var expiresAt: Date?
    private var generation = UUID()
    private var pollTask: Task<Void, Never>?
    private var readJob: (any MeshM1ReturnJob)?
    private var disarmTask: Task<Void, Never>?
    private var disarmJob: (any MeshM1ReturnJob)?
    private var disarmToken: UUID?
    private var keepAwake: (any MeshM1ReturnAwakeAssertion)?
    private let makeJob: (String, Data) -> any MeshM1ReturnJob
    private let makeKeepAwake: () -> any MeshM1ReturnAwakeAssertion

    init(makeJob: @escaping (String, Data) -> any MeshM1ReturnJob = { MeshM1ReturnSSH(operation: $0, payload: $1) },
         makeKeepAwake: @escaping () -> any MeshM1ReturnAwakeAssertion = { MeshM1ReturnCaffeinate() }) {
        self.makeJob = makeJob; self.makeKeepAwake = makeKeepAwake
    }

    func arm(sessionID: UUID, intendedDate: Date, piName: String, piAddresses: [String]) async throws {
        stop()
        let token = generation
        await finishStop()
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        let now = Date()
        let calendar = Calendar.current
        guard calendar.isDate(intendedDate, inSameDayAs: now), !piName.isEmpty,
              piName.count <= 64, piName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              !piAddresses.isEmpty, piAddresses.count <= 4,
              piAddresses.allSatisfy({ !$0.isEmpty && $0.count <= 64 && $0.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" } }),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            throw MeshM1ReturnError.invalidSetup
        }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let record: [String: Any] = ["schema_version": 1, "armed": true,
            "session_id": sessionID.uuidString.lowercased(), "intended_date": formatter.string(from: intendedDate),
            "time_zone": TimeZone.current.identifier, "created_at": now.timeIntervalSince1970,
            "expires_at": tomorrow.timeIntervalSince1970, "pi_name": piName, "pi_addresses": piAddresses]
        status = "Arming the physical M1 Return / Desktop button…"
        self.sessionID = sessionID
        disarmStatus = "not_needed"
        self.expiresAt = tomorrow
        let job = makeJob("arm", try JSONSerialization.data(withJSONObject: record))
        readJob = job
        do {
            let result = try await job.run()
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            guard (try? JSONSerialization.jsonObject(with: result) as? [String: Any])?["ok"] as? Bool == true else {
                throw MeshM1ReturnError.unavailable
            }
            let awake = makeKeepAwake()
            try awake.start()
            keepAwake = awake
            isArmed = true
            gate = MeshM1ReturnGate(sessionID: sessionID, piName: piName, piAddresses: Set(piAddresses), armedAt: now, expiresAt: tomorrow)
            status = "Armed · establishing M1 state baseline · camera and microphone stay off"
            readJob = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.generation == token, self.isArmed else { return }
                    await self.poll(token)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        } catch {
            if generation == token { stop(); status = error.localizedDescription }
            throw error
        }
    }

    func stop() {
        generation = UUID()
        pollTask?.cancel(); pollTask = nil
        readJob?.cancel(); readJob = nil
        gate = nil
        isArmed = false
        isReady = false
        keepAwake?.cancel(); keepAwake = nil
        expiresAt = nil
        lastStationMode = nil; lastSampleAt = nil
        status = "Physical M1 return trigger off"
        if let sessionID {
            self.sessionID = nil
            let payload = Data("{\"session_id\":\"\(sessionID.uuidString.lowercased())\"}".utf8)
            // Matches only this arm receipt; never removes a newer session's hook.
            // arm() awaits the previous disarm before acquiring another session, so
            // repeated stop calls retain this exact cleanup rather than cancelling it.
            let job = makeJob("disarm", payload), token = UUID()
            disarmJob = job; disarmToken = token; disarmStatus = "pending"
            disarmTask = Task { [weak self] in
                var confirmed = false
                do {
                    let bytes = try await job.run()
                    try Task.checkCancellation()
                    confirmed = try JSONDecoder().decode(MeshM1ReturnAcknowledgement.self, from: bytes).ok
                } catch { }
                guard let self, self.disarmToken == token else { return }
                self.disarmStatus = confirmed ? "confirmed" : "unconfirmed"
                self.disarmTask = nil; self.disarmJob = nil; self.disarmToken = nil
            }
        }
    }

    /// Called after synchronous stop(), including when Stop was already pressed earlier.
    /// A completed local task alone is not proof that the M1 acknowledged disarming.
    func finishStop() async {
        while let pending = disarmTask { await pending.value }
    }

    /// The app's outer termination deadline may revoke a slow pending transport.
    /// A late acknowledgement cannot upgrade a cancelled cleanup to confirmed.
    func cancelPendingDisarm() {
        guard let pending = disarmTask else { return }
        disarmStatus = "unconfirmed"
        disarmJob?.cancel(); pending.cancel()
    }

    private func poll(_ token: UUID) async {
        guard let expiresAt, Date() < expiresAt else {
            gate?.disconnected()
            let ended = gate?.sessionEnded == true
            stop(); status = "Physical return arm expired at the end of its selected day"
            if ended { onSessionEnded?() }; return
        }
        guard keepAwake?.isRunning == true else {
            gate?.disconnected()
            let ended = gate?.sessionEnded == true
            stop(); status = "Return trigger stopped because its keep-awake assertion ended"
            if ended { onSessionEnded?() }; return
        }
        let job = makeJob("read", Data())
        readJob = job
        do {
            let bytes = try await job.run()
            guard generation == token, isArmed, !Task.isCancelled else { return }
            let sample = try JSONDecoder().decode(MeshM1StationSample.self, from: bytes)
            let event = gate?.consume(sample, now: Date())
            if gate?.sessionEnded == true {
                stop(); status = "M1 returned to Dark or its active session could not be verified"
                onSessionEnded?(); return
            }
            lastStationMode = gate?.lastMode
            isReady = gate?.lastMode == "dark" && keepAwake?.isRunning == true
            lastSampleAt = Date(timeIntervalSince1970: sample.sampled_at)
            status = isReady ? "Ready · M1 Dark verified · waiting for physical Dark → Desktop · M4 stays awake" : (gate?.lastMode == nil ? "Armed · waiting for a fresh station baseline" : (gate?.sessionActive == true ? "AIY session active · microphone status is shown separately · Dark button ends session" : "Armed · M1 \(sample.mode) · waiting for Dark before the next physical return"))
            readJob = nil
            if let event { status = "Physical Dark → Desktop button receipt verified"; onReturn?(event) }
            if let gate, gate.sessionActive, let receipt = gate.activeReceiptID,
               let source = gate.activeSourceEpoch, let sessionID {
                onSessionAlive?(MeshM1ReturnLiveness(sessionID: sessionID, receiptID: receipt,
                    sourceEpoch: source, observedAt: Date(timeIntervalSince1970: sample.sampled_at)))
            }
        } catch {
            guard generation == token else { return }
            gate?.disconnected(); readJob = nil; lastStationMode = nil; isReady = false
            if gate?.sessionEnded == true {
                stop(); status = "M1 connection lost · active voice session stopped"
                onSessionEnded?(); return
            }
            status = "Armed but M1 unavailable · reconnect will not trigger a briefing"
        }
    }
}

private struct MeshM1ReturnAcknowledgement: Decodable { let ok: Bool }

private final class MeshM1ReturnCaffeinate: MeshM1ReturnAwakeAssertion {
    private var process: Process?
    var isRunning: Bool { process?.isRunning == true }
    func start() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        child.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); process = child
    }
    func cancel() { if process?.isRunning == true { process?.terminate() }; process = nil }
    deinit { cancel() }
}

final class MeshM1ReturnSSH: MeshM1ReturnJob, @unchecked Sendable {
    private let operation: String
    private let payload: Data
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let executableURL: URL
    private let injectedArguments: [String]?
    private let timeoutNanoseconds: UInt64
    private let didLaunch: (@Sendable () -> Void)?

    init(operation: String, payload: Data, executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
         arguments: [String]? = nil, timeoutNanoseconds: UInt64 = 9_000_000_000,
         didLaunch: (@Sendable () -> Void)? = nil) {
        self.operation = operation; self.payload = payload; self.executableURL = executableURL
        self.injectedArguments = arguments; self.timeoutNanoseconds = timeoutNanoseconds
        self.didLaunch = didLaunch
    }

    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if child?.isRunning == true { child?.terminate() }
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    let child = Process(); let input = Pipe(); let output = Pipe()
                    defer { try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
                    let encoded = Data(Self.script.utf8).base64EncodedString()
                    let code = "import base64;exec(base64.b64decode('\(encoded)'))"
                    let quoted = "'" + code.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    child.executableURL = executableURL
                    child.arguments = injectedArguments ?? ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                        "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=yes",
                        "mesh-m1", "/usr/bin/python3 -c " + quoted + " " + operation]
                    child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
                    // Deliberately retain this job while its exact owned process remains alive,
                    // even if the bounded read finishes before a stalled SSH process exits.
                    child.terminationHandler = { [self] ended in
                        lock.lock(); if process === ended { process = nil }; lock.unlock()
                        ended.terminationHandler = nil
                    }
                    lock.lock(); process = child; let stopped = cancelled; lock.unlock()
                    guard !stopped else {
                        child.terminationHandler = nil
                        lock.lock(); process = nil; lock.unlock()
                        continuation.resume(throwing: CancellationError()); return
                    }
                    do {
                        guard payload.count <= 4096,
                              fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
                              fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
                            throw MeshM1ReturnError.invalidState
                        }
                        try child.run()
                        didLaunch?()
                        // cancel() may have run after the pre-launch check but before run().
                        // It must not be followed by writing an arm payload to the new child.
                        lock.lock(); let stoppedAfterLaunch = cancelled; lock.unlock()
                        guard !stoppedAfterLaunch else { throw CancellationError() }
                        try input.fileHandleForWriting.write(contentsOf: payload)
                        try input.fileHandleForWriting.close()
                        let started = DispatchTime.now().uptimeNanoseconds
                        var bytes = Data(), chunk = [UInt8](repeating: 0, count: 4096), endedOutput = false
                        while true {
                            lock.lock(); let stopped = cancelled; lock.unlock()
                            guard !stopped else { throw CancellationError() }
                            guard DispatchTime.now().uptimeNanoseconds - started < timeoutNanoseconds else {
                                throw MeshM1ReturnError.unavailable
                            }
                            if !endedOutput {
                                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
                                if count > 0 {
                                    bytes.append(contentsOf: chunk.prefix(count))
                                    guard bytes.count <= 65_536 else { throw MeshM1ReturnError.invalidState }
                                    continue
                                }
                                if count == 0 { endedOutput = true }
                                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw MeshM1ReturnError.unavailable }
                            }
                            if !child.isRunning && endedOutput { break }
                            // Never block on readToEnd/waitUntilExit. HUP after early stdout close
                            // also needs a bounded wait, rather than spinning on a readable pipe.
                            if endedOutput { _ = Darwin.poll(nil, 0, 20) }
                            else {
                                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                                _ = Darwin.poll(&descriptor, 1, 20)
                            }
                        }
                        lock.lock(); let stopped = cancelled; lock.unlock()
                        guard !stopped, child.terminationStatus == 0 else { throw MeshM1ReturnError.unavailable }
                        continuation.resume(returning: bytes)
                    } catch {
                        cancel()
                        if !child.isRunning {
                            child.terminationHandler = nil
                            lock.lock(); if process === child { process = nil }; lock.unlock()
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    /// Fixed local-owner state paths only. No station method or HTTP mutation is invoked.
    private static let script = #"""
import json,os,sys,time,stat,subprocess,tempfile,uuid,fcntl
from contextlib import contextmanager
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
root=Path.home()/"AIYStation"
marker=Path.home()/".config/mesh-monitor/morning-return.json"
def read_private(path,limit):
 fd=os.open(str(path),os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
 try:
  s=os.fstat(fd)
  if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode&0o077 or not 0<s.st_size<=limit: raise ValueError("unsafe_state")
  raw=os.read(fd,limit+1)
  if len(raw)>limit:raise ValueError("oversize_state")
  return json.loads(raw)
 finally:os.close(fd)
@contextmanager
def marker_lock(create=False):
 # Arm and disarm cooperate on one stable inode; the lock itself is never removed.
 if create:marker.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
 parent=marker.parent.lstat()
 if not stat.S_ISDIR(parent.st_mode) or parent.st_uid!=os.getuid() or parent.st_mode&0o077:raise ValueError("unsafe_marker_directory")
 fd=os.open(str(marker.parent/"morning-return.lock"),os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
 try:
  info=os.fstat(fd)
  if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077 or info.st_nlink!=1:raise ValueError("unsafe_marker_lock")
  fcntl.flock(fd,fcntl.LOCK_EX)
  yield
 finally:os.close(fd)
op=sys.argv[1]
if op=="arm":
 record=json.loads(sys.stdin.buffer.read(4097))
 now=time.time()
 assert record.get("schema_version")==1 and record.get("armed") is True
 assert str(uuid.UUID(record["session_id"]))==record["session_id"]
 assert 0<record["expires_at"]-now<=90000 and abs(now-record["created_at"])<30
 assert datetime.now(ZoneInfo(record["time_zone"])).strftime("%Y-%m-%d")==record["intended_date"]
 assert isinstance(record.get("pi_addresses"),list) and 0<len(record["pi_addresses"])<=4
 # Deployment must install the reviewed receipt/routing hook before arming.
 assert "MESH_MONITOR_RETURN_HOOK_V1" in (root/"m1_station_receiver.py").read_text()
 with marker_lock(create=True):
  fd,tmp=tempfile.mkstemp(prefix=".morning-return-",dir=str(marker.parent))
  try:
   os.fchmod(fd,0o600)
   with os.fdopen(fd,"w") as f:json.dump(record,f);f.flush();os.fsync(f.fileno())
   os.replace(tmp,marker)
  finally:
   if os.path.exists(tmp):os.unlink(tmp)
 print(json.dumps({"ok":True}))
elif op=="disarm":
 record=json.loads(sys.stdin.buffer.read(4097))
 assert str(uuid.UUID(record["session_id"]))==record["session_id"]
 try:
  with marker_lock():
   old=read_private(marker,4096)
   if old.get("session_id")==record.get("session_id"):marker.unlink()
 except FileNotFoundError:pass
 print(json.dumps({"ok":True}))
elif op=="read":
 state=read_private(root/"station-state.json",1048576)
 result=subprocess.run(["/usr/bin/pgrep","-f","[m]1_station_receiver.py"],capture_output=True,text=True,timeout=2)
 pids=[line for line in result.stdout.splitlines() if line.isdigit()]
 assert len(pids)==1
 start=subprocess.run(["/bin/ps","-p",pids[0],"-o","lstart="],capture_output=True,text=True,timeout=2).stdout.strip()
 assert start
 receipts=[]
 for receipt in state.get("receipts",[])[-64:]:
  item={k:receipt.get(k) for k in ("event_id","requested_action","target_mode","status","changed")}
  r=receipt.get("result")
  if isinstance(r,dict):
   item["result"]={k:r[k] for k in ("ok","event_id","mode","active","changed","ignored","return_origin") if k in r}
  receipts.append(item)
 print(json.dumps({"schema_version":state.get("schema_version"),"source_epoch":pids[0]+":"+start,
 "sampled_at":time.time(),"mode":state.get("mode"),"active":state.get("active"),"reason":state.get("reason"),
 "ts":state.get("ts"),"receipts":receipts},separators=(",",":")))
else:raise ValueError("unknown_operation")
"""#
}
