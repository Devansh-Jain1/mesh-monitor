import Combine
import Darwin
import Foundation

struct MeshRSSProcess: Equatable {
    let pid: Int32
    let parentPID: Int32
    let rssKiB: UInt64
}

enum MeshRSSFailure: LocalizedError {
    case malformed, rootMissing, overflow, failed, timedOut, oversized
    var errorDescription: String? {
        switch self {
        case .malformed: "Process memory data could not be parsed."
        case .rootMissing: "The app process was not present in the memory sample."
        case .overflow: "Process memory total exceeded the supported range."
        case .failed: "The process memory query failed."
        case .timedOut: "The process memory query timed out."
        case .oversized: "Process memory output exceeded its size limit."
        }
    }
}

/// Pure parsing and tree selection. No command lines, names, or model identities.
enum MeshRSSParser {
    static func parse(_ output: String) throws -> [MeshRSSProcess] {
        var seen = Set<Int32>()
        return try output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard !fields.isEmpty else { return nil }
            guard fields.count == 3,
                  let pid = Int32(fields[0]), pid > 0,
                  let parentPID = Int32(fields[1]), parentPID >= 0,
                  let rss = UInt64(fields[2]), seen.insert(pid).inserted else {
                throw MeshRSSFailure.malformed
            }
            return MeshRSSProcess(pid: pid, parentPID: parentPID, rssKiB: rss)
        }
    }

    static func descendants(in rows: [MeshRSSProcess], rootPID: Int32) throws -> [MeshRSSProcess] {
        guard let root = rows.first(where: { $0.pid == rootPID }) else { throw MeshRSSFailure.rootMissing }
        let children = Dictionary(grouping: rows, by: \.parentPID)
        var visited = Set<Int32>()
        var queue = [root]
        var result: [MeshRSSProcess] = []
        var index = 0
        while index < queue.count {
            let row = queue[index]
            index += 1
            guard visited.insert(row.pid).inserted else { continue }
            result.append(row)
            queue.append(contentsOf: children[row.pid] ?? [])
        }
        return result
    }
}

/// Peak is the greatest sampled sum, not a continuously measured physical peak.
struct MeshRSSAccumulator {
    private(set) var currentMB: Double?
    private(set) var peakMB: Double?
    private(set) var processCount = 0

    mutating func ingest(_ rows: [MeshRSSProcess], rootPID: Int32) throws {
        do {
            let selected = try MeshRSSParser.descendants(in: rows, rootPID: rootPID)
            var total: UInt64 = 0
            for row in selected {
                let sum = total.addingReportingOverflow(row.rssKiB)
                guard !sum.overflow else { throw MeshRSSFailure.overflow }
                total = sum.partialValue
            }
            let value = Double(total) * 1024 / 1_000_000
            currentMB = value
            peakMB = max(peakMB ?? 0, value)
            processCount = selected.count
        } catch {
            unavailable()
            throw error
        }
    }

    mutating func unavailable() {
        currentMB = nil
        processCount = 0
        // Preserve the observed peak when a child exits or reading fails.
    }
}

/// Small thread-safe collection used only by our own bounded ps subprocess.
private final class MeshRSSOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var tooLarge = false
    private var readFailed = false

    func append(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !tooLarge else { return }
        guard bytes.count + value.count <= 2_000_000 else { tooLarge = true; return }
        bytes.append(value)
    }

    func result() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !tooLarge else { throw MeshRSSFailure.oversized }
        guard !readFailed else { throw MeshRSSFailure.failed }
        guard let text = String(data: bytes, encoding: .utf8) else { throw MeshRSSFailure.malformed }
        return text
    }

    func failed() {
        lock.lock()
        readFailed = true
        lock.unlock()
    }
}

@MainActor
final class MeshRuntimeMetrics: ObservableObject {
    @Published private(set) var currentMB: Double?
    @Published private(set) var peakMB: Double?
    @Published private(set) var processCount = 0
    @Published private(set) var status = "Memory sampling stopped."

    static let measurementNote = "Approximate sum RSS in MB for this app and its descendants. Shared pages can be counted more than once. Excludes GPU memory; peak is the highest sample, not a true physical-memory peak."

    private let rootPID: Int32
    private var accumulator = MeshRSSAccumulator()
    private var timer: Timer?
    private var sampleTask: Task<[MeshRSSProcess], Error>?
    private var monitoring = false
    private var generation = UUID()
    private var lastStartedUptime: TimeInterval?

    init(rootPID: Int32 = ProcessInfo.processInfo.processIdentifier) { self.rootPID = rootPID }

    /// Explicit opt-in. One sample at most per five seconds; never overlaps queries.
    func startMonitoring() {
        guard timer == nil else { return }
        monitoring = true
        generation = UUID()
        status = "Sampling app and descendant RSS every 5 seconds."
        sample()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = 0.5
        self.timer = timer
    }

    func stop() {
        monitoring = false
        timer?.invalidate()
        timer = nil
        generation = UUID()
        sampleTask?.cancel()
        sampleTask = nil
        accumulator.unavailable()
        publish()
        status = "Memory sampling stopped; observed peak retained."
    }

    private func sample() {
        guard monitoring, sampleTask == nil else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if let lastStartedUptime, uptime - lastStartedUptime < 5 { return }
        lastStartedUptime = uptime
        let token = generation
        let task = Task.detached(priority: .utility) { try Self.readSample() }
        sampleTask = task
        Task { [weak self] in
            do {
                let rows = try await task.value
                guard let self, generation == token else { return }
                try accumulator.ingest(rows, rootPID: rootPID)
                publish()
                status = "\(processCount) processes sampled · approximate sum RSS; shared pages may repeat, GPU excluded."
            } catch {
                guard let self, generation == token else { return }
                accumulator.unavailable()
                publish()
                status = error.localizedDescription
            }
            if self?.generation == token { self?.sampleTask = nil }
        }
    }

    private func publish() {
        currentMB = accumulator.currentMB
        peakMB = accumulator.peakMB
        processCount = accumulator.processCount
    }

    /// Runs off the main actor. Waits are bounded and only our spawned ps can be killed.
    /// stderr is discarded; no process inventory or arguments are emitted to logs.
    nonisolated private static func readSample() throws -> [MeshRSSProcess] {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        let output = MeshRSSOutput()
        let ended = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        defer {
            // Also clean up our child if setup/drain throws before the normal wait.
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try process.run()
        // The parent must release its writer so the reader sees EOF when ps exits.
        try pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                    output.append(chunk)
                }
            } catch { output.failed() }
        }
        if ended.wait(timeout: .now() + 2) == .timedOut {
            if process.isRunning { process.terminate() }
            if ended.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 0.2)
            }
            throw MeshRSSFailure.timedOut
        }
        guard drained.wait(timeout: .now() + 0.2) == .success else { throw MeshRSSFailure.timedOut }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw MeshRSSFailure.failed }
        return try MeshRSSParser.parse(output.result())
    }
}
