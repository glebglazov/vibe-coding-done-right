import CoreGraphics
import Foundation
import Testing
@testable import vcdr_mac

/// P, the key both built-in paste destinations bind by default.
private let pKeyCode: UInt16 = 35

/// A combination on P carrying exactly `modifiers`.
private func onP(_ modifiers: CGEventFlags...) -> HotkeyBinding {
    HotkeyBinding(
        keyCode: pKeyCode,
        modifiers: modifiers.reduce(into: UInt64(0)) { bits, flag in bits |= flag.rawValue }
    )
}

/// A session whose only Activation Hotkeys are two bash-script destinations on P:
/// `specific` on Shift+Option+P and `general` on Option+P. Bash is the one
/// destination type a test host can execute, and clearing the built-in bindings
/// leaves the specificity tie-break exactly two candidates.
@MainActor
private struct TwoDestinationsOnP {
    let env: CaptureSessionTestEnvironment
    let specific: UUID
    let general: UUID

    init() {
        env = CaptureSessionTestEnvironment(
            mockProvider: MockTranscriptionProvider(result: "Hello destination")
        )
        for index in env.settings.outputDestinations.indices {
            env.settings.outputDestinations[index].activationHotkey = .unassigned
        }
        specific = env.settings.addDestination()
        general = env.settings.addDestination()
        bind(specific, to: onP(.maskShift, .maskAlternate))
        bind(general, to: onP(.maskAlternate))
    }

    func bind(_ destinationID: UUID, to hotkey: HotkeyBinding) {
        guard let index = env.settings.outputDestinations.firstIndex(where: { $0.id == destinationID }) else {
            Issue.record("Destination \(destinationID) missing from settings")
            return
        }
        env.settings.outputDestinations[index].activationHotkey = hotkey
    }

    /// Every combination claimed on P.
    var claimedOnP: [HotkeyBinding] {
        env.hotkeyRegistry.claimedBindings.filter { $0.keyCode == pKeyCode }
    }

    /// Records until `combination` is claimed, then presses it.
    func startRecordingAndClaim(_ combination: HotkeyBinding) async {
        env.session.toggle()
        #expect(await env.waitForPhase { $0 == .recording })
        #expect(
            await waitFor { env.hotkeyRegistry.claimedBindings.contains(combination) },
            "\(combination.displayString) must be claimed while recording"
        )
    }

    /// Records, presses `combination`, and reports where the capture landed.
    func captureRouted(by combination: HotkeyBinding) async -> UUID? {
        await startRecordingAndClaim(combination)
        #expect(env.hotkeyRegistry.press(combination))
        #expect(await env.waitForPhase { $0 == .idle })
        return await env.session.waitForNextIdle(timeout: .seconds(5))?.destinationID
    }
}

/// An Output Destination's Activation Hotkey answers to any combination that
/// includes its modifiers, and loses its key to a binding requiring more of them.
/// Carbon matches exactly, so that rule now lives in what gets claimed rather than
/// in what a callback compares — these press combinations through the registry and
/// read the answer off where the capture landed.
@Suite("CaptureSession — Destination hotkeys")
struct CaptureSessionDestinationHotkeyTests {

    @Test("Pressing a destination's Activation Hotkey while recording routes the capture there")
    @MainActor
    func pressRoutesTheCapture() async {
        let setup = TwoDestinationsOnP()
        defer { setup.env.cleanup() }

        #expect(await setup.captureRouted(by: onP(.maskAlternate)) == setup.general)
    }

    @Test("An Activation Hotkey still fires when push-to-talk modifiers are held")
    @MainActor
    func extraModifiersStillFire() async {
        let setup = TwoDestinationsOnP()
        defer { setup.env.cleanup() }

        let heldDown = onP(.maskControl, .maskAlternate, .maskCommand)
        #expect(await setup.captureRouted(by: heldDown) == setup.general)
    }

    @Test("Shift+Option+P and Option+P route to different destinations, the more specific winning the key")
    @MainActor
    func moreSpecificBindingWinsTheSharedKey() async {
        let setup = TwoDestinationsOnP()
        defer { setup.env.cleanup() }

        #expect(await setup.captureRouted(by: onP(.maskShift, .maskAlternate)) == setup.specific)
        #expect(await setup.captureRouted(by: onP(.maskAlternate)) == setup.general)
    }

    @Test("Two bindings on one key expand to eight combinations, none of them claimed twice")
    @MainActor
    func expansionClaimsEachCombinationOnce() async {
        let setup = TwoDestinationsOnP()
        defer { setup.env.cleanup() }

        await setup.startRecordingAndClaim(onP(.maskAlternate))
        #expect(
            await waitFor { setup.claimedOnP.count == 8 },
            "Every combination including Option, and no other"
        )

        let claimed = setup.claimedOnP
        let distinct = claimed.reduce(into: [HotkeyBinding]()) { unique, combination in
            if !unique.contains(combination) { unique.append(combination) }
        }
        #expect(
            distinct.count == claimed.count,
            "Carbon refuses a duplicate registration, so a repeated combination means the expansion is wrong"
        )

        setup.env.session.cancel()
        #expect(await setup.env.waitForPhase { $0 == .idle })
    }

    @Test("Outside a recording nothing is claimed, so the combination reaches the frontmost app")
    @MainActor
    func claimedOnlyWhileRecording() async {
        let setup = TwoDestinationsOnP()
        defer { setup.env.cleanup() }
        let combination = onP(.maskAlternate)

        #expect(!setup.env.hotkeyRegistry.press(combination), "Nothing to route before a recording")

        await setup.startRecordingAndClaim(combination)

        setup.env.session.toggle()
        #expect(await setup.env.waitForPhase { $0 == .idle })

        #expect(!setup.env.hotkeyRegistry.press(combination), "The finished capture must hand the key back")
    }

    @Test("A modifier-less Activation Hotkey is accepted and claims every combination of its key")
    @MainActor
    func modifierLessBindingClaimsEveryCombination() async {
        let setup = TwoDestinationsOnP()
        defer { setup.env.cleanup() }

        setup.bind(setup.specific, to: .unassigned)
        setup.bind(setup.general, to: onP())

        await setup.startRecordingAndClaim(onP())
        #expect(await waitFor { setup.claimedOnP.count == 16 }, "A bare key matches every modifier state")
        #expect(
            setup.claimedOnP.contains(onP(.maskCommand)),
            "Command-P is swallowed for the duration of the recording, exactly as the event tap swallowed it"
        )

        #expect(setup.env.hotkeyRegistry.press(onP()))
        #expect(await setup.env.waitForPhase { $0 == .idle })
        #expect(await setup.env.session.waitForNextIdle(timeout: .seconds(5))?.destinationID == setup.general)
    }
}
