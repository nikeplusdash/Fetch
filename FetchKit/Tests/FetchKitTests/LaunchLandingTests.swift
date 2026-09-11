import Testing
@testable import FetchKit

@Suite("Launch landing")
struct LaunchLandingTests {
    @Test("with nothing downloading the app lands on the Library")
    func idleLandsOnLibrary() {
        #expect(LaunchLanding.filter(hasActiveDownloads: false) == .library)
    }

    @Test("with something downloading the app lands on the in-flight list")
    func busyLandsOnDownloads() {
        #expect(LaunchLanding.filter(hasActiveDownloads: true) == .downloads)
    }

    @Test("the app never opens on Cloud, which would fetch before being asked")
    func neverLandsOnCloud() {
        for busy in [true, false] {
            #expect(LaunchLanding.filter(hasActiveDownloads: busy) != .cloud)
        }
    }
}
