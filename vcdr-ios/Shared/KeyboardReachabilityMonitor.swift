import Combine
import Foundation

/// Watches whether a tap on the keyboard's record control will record in place
/// or bounce the user into the app.
///
/// It answers that with the *same* read the tap makes — `isAppLikelyAlive()` on
/// the Keyboard Channel — and nothing else. A sharper probe would be worse than
/// this one: it could report "in place" while `startRecording` reads the
/// heartbeat as stale and opens the Deep-Link Fallback anyway, which is the
/// indicator lying by being more right than the code it describes.
///
/// The heartbeat is a single `Double` in shared defaults with no change
/// notification, so freshness is sampled on a short poll that runs only while
/// the keyboard is on screen. The keyboard is a memory-constrained extension:
/// the app must not be made to wake it per heartbeat.
@MainActor
final class KeyboardReachabilityMonitor: ObservableObject {

    // MARK: - Constants

    /// Gap between samples. Short enough that an app the user has just
    /// foregrounded lights the control while they are still looking at it,
    /// long enough to stay a rounding error against a defaults read.
    static let defaultPollInterval: Duration = .seconds(2)

    /// True when the next tap records without leaving the keyboard.
    ///
    /// Starts unlit: until the first sample lands we have not read a heartbeat,
    /// and claiming reachability we haven't checked is the one failure mode
    /// this indicator exists to prevent.
    @Published private(set) var recordsInPlace: Bool = false

    private let channel: any KeyboardChannelProtocol
    private let pollInterval: Duration
    private var poll: Task<Void, Never>?

    /// Whether a poll is currently running. Lets the keyboard's lifecycle
    /// contract — polling only while visible — be asserted from outside.
    var isPolling: Bool { poll != nil }

    init(
        channel: any KeyboardChannelProtocol,
        pollInterval: Duration = KeyboardReachabilityMonitor.defaultPollInterval
    ) {
        self.channel = channel
        self.pollInterval = pollInterval
    }

    deinit {
        poll?.cancel()
    }

    /// Samples once now — so the control is right on the frame the keyboard
    /// appears — then keeps sampling until `stop()`.
    func start() {
        sample()
        guard poll == nil else { return }
        poll = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.sample()
            }
        }
    }

    /// Ends polling. Safe to call when no poll is running.
    func stop() {
        poll?.cancel()
        poll = nil
    }

    private func sample() {
        let inPlace = channel.isAppLikelyAlive()
        if recordsInPlace != inPlace {
            recordsInPlace = inPlace
        }
    }
}
