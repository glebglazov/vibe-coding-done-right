import Testing
@testable import vcdr_ios

struct HostBundleIDTests {
    @Test("an empty bundle ID is not a host")
    func emptyBundleIsNotAHost() {
        #expect(HostBundleID("   ") == nil)
    }

    @Test("VCDR and its keyboard are never a host to return to")
    func ownAppIsExcluded() {
        let app = "glebglazov.vcdr-ios"
        #expect(HostBundleID("glebglazov.vcdr-ios")?.belongs(toApp: app) == true)
        #expect(HostBundleID("glebglazov.vcdr-ios.keyboard")?.belongs(toApp: app) == true)
        #expect(HostBundleID("dev.muxify.app")?.belongs(toApp: app) == false)
    }
}
