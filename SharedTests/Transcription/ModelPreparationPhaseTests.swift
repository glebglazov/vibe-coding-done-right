import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Pins the wording both products render for a Model Preparation Phase, and
/// the moment a label starts carrying a Preparation Heartbeat.
struct ModelPreparationPhaseTests {
    @Test("each phase renders its own label")
    func phaseLabels() {
        #expect(ModelPreparationPhase.preparing.label(elapsedSeconds: 0) == "Preparing")
        #expect(ModelPreparationPhase.downloadingModel.label(elapsedSeconds: 0) == "Downloading model")
        #expect(ModelPreparationPhase.loadingModel.label(elapsedSeconds: 0) == "Loading model")
        #expect(ModelPreparationPhase.ready.label(elapsedSeconds: 99) == "Ready")
    }

    @Test("a launch with cached artifacts cannot read as a download")
    func preparingIsNotDownloading() {
        #expect(
            ModelPreparationPhase.preparing.label(elapsedSeconds: 0)
                != ModelPreparationPhase.downloadingModel.label(elapsedSeconds: 0)
        )
    }

    @Test("the heartbeat appears only once a phase outlasts the reveal threshold")
    func heartbeatFollowsRevealThreshold() {
        let threshold = ModelPreparationPhase.heartbeatRevealThreshold
        #expect(ModelPreparationPhase.loadingModel.label(elapsedSeconds: threshold - 1) == "Loading model")
        #expect(
            ModelPreparationPhase.loadingModel.label(elapsedSeconds: threshold)
                == "Loading model · \(threshold)s"
        )
        #expect(ModelPreparationPhase.loadingModel.label(elapsedSeconds: 5) == "Loading model · 5s")
    }
}
