import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Pins what a Library row says a model will cost before anyone installs it.
/// Shared, because the wording is one vocabulary and both products render it
/// from the same state.
struct TranscriptionModelInstallSizeTests {
    @Test("every model this platform offers declares what it will cost on disk")
    func everyModelDeclaresASize() {
        for model in TranscriptionProviderRegistry.offeredModels {
            #expect(model.approximateSizeOnDisk > 0, "\(model.rawValue) declares no install size")
        }
    }

    @Test("a row for a model that is not installed says what installing it costs")
    func notInstalledStatesItsCost() {
        #expect(
            TranscriptionModelState.notInstalled.label(for: .whisperMedium)
                == "Not installed · ≈ \(Self.declaredSize(of: .whisperMedium))"
        )
        #expect(Self.declaredSize(of: .whisperMedium).localizedCaseInsensitiveContains("gb"))
    }

    @Test("a model this device cannot run, and one not yet judged, also say the cost")
    func absentStatesAllStateTheirCost() {
        for state in [TranscriptionModelState.unsupported, .installabilityUnknown] {
            #expect(state.label(for: .whisperLargeV3).hasSuffix("· ≈ \(Self.declaredSize(of: .whisperLargeV3))"))
        }
    }

    @Test("an installed row shows the size measured on disk, not the declared one")
    func installedStatesTheMeasuredSize() {
        let label = TranscriptionModelState.installed(bytes: 461_000_000).label(for: .parakeetV3)
        #expect(label == "Installed · 461 MB")
    }

    /// The declared cost as the app renders it, so the pinned wording survives
    /// a machine whose locale writes 1.5 GB with a comma.
    private static func declaredSize(of model: TranscriptionModel) -> String {
        model.approximateSizeOnDisk.formatted(.byteCount(style: .file))
    }

    @Test("a model select spends nothing, so the wording it renders carries no size")
    func selectWordingCarriesNoSize() {
        for model in TranscriptionProviderRegistry.offeredModels {
            let name = model.displayName
            #expect(!name.contains("≈"))
            #expect(!name.localizedCaseInsensitiveContains("GB"))
            #expect(!name.localizedCaseInsensitiveContains("MB"))
        }
    }
}
