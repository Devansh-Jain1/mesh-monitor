import AppKit
import CoreGraphics

/// Pure metadata only: do not construct MeshScreenContext or access NSWorkspace.
@main struct ScreenContextFixture {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let ownPID: pid_t = 123
        let appPID: pid_t = 456
        func eligible(_ policy: NSApplication.ActivationPolicy?, pid: pid_t? = appPID) -> Bool {
            MeshScreenCapturePolicy.eligibleApplication(processID: pid, activationPolicy: policy, ownPID: ownPID)
        }
        expect(eligible(.regular), "Regular foreground app remains eligible")
        expect(eligible(.accessory), "Foreground accessory/helper app with a normal window must not be excluded")
        expect(!eligible(.prohibited), "Prohibited process must remain excluded")
        expect(!eligible(nil), "Missing application policy must remain excluded")
        for policy in [NSApplication.ActivationPolicy.regular, .accessory, .prohibited] {
            expect(!eligible(policy, pid: ownPID), "Monitor must not capture itself under any policy")
            expect(!eligible(policy, pid: nil), "Missing application PID must remain excluded")
            expect(!eligible(policy, pid: 0), "Invalid application PID must remain excluded")
            expect(!eligible(policy, pid: -1), "Negative application PID must remain excluded")
        }

        let normal = CGRect(x: 0, y: 0, width: 600, height: 400)
        func window(owner: pid_t? = appPID, selected: pid_t? = appPID,
                    layer: Int = 0, frame: CGRect = normal) -> Bool {
            MeshScreenCapturePolicy.eligibleWindow(ownerPID: owner, selectedPID: selected, layer: layer, frame: frame)
        }
        expect(window(), "Normal window of the exact foreground PID is eligible")
        expect(!window(owner: ownPID), "Other applications must not substitute for the selected app")
        expect(!window(owner: nil), "Window without an owner must remain excluded")
        expect(!window(selected: nil), "Missing foreground selection must not select a window")
        expect(!window(owner: nil, selected: nil), "Two missing identities must never match")
        expect(!window(owner: 0, selected: 0), "Invalid identities must never match")
        for layer in [-1, 1, 25] {
            expect(!window(layer: layer), "Only ordinary layer-zero windows are eligible")
        }
        expect(!window(frame: CGRect(x: 0, y: 0, width: 150, height: 400)), "Width threshold remains strict")
        expect(!window(frame: CGRect(x: 0, y: 0, width: 600, height: 100)), "Height threshold remains strict")
        expect(window(frame: CGRect(x: -1200, y: -200, width: 151, height: 101)), "An ordinary window on a secondary display remains eligible")

        // Eligible input order deliberately differs from the desktop's front-to-back order.
        let eligibleIDs: Set<CGWindowID> = [10, 20]
        expect(MeshScreenCapturePolicy.frontmostWindowID(orderedIDs: [99, 20, 10], eligibleIDs: eligibleIDs) == 20,
               "Choose the frontmost eligible window, never the largest or shareable-content first entry")
        expect(MeshScreenCapturePolicy.frontmostWindowID(orderedIDs: [10, 20], eligibleIDs: eligibleIDs) == 10,
               "Follow current front-to-back desktop ordering")
        expect(MeshScreenCapturePolicy.frontmostWindowID(orderedIDs: [99], eligibleIDs: eligibleIDs) == nil,
               "Do not fall back to a window absent from on-screen ordering")
        expect(MeshScreenCapturePolicy.frontmostWindowID(orderedIDs: [], eligibleIDs: eligibleIDs) == nil,
               "No on-screen windows means no selection")
        expect(MeshScreenCapturePolicy.frontmostWindowID(orderedIDs: [10], eligibleIDs: []) == nil,
               "Ineligible windows cannot be selected")

        expect(MeshScreenCapturePolicy.foregroundStillMatches(selectedPID: appPID, foregroundPID: appPID),
               "A stable foreground PID can publish")
        for switchedPID: pid_t? in [ownPID, 789, nil, 0] {
            expect(!MeshScreenCapturePolicy.foregroundStillMatches(selectedPID: appPID, foregroundPID: switchedPID),
                   "A foreground switch during asynchronous capture must cancel publication")
        }
        expect(!MeshScreenCapturePolicy.foregroundStillMatches(selectedPID: nil, foregroundPID: nil),
               "Two missing foreground identities must not authorize publication")
        expect(!MeshScreenCapturePolicy.foregroundStillMatches(selectedPID: 0, foregroundPID: 0),
               "Invalid foreground identities must not authorize publication")
        print("PASS \(checks) offline screen selection checks; no capture, inputs, app launch, or workspace observation")
    }
}
