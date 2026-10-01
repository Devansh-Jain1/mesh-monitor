import Foundation

@main
private struct MeshRuntimeMetricsFixtureTests {
    static func main() throws {
        let rows = try MeshRSSParser.parse(" 100 1 1000\n101 100 2000\n102 101 3000\n200 1 90000\n")
        assert(rows.count == 4)
        let selected = try MeshRSSParser.descendants(in: rows, rootPID: 100)
        assert(selected.map(\.pid) == [100, 101, 102])
        var samples = MeshRSSAccumulator()
        try samples.ingest(rows, rootPID: 100)
        assert(samples.processCount == 3 && samples.currentMB == 6.144 && samples.peakMB == 6.144)
        try samples.ingest([rows[0]], rootPID: 100)
        assert(samples.processCount == 1 && samples.currentMB == 1.024 && samples.peakMB == 6.144,
               "A worker exit lowers current memory without erasing observed peak")
        do { try samples.ingest([], rootPID: 100); assertionFailure("Missing app must fail") }
        catch { assert(samples.currentMB == nil && samples.processCount == 0 && samples.peakMB == 6.144) }

        let cyclic = try MeshRSSParser.parse("10 11 100\n11 10 200\n12 11 300\n88 89 500\n89 88 500\n")
        let cycleSelection = try MeshRSSParser.descendants(in: cyclic, rootPID: 10)
        assert(Set(cycleSelection.map(\.pid)) == [10, 11, 12] && cycleSelection.count == 3)
        for invalid in ["pid ppid rss", "1 0 -5", "0 0 10", "1 -1 10", "1 0 1 extra", "1 0 1\n1 0 1", "1 0 nan"] {
            do { _ = try MeshRSSParser.parse(invalid); assertionFailure("Malformed process data must fail") }
            catch { }
        }
        try samples.ingest(try MeshRSSParser.parse("100 1 10000\n"), rootPID: 100)
        assert(samples.currentMB == 10.24 && samples.peakMB == 10.24)
        samples.unavailable()
        assert(samples.currentMB == nil && samples.processCount == 0 && samples.peakMB == 10.24)
        let overflow = [MeshRSSProcess(pid: 100, parentPID: 1, rssKiB: UInt64.max), MeshRSSProcess(pid: 101, parentPID: 100, rssKiB: 1)]
        do { try samples.ingest(overflow, rootPID: 100); assertionFailure("Overflow must fail") }
        catch { assert(samples.currentMB == nil && samples.peakMB == 10.24) }
        print("PASS: RSS parsing, descendant-only selection, cycle bounds, process-exit peak preservation, missing process and invalid/overflow data. Pure fixtures; no ps or other process launched.")
    }
}
