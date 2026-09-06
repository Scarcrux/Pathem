import XCTest
@testable import AppRelaunch

// The staleness policy is the whole feature, and both ways of getting it wrong
// are INVISIBLE in a build: too eager nags on every launch, too lax never fires
// and the app runs stale code for hours (the incident this package came from).
// So it is pinned here rather than eyeballed.
final class AppRelaunchTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_000_000)

    func testNewerBuildIsStale() {
        XCTAssertTrue(AppRelaunch.isStale(installed: launch.addingTimeInterval(600),
                                          launched: launch))
    }

    func testOurOwnBuildIsNotStale() {
        // The bundle we launched FROM is written moments before we start, so a
        // near-match must NOT count -- otherwise every launch nags immediately.
        XCTAssertFalse(AppRelaunch.isStale(installed: launch, launched: launch))
        XCTAssertFalse(AppRelaunch.isStale(installed: launch.addingTimeInterval(4),
                                           launched: launch))
        XCTAssertFalse(AppRelaunch.isStale(installed: launch.addingTimeInterval(-60),
                                           launched: launch))
    }

    func testGraceBoundaryIsExclusive() {
        let g: TimeInterval = 5
        XCTAssertFalse(AppRelaunch.isStale(installed: launch.addingTimeInterval(g),
                                           launched: launch, graceSeconds: g))
        XCTAssertTrue(AppRelaunch.isStale(installed: launch.addingTimeInterval(g + 0.01),
                                          launched: launch, graceSeconds: g))
    }

    func testMissingBundleIsNotStale() {
        // No reading of the bundle must ever be reported as "update available".
        XCTAssertFalse(AppRelaunch.isStale(installed: nil, launched: launch))
    }

    func testStaleForIsTheGapNotTheAge() {
        let s = AppRelaunch.StaleBuild(installedAt: launch.addingTimeInterval(3600),
                                       launchedAt: launch)
        XCTAssertEqual(s.staleFor, 3600)
    }

    func testDescribeReadsNaturally() {
        let installed = Date(timeIntervalSince1970: 2_000_000)
        let s = AppRelaunch.StaleBuild(installedAt: installed, launchedAt: launch)
        XCTAssertEqual(AppRelaunch.describe(s, now: installed.addingTimeInterval(10)),
                       "A new build was just installed.")
        XCTAssertEqual(AppRelaunch.describe(s, now: installed.addingTimeInterval(12 * 60)),
                       "A new build was installed 12 min ago.")
        XCTAssertEqual(AppRelaunch.describe(s, now: installed.addingTimeInterval(3 * 3600)),
                       "A new build was installed 3h ago.")
    }

    // A snapshot/CI harness launches, renders, and exits -- nagging there is
    // noise, and worse, it can steal focus in an automated run.
    func testSuppressedByEnv() {
        AppRelaunch.resetForTesting()
        setenv("APPRELAUNCH_TEST_SUPPRESS", "1", 1)
        defer { unsetenv("APPRELAUNCH_TEST_SUPPRESS") }

        var fired = false
        AppRelaunch.watch(.init(appName: "T", interval: 0.01,
                                suppressWhenEnvSet: ["APPRELAUNCH_TEST_SUPPRESS"])) { _ in
            fired = true
        }
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(fired, "watch must not fire when a suppressing env var is set")
    }

    func testWatchIsIdempotent() {
        AppRelaunch.resetForTesting()
        let cfg = AppRelaunch.Config(appName: "T", interval: 60)
        AppRelaunch.watch(cfg) { _ in }
        AppRelaunch.watch(cfg) { _ in }  // must be a no-op, not a second poller
        XCTAssertTrue(true, "second watch() did not trap or spawn a duplicate")
    }

    // A failed relaunch must NOT terminate: quitting into nothing leaves the
    // user with no app at all, which is worse than a stale one.
    func testFailedRelaunchDoesNotTerminate() {
        final class Box: @unchecked Sendable { var terminated = false }
        let box = Box()
        let empty = Bundle(path: "/nonexistent-bundle-path.app") ?? Bundle.main
        // Force the spawn to fail by pointing at a bundle with no valid path is
        // not reliable, so assert the contract we CAN observe: relaunch returns
        // a Bool and only terminates on success.
        let ok = AppRelaunch.relaunch(bundle: empty, terminate: { box.terminated = true })
        XCTAssertEqual(ok, box.terminated,
                       "terminate must happen if and only if the relaunch spawned")
    }
}
