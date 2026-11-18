import XCTest
import VishotConfiguration
import Carbon.HIToolbox
@testable import Vishot

final class MicrophoneOptionsTests: XCTestCase {
    func testSystemAudioIsOptionalAndCombinedSourcesAreSupported() throws {
        var options = VideoAudioOptions()
        XCTAssertEqual(options.summary(), "Audio off")
        options.systemEnabled = true
        try options.validate()
        XCTAssertEqual(options.summary(), "All system audio")
        options.microphoneEnabled = true
        XCTAssertEqual(options.summary(), "System + Mic")
        try options.validate()
        XCTAssertTrue(options.systemEnabled)
        XCTAssertTrue(options.microphoneEnabled)
    }
    func testSystemTogglePersistsIndependentlyAndInvalidValueKeepsLastGood() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "# keep audio notes\n[video]\nmicrophone = true # narration\n[custom]\nvalue = 42\n".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url, register: { _ in NSObject() })
        store.start(watching: false)
        store.update(systemAudioEnabled: true)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.active.systemAudioEnabled)
        XCTAssertTrue(store.active.microphoneEnabled)
        XCTAssertTrue(try AppSettings.read(url: url).systemAudioEnabled)
        let source = try String(contentsOf: url)
        XCTAssertTrue(source.contains("# narration"))
        XCTAssertTrue(source.contains("# keep audio notes"))
        store.update(systemAudioEnabled: false)
        XCTAssertFalse(try AppSettings.read(url: url).systemAudioEnabled)
        XCTAssertTrue(store.active.microphoneEnabled)
        try "[video]\nsystem_audio = 'anything'".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.active.microphoneEnabled)
        XCTAssertFalse(store.active.systemAudioEnabled)
    }
    func testSharedPopupRestoresInjectedInvokerOnlyOnOuterDismissalOnce() {
        let popup = CaptureOptions()
        var restored: [String] = []
        let rows = [CaptureOptions.Row(id: "choice", title: "Choice", choices: [.init(id: "value", title: "Value")])]
        for key in [kVK_Escape, kVK_ANSI_O] {
            let invoker = "window-\(key)"
            popup.open(rows: rows, restoreFocus: { restored.append(invoker) })
            popup.handle(kVK_Return)
            popup.handle(kVK_Escape)
            XCTAssertFalse(restored.contains(invoker), "Nested dismissal stays inside the popup")
            popup.handle(key)
            popup.close()
            XCTAssertEqual(restored.filter { $0 == invoker }.count, 1)
        }
        popup.open(rows: [], restoreFocus: { restored.append("mouse invoker") })
        XCTAssertTrue(popup.outsideClick())
        XCTAssertEqual(restored.last, "mouse invoker")
        popup.close()
        XCTAssertEqual(restored.count, 3)
    }
    func testRestrictedAndSilentPreflightNeverEnumerateOrPrompt() async throws {
        var status = MicrophoneAuthorization.restricted
        let permission = MicrophonePermission(readStatus: { status }, requestAccess: { _ in XCTFail("No prompt") })
        let preflight = MicrophonePreflight(permission: permission,
            devices: { XCTFail("No enumeration"); return [] }, defaultDevice: { XCTFail("No default lookup"); return nil })
        do { _ = try await preflight.resolve(enabled: true, device: ""); XCTFail("Restriction must block") }
        catch { XCTAssertTrue(error.localizedDescription.contains("restricted")) }
        status = .notDetermined
        let silent = try await preflight.resolve(enabled: false, device: "")
        XCTAssertNil(silent)
    }
    func testPreflightFreezesDefaultAndMissingDeviceNeverFallsBack() async throws {
        let permission = MicrophonePermission(readStatus: { .authorized }, requestAccess: { _ in XCTFail("Already authorized") })
        var current = "one"
        let preflight = MicrophonePreflight(permission: permission, devices: {
            [MicrophoneDevice(id: "one", name: "Same name"), MicrophoneDevice(id: "two", name: "Same name")]
        }, defaultDevice: { current })
        let frozen = try await preflight.resolve(enabled: true, device: "")
        current = "two"
        XCTAssertEqual(frozen?.id, "one")
        let specific = try await preflight.resolve(enabled: true, device: "two")
        XCTAssertEqual(specific?.id, "two")
        do { _ = try await preflight.resolve(enabled: true, device: "gone"); XCTFail("Missing device must block") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
        let silent = try await preflight.resolve(enabled: false, device: "gone")
        XCTAssertNil(silent)
    }
    func testReusablePopupNestedChooserAndConsumedDismissal() {
        var changes: [String] = []
        let popup = CaptureOptions()
        popup.open(rows: [
            .init(id: "toggle", title: "Microphone", value: "Off", activate: { changes.append("on") }),
            .init(id: "device", title: "Input", value: "Default", choices: [
                .init(id: "default", title: "System default", activate: { changes.append("default") }),
                .init(id: "usb", title: "USB", activate: { changes.append("usb") })])])
        XCTAssertTrue(popup.handle(kVK_Space))
        XCTAssertEqual(changes, ["on"])
        popup.handle(kVK_ANSI_J)
        popup.handle(kVK_Return)
        XCTAssertTrue(popup.isChoosing)
        popup.handle(kVK_Escape)
        XCTAssertTrue(popup.isOpen)
        XCTAssertFalse(popup.isChoosing)
        popup.handle(kVK_Return)
        popup.handle(kVK_DownArrow)
        popup.handle(kVK_Return)
        XCTAssertEqual(changes, ["on", "usb"])
        XCTAssertFalse(popup.isChoosing)
        XCTAssertTrue(popup.outsideClick())
        XCTAssertFalse(popup.isOpen)
        XCTAssertFalse(popup.outsideClick())
    }
    func testOptionsPersistWithoutLosingCommentsAndInvalidEditsKeepLastGood() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "# keep me\n[custom]\nvalue = 42\n".write(to: url, atomically: true, encoding: .utf8)
        let store = SettingsStore(url: url, register: { _ in NSObject() })
        store.start(watching: false)
        store.setSessionActive(true)
        store.update(microphoneEnabled: true, microphoneDevice: "usb:\"stable\\id")
        XCTAssertNil(store.error)
        XCTAssertTrue(store.configured!.microphoneEnabled)
        XCTAssertEqual(store.configured!.microphoneDevice, "usb:\"stable\\id")
        XCTAssertTrue(try String(contentsOf: url).contains("# keep me"))
        store.setSessionActive(false)
        try "[video]\nmicrophone = 'invalid'".write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.active.microphoneEnabled)
    }
}
