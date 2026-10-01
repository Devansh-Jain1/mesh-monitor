import Foundation

@main
struct MeshFocusActivityFixture {
    static func main() {
        let now = Date(timeIntervalSince1970: 10_000)
        let browser = MeshFocusApplication(name: "Browser", bundleID: "test.browser", isMonitor: false)
        let editor = MeshFocusApplication(name: "Editor", bundleID: "test.editor", isMonitor: false)
        let monitor = MeshFocusApplication(name: "Mesh Monitor", bundleID: "test.monitor", isMonitor: true)
        var reducer = MeshFocusActivityReducer()
        reducer.observe(browser, at: now, uptime: 100)
        assert(!reducer.isMonitoring && reducer.application == nil, "Construction and stopped observations must be inert")
        reducer.start(application: browser, at: now, uptime: 100)
        reducer.tick(uptime: 110)
        assert(reducer.secondsInCurrentApp == 10)
        reducer.tick(uptime: 105)
        assert(reducer.secondsInCurrentApp == 10, "Clock regressions cannot reduce observed duration")
        reducer.tick(uptime: .nan)
        assert(reducer.secondsInCurrentApp == 10)
        reducer.observe(browser, at: now.addingTimeInterval(-500), uptime: 115)
        assert(reducer.secondsInCurrentApp == 15 && reducer.foregroundStartedAt == now)
        reducer.observe(editor, at: now.addingTimeInterval(-500), uptime: 120)
        assert(reducer.recentSwitches.count == 1 && reducer.recentSwitches[0].seconds == 20,
               "Durations must not use wall time")
        assert(reducer.application == editor && reducer.secondsInCurrentApp == 0)
        reducer.observe(MeshFocusApplication(name: "Renamed Editor", bundleID: editor.bundleID, isMonitor: false), at: now, uptime: 125)
        assert(reducer.recentSwitches.count == 1 && reducer.secondsInCurrentApp == 5)
        reducer.observe(monitor, at: now, uptime: 130)
        assert(reducer.snapshotDescription.contains("Monitor's own interface"))
        for index in 0..<35 {
            reducer.observe(index % 2 == 0 ? editor : browser, at: now.addingTimeInterval(Double(index)), uptime: 140 + Double(index))
        }
        assert(reducer.recentSwitches.count == 20, "History must remain bounded")
        reducer.stop()
        reducer.tick(uptime: 400)
        reducer.observe(editor, at: now, uptime: 500)
        assert(!reducer.isMonitoring && reducer.application == nil && reducer.recentSwitches.isEmpty)
        assert(reducer.secondsInCurrentApp == 0 && reducer.foregroundStartedAt == nil)
        reducer.start(application: nil, at: now, uptime: 600)
        assert(reducer.snapshotDescription.contains("unavailable"))
        reducer.observe(browser, at: now, uptime: 605)
        reducer.tick(uptime: 610)
        assert(reducer.secondsInCurrentApp == 5 && reducer.recentSwitches.isEmpty)
        print("PASS: synthetic focus activity timing, clock regression, bounded history, stop, and restart")
    }
}
