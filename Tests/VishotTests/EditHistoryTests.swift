import XCTest
@testable import Vishot

final class EditHistoryTests: XCTestCase {
    private let arrow = Annotation.arrow(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 30, y: 40), color: .red)
    private let rect = Annotation.rect(CGRect(x: 5, y: 5, width: 10, height: 10), color: .purple)
    private let crop = CGRect(x: 0, y: 0, width: 50, height: 50)

    func testUndoRestoresTheSnapshotPushedBeforeAChange() {
        var history = EditHistory()
        var state = EditSnapshot(annotations: [], crop: nil)
        history.push(state)
        state = EditSnapshot(annotations: [arrow], crop: crop)

        XCTAssertTrue(history.undo(&state))
        XCTAssertEqual(state, EditSnapshot(annotations: [], crop: nil))
    }

    func testRedoReappliesWhatUndoReverted() {
        var history = EditHistory()
        var state = EditSnapshot(annotations: [], crop: nil)
        history.push(state)
        state.annotations = [arrow]
        history.push(state)
        state.annotations = [arrow, rect]

        XCTAssertTrue(history.undo(&state))
        XCTAssertTrue(history.undo(&state))
        XCTAssertEqual(state.annotations, [])
        XCTAssertTrue(history.redo(&state))
        XCTAssertEqual(state.annotations, [arrow])
        XCTAssertTrue(history.redo(&state))
        XCTAssertEqual(state.annotations, [arrow, rect])
    }

    func testPushClearsRedo() {
        var history = EditHistory()
        var state = EditSnapshot(annotations: [], crop: nil)
        history.push(state)
        state.annotations = [arrow]
        XCTAssertTrue(history.undo(&state))

        history.push(state)
        state.crop = crop

        XCTAssertFalse(history.redo(&state))
        XCTAssertEqual(state, EditSnapshot(annotations: [], crop: crop))
    }

    func testUndoAndRedoWithNothingToApplyReturnFalseAndKeepTheState() {
        var history = EditHistory()
        var state = EditSnapshot(annotations: [rect], crop: crop)

        XCTAssertFalse(history.undo(&state))
        XCTAssertFalse(history.redo(&state))
        XCTAssertEqual(state, EditSnapshot(annotations: [rect], crop: crop))
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }
}
