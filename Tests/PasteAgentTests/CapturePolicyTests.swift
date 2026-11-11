import Foundation
import XCTest
@testable import PasteAgent

final class CapturePolicyTests: XCTestCase {
    func testPausedAlwaysWins() {
        XCTAssertFalse(CapturePolicy.shouldCapture(paused: true, excludedApps: [], executableName: "notes"))
        XCTAssertTrue(CapturePolicy.shouldCapture(paused: false, excludedApps: [], executableName: "notes"))
    }

    func testExclusionIsCaseInsensitiveOnExecutableName() {
        let excluded = ["1password", "Bitwarden.exe"]
        XCTAssertFalse(CapturePolicy.shouldCapture(paused: false, excludedApps: excluded, executableName: "1Password"))
        XCTAssertFalse(CapturePolicy.shouldCapture(paused: false, excludedApps: excluded, executableName: "bitwarden.exe"))
        XCTAssertTrue(CapturePolicy.shouldCapture(paused: false, excludedApps: excluded, executableName: "Safari"))
        // Unknown source cannot match any exclusion.
        XCTAssertTrue(CapturePolicy.shouldCapture(paused: false, excludedApps: excluded, executableName: ""))
    }

    func testRetentionCutoffUsesMilliseconds() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(CapturePolicy.retentionCutoff(nowMs: now, days: 1), now - 86_400_000)
        XCTAssertNil(CapturePolicy.retentionCutoff(nowMs: now, days: 0))
        XCTAssertNil(CapturePolicy.retentionCutoff(nowMs: now, days: -5))
    }

    func testRetentionCutoffNeverTrapsOnHugeWindows() {
        let now: Int64 = 1_700_000_000_000
        // Int64.max days would overflow the millisecond conversion; treat it
        // as keep-forever instead of trapping.
        XCTAssertNil(CapturePolicy.retentionCutoff(nowMs: now, days: Int64.max))
        XCTAssertEqual(
            CapturePolicy.retentionCutoff(nowMs: now, days: 100_000),
            now - 100_000 * 86_400_000
        )
    }
}
