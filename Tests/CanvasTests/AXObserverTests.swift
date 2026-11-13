import ApplicationServices
import XCTest
@testable import Canvas

/// What an app's answer to an Accessibility registration means. The registrations themselves are round
/// trips to the app, made off the main thread; the answer is read back on it.
final class AXObserverTests: XCTestCase {
    func testRegisteredOnceOrAlready() {
        XCTAssertEqual(AXAppObserver.outcome(of: .success, attempt: 0, forWindow: false), .registered)
        XCTAssertEqual(AXAppObserver.outcome(of: .notificationAlreadyRegistered, attempt: 0, forWindow: true), .registered,
                       "the same window entered again")
    }

    func testALaunchingAppIsAskedAgainForAFewSeconds() {
        XCTAssertEqual(AXAppObserver.outcome(of: .cannotComplete, attempt: 0, forWindow: false), .retry)
        XCTAssertEqual(AXAppObserver.outcome(of: .cannotComplete, attempt: AXAppObserver.retries - 1, forWindow: true), .retry)
        XCTAssertEqual(AXAppObserver.outcome(of: .cannotComplete, attempt: AXAppObserver.retries, forWindow: false), .failed)
    }

    func testAnEnteredWindowItsAppNoLongerHasIsToldAsGone() {
        XCTAssertEqual(AXAppObserver.outcome(of: .invalidUIElement, attempt: 0, forWindow: true), .windowGone)
        XCTAssertEqual(AXAppObserver.outcome(of: .invalidUIElement, attempt: 3, forWindow: true), .windowGone)
        XCTAssertEqual(AXAppObserver.outcome(of: .invalidUIElement, attempt: 0, forWindow: false), .failed,
                       "the app itself: nothing to come back from")
    }

    func testAnythingElseIsAFailure() {
        XCTAssertEqual(AXAppObserver.outcome(of: .apiDisabled, attempt: 0, forWindow: false), .failed)
        XCTAssertEqual(AXAppObserver.outcome(of: .notificationUnsupported, attempt: 0, forWindow: true), .failed)
    }

    /// An observer on this very process: made and let go on the main thread without waiting on any
    /// registration, and the queue behind it finishes on its own.
    @MainActor
    func testAnObserverIsMadeAndLetGoWithoutWaitingOnItsApp() {
        var observer = AXAppObserver(pid: getpid()) { _, _ in }
        observer?.watch(window: nil)
        observer = nil
        let settled = expectation(description: "the main queue runs on")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }
}
