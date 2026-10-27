import XCTest
@testable import Vishot

final class CountdownTests: XCTestCase {
    func testBadgeCentersOnTinyTargetAndClampsOnlyAtSelectedDisplayEdges() {
        let display = CGRect(x: -1000, y: -800, width: 1000, height: 800)
        let tiny = CGRect(x: -510, y: -410, width: 20, height: 20)
        for style in VisualStyle.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let theme = ThemeCatalog.resolve(style: style, colorScheme: scheme)
                let frame = CountdownPlacement.frame(target: tiny, display: display, size: theme.countdown.size, scale: 2)
                XCTAssertEqual(frame.midX, -500)
                XCTAssertEqual(frame.midY, -400)
                XCTAssertGreaterThan(frame.width, tiny.width)
                let edge = CountdownPlacement.frame(target: CGRect(x: -1000, y: -800, width: 1, height: 1),
                    display: display, size: theme.countdown.size, scale: 1)
                XCTAssertTrue(display.contains(edge))
                XCTAssertGreaterThanOrEqual(edge.width, 80)
            }
        }
    }

    func testCancelAndRestartFenceAlreadyQueuedTicksAndPreserveFullNewInterval() {
        let clock = CountdownTestClock()
        let countdown = CaptureCountdown(schedule: clock.schedule)
        var old: [CaptureCountdown.Outcome] = [], next: [CaptureCountdown.Outcome] = []
        var numbers: [Int] = []
        countdown.start(present: { _ in }, completion: { old.append($0) })
        clock.advance(to: 1)
        countdown.cancel()
        countdown.cancel()
        countdown.start(present: { if let frame = $0 { numbers.append(frame.number) } }, completion: { next.append($0) })
        clock.advance(to: 2)
        XCTAssertEqual(old, [.cancelled])
        XCTAssertEqual(numbers, [3, 2])
        clock.advance(to: 3)
        XCTAssertEqual(numbers, [3, 2, 1])
        XCTAssertTrue(next.isEmpty)
        clock.advance(to: 4)
        XCTAssertEqual(next, [.completed])
    }

    func testReplacementCannotOverwriteNewerCountdownStartedByCancellationCallback() {
        let clock = CountdownTestClock()
        let countdown = CaptureCountdown(schedule: clock.schedule)
        var old: [CaptureCountdown.Outcome] = [], replacement: [CaptureCountdown.Outcome] = []
        var newest: [CaptureCountdown.Outcome] = []
        countdown.start(present: { _ in }) {
            old.append($0)
            countdown.start(present: { _ in }, completion: { newest.append($0) })
        }
        countdown.start(present: { _ in }, completion: { replacement.append($0) })
        clock.advance(to: 3)
        XCTAssertEqual(old, [.cancelled])
        XCTAssertEqual(replacement, [.cancelled])
        XCTAssertEqual(newest, [.completed])
    }

    func testStandaloneCountdownShowsThreeTwoOneAndCompletesAtThreeSecondsOnce() {
        let clock = CountdownTestClock()
        let countdown = CaptureCountdown(schedule: clock.schedule)
        var numbers: [Int] = []
        var outcomes: [CaptureCountdown.Outcome] = []
        countdown.start(present: { if let frame = $0 { numbers.append(frame.number) } }, completion: { outcomes.append($0) })
        XCTAssertEqual(numbers, [3])
        clock.advance(to: 0.999)
        XCTAssertTrue(outcomes.isEmpty)
        clock.advance(to: 1)
        XCTAssertEqual(numbers, [3, 2])
        clock.advance(to: 2)
        XCTAssertEqual(numbers, [3, 2, 1])
        clock.advance(to: 2.999)
        XCTAssertTrue(outcomes.isEmpty)
        clock.advance(to: 3)
        XCTAssertEqual(outcomes, [.completed])
        clock.advance(to: 10)
        countdown.cancel()
        XCTAssertEqual(outcomes, [.completed])
    }
}

/// Deliberately delivers canceled callbacks too, like already-enqueued OS work.
final class CountdownTestClock {
    private(set) var now: TimeInterval = 0
    private var jobs: [(TimeInterval, () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        jobs.append((now + delay, action))
        return {}
    }
    func advance(to time: TimeInterval) {
        now = time
        let due = jobs.filter { $0.0 <= time }.sorted { $0.0 < $1.0 }
        jobs.removeAll { $0.0 <= time }
        due.forEach { $0.1() }
    }
}
