import Foundation
import Testing
@testable import vcdr_mac

/// Pins what a Preparation Failure is allowed to claim: the one cause the app
/// can genuinely tell apart, and nothing borrowed from the backend's own words.
@Suite("Preparation failure")
struct PreparationFailureTests {

    @Test("a lost connection is named as the cause")
    func offlineIsNamed() {
        let offline = URLError(.notConnectedToInternet)

        #expect(PreparationFailure(error: offline) == .offline)
        #expect(PreparationFailure.offline.headline.contains("internet connection"))
    }

    @Test("a cause the app cannot verify is not invented")
    func opaqueFailureStaysUnknown() {
        let compileFailure = NSError(
            domain: "com.apple.CoreML",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Error compiling model: unsupported layer"]
        )

        let failure = PreparationFailure(error: compileFailure)

        #expect(failure == .unknown)
        #expect(!failure.message.contains("unsupported layer"))
    }

    @Test("every failure says waiting will not fix it")
    func everyFailureRulesOutWaiting() {
        for failure in [PreparationFailure.offline, .unknown] {
            #expect(failure.remedy.contains("Waiting will not fix this"))
            #expect(failure.remedy.lowercased().contains("try again"))
        }
    }

    @Test("readiness carries the failure the provider classified, never its text")
    @MainActor
    func readinessCarriesTheClassifiedFailure() {
        let thrown = TranscriptionError.initializationFailed(.offline)

        #expect(ModelReadiness.failed(from: thrown) == .failed(.offline))
        #expect(thrown.localizedDescription == PreparationFailure.offline.message)
        #expect(ModelReadiness.failed(from: URLError(.badServerResponse)) == .failed(.unknown))
    }

    @Test("a retried preparation stops reporting the failure and reaches ready")
    @MainActor
    func retryRecoversToReady() {
        var narrator = ModelPreparationNarrator()

        #expect(narrator.readiness(for: .failed(.offline)) == .failed(.offline))
        #expect(narrator.readiness(for: .downloadingModel) != .failed(.offline))
        #expect(narrator.readiness(for: .ready) == .ready)
    }
}
