import XCTest
@testable import Vishot

@MainActor
final class FrozenSourcePreparationTests: XCTestCase {
    func testCopyAndEditWaitForRaiseAndPickerExclusionBeforeReceivingFrozenSource() async throws {
        for destination in ["copy", "edit"] {
            let raise = Gate()
            let source = try makeCapture()
            var pickerExcluded = false
            var received: Capture?
            var editor: EditorController?
            let preparation = FrozenSourcePreparation(
                waitForRaise: { await raise.wait() },
                excludePicker: { pickerExcluded = true },
                capture: { _ in
                    XCTAssertTrue(pickerExcluded, destination)
                    return source
                },
                onFailure: { XCTFail("Unexpected capture failure") }
            )
            let request = Task {
                await preparation.prepare(for: target) {
                    received = $0
                    if destination == "edit" { editor = EditorController(capture: $0) }
                }
            }
            await raise.entered()
            XCTAssertFalse(pickerExcluded)
            XCTAssertNil(received)
            raise.resume()
            await request.value
            let result = try XCTUnwrap(received)
            XCTAssertTrue(result.image === source.image)
            XCTAssertEqual(result.scale, 2)
            XCTAssertEqual(result.frame, source.frame)
            XCTAssertEqual(result.initialCrop, source.initialCrop)
            let document = editor?.document ?? EditDocument(image: result.image, scale: result.scale, crop: result.initialCrop)
            let output = try XCTUnwrap(AnnotationRenderer.export(document))
            XCTAssertEqual(output.width, 40)
            XCTAssertEqual(output.height, 20)
        }
    }

    func testCancellationDuringRaiseDoesNotHidePickerOrCapture() async {
        let raise = Gate()
        var effects: [String] = []
        let preparation = FrozenSourcePreparation(
            waitForRaise: { await raise.wait() },
            excludePicker: { effects.append("hide") },
            capture: { _ in effects.append("capture"); return nil },
            onFailure: { effects.append("failure") }
        )
        let request = Task { await preparation.prepare(for: target) { _ in effects.append("output") } }
        await raise.entered()
        request.cancel()
        raise.resume()
        await request.value
        XCTAssertEqual(effects, [])
    }

    func testLateCaptureCannotOutputOrRecoverFailureInReplacementSession() async throws {
        for succeeds in [true, false] {
            let capture = Gate()
            let source = try makeCapture()
            var outputs: [String] = []
            var failures = 0
            let preparation = FrozenSourcePreparation(
                waitForRaise: {}, excludePicker: {},
                capture: { target in
                    if target.label == "App" {
                        await capture.wait()
                        return succeeds ? source : nil
                    }
                    return source
                },
                onFailure: { failures += 1 }
            )
            let old = Task { await preparation.prepare(for: target) { _ in outputs.append("old") } }
            await capture.entered()
            preparation.cancel()
            let replacement = CaptureTarget(kind: .display(2), frame: source.frame,
                anchor: .zero, label: "replacement")
            await preparation.prepare(for: replacement) { _ in outputs.append("new") }
            capture.resume()
            await old.value
            XCTAssertEqual(outputs, ["new"])
            XCTAssertEqual(failures, 0)
        }
    }

    func testFailureRestoresPickerAndAllowsRetryForEitherDestination() async throws {
        for destination in ["copy", "edit"] {
            let source = try makeCapture()
            var pickerVisible = true
            var failures = 0
            var available: Capture?
            var received: Capture?
            let preparation = FrozenSourcePreparation(
                waitForRaise: {}, excludePicker: { pickerVisible = false },
                capture: { _ in available },
                onFailure: { failures += 1; pickerVisible = true }
            )
            await preparation.prepare(for: target) { received = $0 }
            XCTAssertNil(received, destination)
            XCTAssertTrue(pickerVisible, destination)
            XCTAssertEqual(failures, 1)
            available = source
            await preparation.prepare(for: target) { received = $0 }
            XCTAssertNotNil(received, destination)
            XCTAssertFalse(pickerVisible, destination)
            XCTAssertEqual(failures, 1)
        }
    }

    func testReplacingRequestDuringRaiseCannotHideNewPicker() async throws {
        let raise = Gate()
        let source = try makeCapture()
        var oldRequest = true
        var exclusions = 0
        var outputs: [String] = []
        let preparation = FrozenSourcePreparation(
            waitForRaise: { if oldRequest { await raise.wait() } },
            excludePicker: { exclusions += 1 }, capture: { _ in source },
            onFailure: { XCTFail("Unexpected capture failure") }
        )
        let old = Task { await preparation.prepare(for: target) { _ in outputs.append("old") } }
        await raise.entered()
        oldRequest = false
        await preparation.prepare(for: target) { _ in outputs.append("new") }
        raise.resume()
        await old.value
        XCTAssertEqual(exclusions, 1)
        XCTAssertEqual(outputs, ["new"])
    }

    func testTaskCancelledDuringCaptureCannotDeliverOutputOrFailure() async throws {
        for succeeds in [true, false] {
            let capture = Gate()
            let source = try makeCapture()
            let preparation = FrozenSourcePreparation(
                waitForRaise: {}, excludePicker: {},
                capture: { _ in await capture.wait(); return succeeds ? source : nil },
                onFailure: { XCTFail("Cancelled capture must not recover into a newer picker") }
            )
            let request = Task {
                await preparation.prepare(for: target) { _ in XCTFail("Cancelled capture delivered output") }
            }
            await capture.entered()
            request.cancel()
            capture.resume()
            await request.value
        }
    }

    private var target: CaptureTarget {
        CaptureTarget(kind: .window(7), frame: CGRect(x: -80, y: 30, width: 20, height: 10),
                      anchor: CGPoint(x: -70, y: 35), label: "App")
    }

    private func makeCapture() throws -> Capture {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return Capture(image: try XCTUnwrap(context.makeImage()), scale: 2,
            frame: CGRect(x: -100, y: 0, width: 100, height: 50),
            initialCrop: CGRect(x: 20, y: 30, width: 20, height: 10))
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer?.resume()
            observer = nil
        }
    }

    func entered() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
