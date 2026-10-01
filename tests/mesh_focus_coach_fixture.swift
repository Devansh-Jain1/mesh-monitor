@main struct CoachChecks {
 static func main() {
  let now = Date(timeIntervalSince1970: 1000)
  var s = MeshCoachSchedule(); s.start(now)
  assert(s.due(now.addingTimeInterval(901), available: false) == nil)
  assert(s.due(now.addingTimeInterval(901), available: true) != nil)
  assert(s.due(now.addingTimeInterval(902), available: true) == nil)
  s.snooze(now.addingTimeInterval(902), minutes: 10)
  assert(s.due(now.addingTimeInterval(1000), available: true) == nil)
  assert(s.due(now.addingTimeInterval(3001), available: true)!.contains("water"))
  s.snooze(now.addingTimeInterval(5999), minutes: 10)
  assert(s.due(now.addingTimeInterval(6002), available: true) == nil)
  assert(s.due(now.addingTimeInterval(6600), available: false) == nil)
  assert(s.due(now.addingTimeInterval(6600), available: true) != nil)
  s.stop(); assert(s.due(now.addingTimeInterval(9999), available: true) == nil)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let path = root.appendingPathComponent("state.json")
  defer { try? FileManager.default.removeItem(at: root) }
  var pending = MeshCoachSchedule(); pending.start(now); pending.nextCheck = now
  let recovery = MeshFocusRecovery(task: "Fixture", finish: "Done", schedule: pending, spoken: true, resumeAt: now.addingTimeInterval(600))
  try! recovery.save(to: path)
  let restored = MeshFocusRecovery.load(from: path)!
  assert(restored.schedule.nextCheck == now)
  assert(restored.resumeAt == now.addingTimeInterval(600))
  assert(restored.spoken)
  var restoredSchedule = restored.schedule
  assert(restoredSchedule.due(now.addingTimeInterval(601), available: true) != nil)
  try! MeshFocusRecovery.clear(at: path)
  assert(MeshFocusRecovery.load(from: path) == nil)
  try! MeshFocusRecovery.clear(at: path)
  print("PASS: coaching deadlines, deferral, snooze, break, stop")
 }
}
