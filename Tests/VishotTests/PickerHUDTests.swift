import AppKit
import Carbon.HIToolbox
import XCTest
import VishotConfiguration
@testable import Vishot

final class PickerHUDTests: XCTestCase {
    func testScreenshotHasNoOptionsControlOrPopup() throws {
        let fixture = ControllerFixture()
        defer { fixture.remove() }
        fixture.controller.microphoneDevices = { XCTFail("Screenshot must not enumerate microphones"); return [] }
        fixture.controller.handle(try key(kVK_ANSI_O))
        fixture.controller.openCaptureOptions()
        XCTAssertFalse(fixture.controller.captureOptions.isOpen)
        for visual in VisualStyle.allCases {
            let theme = ThemeCatalog.resolve(style: visual, colorScheme: .dark)
            let hud = PickerHUD(scale: 2, style: theme.hud)
            hud.prepare(theme: theme)
            hud.show(.init(), status: "", size: CGSize(width: 1200, height: 900), visible: true)
            XCTAssertNil(hud.optionsFrame)
            hud.show(.init(captureType: .video), status: "", size: CGSize(width: 1200, height: 900), visible: true)
            XCTAssertNotNil(hud.optionsFrame)
        }
    }

    func testPixelMicrophoneDrawsCapsuleAboveStand() throws {
        _ = NSApplication.shared
        let button = AudioHUDButton(control: .microphone)
        button.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        button.configure(theme: ThemeCatalog.pixel, enabled: true)
        let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / 32
        func brightness(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
            return color.redComponent + color.greenComponent + color.blueComponent
        }
        // Bitmap rows run from the visual top. The capsule is broad near its
        // top; the stand has only a central stem at the matching bottom row.
        XCTAssertGreaterThan(try brightness(12, 8), try brightness(12, 24))
    }

    func testWindowMouseDispatchDismissesOptionsBeforeHUDButtonTrackingAndConsumesRelease() throws {
        _ = NSApplication.shared
        for visual in VisualStyle.allCases {
            let fixture = ControllerFixture()
            defer { fixture.remove() }
            let controller = fixture.controller
            controller.microphoneDevices = { [] }
            controller.handle(try key(kVK_ANSI_R))
            let before = try XCTUnwrap(controller.selection)
            var preferenceWrites = 0
            controller.onMicrophoneOptions = { _, _ in preferenceWrites += 1 }
            controller.onSystemAudioOptions = { _ in preferenceWrites += 1 }
            let theme = ThemeCatalog.resolve(style: visual, colorScheme: .dark)
            let panel = OverlayPanel(screen: try XCTUnwrap(NSScreen.main), theme: theme)
            defer { panel.close() }
            panel.prepare(theme: theme)
            panel.showHUD(controller.pickerHUDContent, status: "", visible: true)
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.onAudioToggle = { controller.toggleAudio($0) }
            panel.onOptions = { controller.openCaptureOptions() }
            panel.onDismissOptions = { controller.captureOptions.outsideClick() }
            panel.onMouseUp = { controller.mouseUp(at: $0) }
            let buttons = try XCTUnwrap(panel.contentView).subviews.compactMap { $0 as? NSButton }
            for name in ["Microphone", "System audio", "Capture options"] {
                let button = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == name })
                controller.openCaptureOptions()
                XCTAssertTrue(controller.captureOptions.isOpen)
                try dispatchOutsideClick(on: button, in: panel)
                XCTAssertFalse(controller.captureOptions.isOpen, "\(name) must dismiss the popup")
                XCTAssertFalse(controller.microphoneEnabled)
                XCTAssertFalse(controller.systemAudioEnabled)
                XCTAssertEqual(preferenceWrites, 0, "Outside clicks must not write remembered preferences")
                XCTAssertFalse(controller.pickerHUDContent.isCountingDown)
                assertTarget(controller.selection, matches: before)
            }
            // Normal activation is covered separately without an event-tracking loop.
            let mic = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Microphone" })
            mic.performClick(nil)
            XCTAssertTrue(controller.microphoneEnabled)
            XCTAssertEqual(preferenceWrites, 1)
            let options = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Capture options" })
            options.performClick(nil)
            XCTAssertTrue(controller.captureOptions.isOpen)
            try dispatchOutsideClick(on: options, in: panel)
            XCTAssertFalse(controller.captureOptions.isOpen, "Second Options click dismisses without reopening")
        }
    }

    private func dispatchOutsideClick(on button: NSButton, in panel: OverlayPanel) throws {
        // The outside gesture must be intercepted before native tracking. Fail at
        // that boundary rather than letting a regression block in AppKit's loop.
        let originalCell = button.cell
        button.cell = TrackingForbiddenCell(textCell: "")
        defer { button.cell = originalCell }
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: time, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: time + 0.1, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        panel.sendEvent(down)
        panel.sendEvent(up)
    }

    private final class TrackingForbiddenCell: NSButtonCell {
        override func trackMouse(with event: NSEvent, in cellFrame: NSRect,
                                 of controlView: NSView, untilMouseUp flag: Bool) -> Bool {
            XCTFail("Popup outside click reached native button tracking")
            return false
        }
    }

    func testAudioHitboxesFollowOptionsWithoutOverlapAcrossThemesScalesAndCompactDisplays() throws {
        for visual in VisualStyle.allCases {
            let theme = ThemeCatalog.resolve(style: visual, colorScheme: .dark)
            for scale: CGFloat in [1, 2] {
                let hud = PickerHUD(scale: scale, style: theme.hud)
                hud.prepare(theme: theme)
                for width: CGFloat in [320, 800, 2000] {
                    var content = PickerHUD.Content(captureType: .video)
                    hud.show(content, status: "", size: CGSize(width: width, height: 900), visible: true)
                    let options = try XCTUnwrap(hud.optionsFrame)
                    let mic = try XCTUnwrap(hud.audioFrame(.microphone))
                    let system = try XCTUnwrap(hud.audioFrame(.system))
                    for frame in [mic, system] {
                        XCTAssertTrue(hud.root.frame.contains(frame))
                        XCTAssertGreaterThanOrEqual(frame.width, 32)
                        XCTAssertGreaterThanOrEqual(frame.height, 32)
                        XCTAssertFalse(frame.intersects(options))
                    }
                    XCTAssertFalse(mic.intersects(system))
                    XCTAssertTrue(mic.minY < options.minY || mic.minX > options.maxX)
                    XCTAssertTrue(system.minY < mic.minY || system.minX > mic.maxX)
                    content.microphoneEnabled = true
                    content.systemAudioEnabled = true
                    hud.show(content, status: "", size: CGSize(width: width, height: 900), visible: true)
                    XCTAssertEqual(hud.audioFrame(.microphone), mic)
                    XCTAssertEqual(hud.audioFrame(.system), system)
                    for state in [PickerHUD.Content(), .init(captureType: .video, picker: .hint), .init(captureType: .video, isCountingDown: true)] {
                        hud.show(state, status: "", size: CGSize(width: width, height: 900), visible: true)
                        XCTAssertNil(hud.audioFrame(.microphone))
                        XCTAssertNil(hud.audioFrame(.system))
                    }
                }
            }
        }
    }

    func testNativeAudioControlsToggleSharedRememberedOptionsWithoutSelectingOrCapturing() throws {
        _ = NSApplication.shared
        let fixture = ControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller
        controller.microphoneDevices = { XCTFail("HUD toggles must not discover audio devices"); return [] }
        let before = try XCTUnwrap(controller.selection)
        let panel = OverlayPanel(screen: try XCTUnwrap(NSScreen.main), theme: ThemeCatalog.pixel)
        defer { panel.close() }
        panel.prepare(theme: ThemeCatalog.pixel)
        panel.onAudioToggle = { controller.toggleAudio($0) }
        let url = fixture.root.appendingPathComponent("settings.toml")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let store = SettingsStore(url: url, register: { _ in NSObject() })
        store.start(watching: false)
        controller.onMicrophoneOptions = { store.update(microphoneEnabled: $0, microphoneDevice: $1) }
        controller.onSystemAudioOptions = { store.update(systemAudioEnabled: $0) }
        panel.showHUD(controller.pickerHUDContent, status: "", visible: true)
        let controls = panel.contentView!.subviews.compactMap { $0 as? NSButton }
        let mic = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "Microphone" })
        let system = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "System audio" })
        XCTAssertTrue(mic.isHidden)
        XCTAssertTrue(system.isHidden)
        controller.handle(try key(kVK_ANSI_R))
        panel.showHUD(controller.pickerHUDContent, status: "", visible: true)
        XCTAssertFalse(mic.isHidden)
        XCTAssertFalse(system.isHidden)
        XCTAssertEqual(mic.accessibilityValue() as? String, "Off")
        XCTAssertEqual(mic.toolTip, "Microphone off — click to turn on")
        mic.performClick(nil)
        controller.mouseUp(at: before.anchor)
        XCTAssertTrue(controller.microphoneEnabled)
        XCTAssertFalse(controller.systemAudioEnabled)
        system.performClick(nil)
        controller.mouseUp(at: before.anchor)
        XCTAssertTrue(controller.systemAudioEnabled)
        panel.showHUD(controller.pickerHUDContent, status: "", visible: true)
        XCTAssertEqual(system.accessibilityValue() as? String, "On")
        XCTAssertEqual(system.toolTip, "System audio on — click to turn off")
        XCTAssertTrue(try AppSettings.read(url: url).microphoneEnabled)
        XCTAssertTrue(try AppSettings.read(url: url).systemAudioEnabled)
        XCTAssertFalse(controller.pickerHUDContent.isCountingDown)
        assertTarget(controller.selection, matches: before)
        controller.microphoneDevices = { [] }
        controller.openCaptureOptions()
        XCTAssertEqual(controller.captureOptions.visibleRows.first { $0.id == "microphone" }?.value, "On")
        controller.captureOptions.activate(0)
        controller.captureOptions.close()
        panel.showHUD(controller.pickerHUDContent, status: "", visible: true)
        XCTAssertEqual(mic.accessibilityValue() as? String, "Off")
        XCTAssertFalse(try AppSettings.read(url: url).microphoneEnabled)
        XCTAssertTrue(try AppSettings.read(url: url).systemAudioEnabled)
    }

    func testSystemPopupCapturesWholeMacAcrossTargetsAndNeverDropsMic() throws {
        let fixture = ControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller
        controller.microphoneDevices = { [] }
        controller.handle(try key(kVK_ANSI_R))
        controller.openCaptureOptions()
        let popup = controller.captureOptions
        popup.activate(try XCTUnwrap(popup.visibleRows.firstIndex { $0.id == "system-audio" }))
        XCTAssertTrue(controller.systemAudioEnabled)
        XCTAssertEqual(controller.audioSummary, "All system audio")
        XCTAssertEqual(try XCTUnwrap(popup.visibleRows.first { $0.id == "system-audio" }).title, "System audio")
        let explanation = "Captures audio from all apps and notifications, regardless of the picture target (excluding Vishot)."
        XCTAssertTrue(popup.visibleRows.contains { $0.title == explanation })
        XCTAssertEqual(popup.visibleRows.filter { !$0.choices.isEmpty }.count, 1, "Only the microphone device needs a chooser")
        popup.activate(0)
        XCTAssertTrue(controller.microphoneEnabled)
        XCTAssertTrue(controller.systemAudioEnabled)
        XCTAssertEqual(controller.audioSummary, "System + Mic")
        XCTAssertFalse(popup.visibleRows.contains { $0.id == "mix-unavailable" || $0.title.localizedCaseInsensitiveContains("combined audio unavailable") })
        popup.close()
        controller.handle(try key(kVK_ANSI_G, flags: .shift))
        XCTAssertEqual(controller.audioSummary, "System + Mic")
        controller.openCaptureOptions()
        XCTAssertTrue(popup.visibleRows.contains { $0.title == explanation })
        popup.close()
        controller.handle(try key(kVK_ANSI_V))
        XCTAssertEqual(controller.audioSummary, "System + Mic")
        controller.openCaptureOptions()
        XCTAssertTrue(popup.visibleRows.contains { $0.title == explanation })
    }
    func testNativeOptionsControlDismissesExistingPopupWithoutLosingTarget() throws {
        _ = NSApplication.shared
        let fixture = ControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller
        controller.handle(try key(kVK_ANSI_R))
        let before = try XCTUnwrap(controller.selection)
        let panel = OverlayPanel(screen: try XCTUnwrap(NSScreen.main), theme: ThemeCatalog.pixel)
        defer { panel.close() }
        panel.prepare(theme: ThemeCatalog.pixel)
        panel.showHUD(controller.pickerHUDContent, status: "", visible: true)
        panel.onOptions = { controller.openCaptureOptions() }
        let button = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Capture options" })
        button.performClick(nil)
        XCTAssertTrue(controller.captureOptions.isOpen)
        button.performClick(nil)
        XCTAssertFalse(controller.captureOptions.isOpen, "Native HUD invocation dismisses rather than replaces an open popup")
        controller.mouseUp(at: before.anchor)
        XCTAssertFalse(controller.pickerHUDContent.isCountingDown)
        assertTarget(controller.selection, matches: before)
    }

    func testKeyboardOptionsDismissalImmediatelyRestoresPointerNavigation() throws {
        for code in [kVK_Escape, kVK_ANSI_O] {
            let fixture = ControllerFixture()
            defer { fixture.remove() }
            let controller = fixture.controller
            controller.handle(try key(kVK_ANSI_R))
            controller.handle(try key(kVK_ANSI_V))
            controller.handle(try key(kVK_ANSI_V)) // Anchor a region at the cursor.
            controller.handle(try key(kVK_ANSI_O))
            controller.handle(try key(code))
            XCTAssertFalse(controller.captureOptions.isOpen)
            controller.mouseMoved(to: CGPoint(x: 500, y: 450))
            XCTAssertEqual(controller.selection?.frame.maxX, 500)
            XCTAssertEqual(controller.selection?.frame.maxY, 450)
        }
    }
    func testPhysicalOptionsInputPreservesTargetAndOutsideGestureIsConsumed() throws {
        let fixture = ControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller
        controller.microphoneDevices = { [.init(id: "usb", name: "USB")] }
        let before = try XCTUnwrap(controller.selection)
        controller.handle(try key(kVK_ANSI_R))
        controller.handle(try key(kVK_ANSI_O, characters: "я"))
        XCTAssertTrue(controller.captureOptions.isOpen)
        controller.handle(try key(kVK_Space))
        XCTAssertTrue(controller.microphoneEnabled)
        controller.handle(try key(kVK_ANSI_J))
        controller.handle(try key(kVK_ANSI_J))
        controller.handle(try key(kVK_Return))
        XCTAssertTrue(controller.captureOptions.isChoosing)
        controller.handle(try key(kVK_Escape))
        XCTAssertTrue(controller.captureOptions.isOpen)
        controller.mouseDown(at: before.anchor)
        controller.mouseUp(at: before.anchor)
        XCTAssertFalse(controller.captureOptions.isOpen)
        XCTAssertFalse(controller.pickerHUDContent.isCountingDown)
        assertTarget(controller.selection, matches: before)
        controller.handle(try key(kVK_ANSI_O))
        controller.handle(try key(kVK_ANSI_O))
        XCTAssertFalse(controller.captureOptions.isOpen)
        controller.handle(try key(kVK_ANSI_S))
        controller.handle(try key(kVK_ANSI_O))
        XCTAssertFalse(controller.captureOptions.isOpen, "Screenshot has no options popup")
        controller.captureOptions.close()
        controller.handle(try key(kVK_ANSI_F))
        controller.handle(try key(kVK_ANSI_O))
        XCTAssertFalse(controller.captureOptions.isOpen)
        XCTAssertEqual(controller.pickerHUDContent.picker, .element)
    }
    func testCaptureTypeSwitchKeepsHUDWidthAndPickerColumnsStable() throws {
        for visual in VisualStyle.allCases {
            let theme = ThemeCatalog.resolve(style: visual, colorScheme: .dark)
            let hud = PickerHUD(scale: 2, style: theme.hud)
            hud.prepare(theme: theme)
            for picker in PickerHUD.Picker.allCases {
                for width: CGFloat in [320, 800, 2000] {
                    let size = CGSize(width: width, height: 900)
                    hud.show(PickerHUD.Content(picker: picker), status: "", size: size, visible: true)
                    let before = hud.root.frame
                    hud.show(PickerHUD.Content(captureType: .video, picker: picker), status: "", size: size, visible: true)
                    XCTAssertEqual(hud.root.frame.width, before.width)
                    XCTAssertEqual(hud.root.frame.minX, before.minX)
                }
            }
        }
    }

    func testTopControlsShareColumnsWithBottomActions() throws {
        for visual in VisualStyle.allCases {
            let theme = ThemeCatalog.resolve(style: visual, colorScheme: .dark)
            let hud = PickerHUD(scale: 2, style: theme.hud)
            hud.prepare(theme: theme)
            for type in PickerHUD.CaptureType.allCases {
                hud.show(PickerHUD.Content(captureType: type), status: "", size: CGSize(width: 2000, height: 900), visible: true)
                let pairs = type == .screenshot
                    ? [("Select elements", "Copy to clipboard"), ("Whole screen", "Edit"), ("Select region", "Cancel")]
                    : [("Select elements", "Record"), ("Select region", "Cancel")]
                for (top, bottom) in pairs {
                    let topEntry = try XCTUnwrap(text(top, in: hud.root)?.superlayer)
                    let bottomEntry = try XCTUnwrap(text(bottom, in: hud.root)?.superlayer)
                    XCTAssertEqual(hud.root.convert(topEntry.bounds, from: topEntry).minX,
                                   hud.root.convert(bottomEntry.bounds, from: bottomEntry).minX, accuracy: 0.01)
                }
            }
        }
    }

    func testControllerPhysicalTypeKeysPreserveTargetsAcrossEveryPickerAndHistoryOff() throws {
        for picker in [PickerHUD.Picker.window, .element, .screen, .region] {
            let fixture = ControllerFixture()
            defer { fixture.remove() }
            let controller = fixture.controller
            XCTAssertEqual(controller.pickerHUDContent.captureType, .screenshot)
            switch picker {
            case .element:
                controller.handle(try key(kVK_ANSI_F))
                controller.handle(try key(kVK_ANSI_A))
            case .screen: controller.handle(try key(kVK_ANSI_G, flags: .shift))
            case .region:
                controller.handle(try key(kVK_ANSI_V))
                controller.mouseDown(at: CGPoint(x: 100, y: 100))
                controller.mouseDragged(to: CGPoint(x: 300, y: 250))
                controller.mouseUp(at: CGPoint(x: 300, y: 250))
            default: break
            }
            let before = try XCTUnwrap(controller.selection)
            XCTAssertEqual(controller.pickerHUDContent.picker, picker)
            // Deliberately conflicting characters: dispatch must use physical codes.
            controller.handle(try key(kVK_ANSI_R, characters: "s"))
            XCTAssertEqual(controller.pickerHUDContent.captureType, .video)
            XCTAssertEqual(controller.pickerHUDContent.picker, picker)
            assertTarget(controller.selection, matches: before)
            controller.handle(try key(kVK_ANSI_S, characters: "r"))
            XCTAssertEqual(controller.pickerHUDContent.captureType, .screenshot)
            XCTAssertEqual(controller.pickerHUDContent.picker, picker)
            assertTarget(controller.selection, matches: before)
            fixture.history.retention = .off
            controller.handle(try key(kVK_ANSI_R))
            XCTAssertEqual(controller.pickerHUDContent.captureType, .screenshot)
            XCTAssertEqual(controller.pickerHUDContent.typeSwitch?.unavailableReason, PickerHUD.historyUnavailableReason)
            assertTarget(controller.selection, matches: before)
        }
    }

    func testControllerHintKeysTakePriorityOverBothCaptureTypeSwitchesWithNonLatinCharacters() throws {
        for (code, initialType, expectedLabel) in [(kVK_ANSI_R, PickerHUD.CaptureType.screenshot, "Element 12"),
                                                  (kVK_ANSI_S, .video, "Element 1")] {
            let fixture = ControllerFixture()
            defer { fixture.remove() }
            let controller = fixture.controller
            if initialType == .video { controller.handle(try key(kVK_ANSI_R)) }
            controller.handle(try key(kVK_ANSI_F))
            XCTAssertEqual(controller.pickerHUDContent.picker, .hint)
            controller.handle(try key(code))
            XCTAssertEqual(controller.pickerHUDContent.picker, .element)
            XCTAssertEqual(controller.pickerHUDContent.captureType, initialType)
            XCTAssertEqual(controller.selection?.label, expectedLabel)
            guard case .element(windowID: 42, rect: _)? = controller.selection?.kind else {
                return XCTFail("The physical hint must select its element")
            }
        }
    }

    @MainActor func testControllerEscapeDuringCountdownAndPendingPreparationRestoresSameRegion() async throws {
        for cancelDuringPreparation in [false, true] {
            let fixture = ControllerFixture()
            defer { fixture.remove() }
            let controller = fixture.controller
            let clock = CountdownTestClock()
            var pending: CheckedContinuation<VideoRecording, Error>?
            let video = VideoSession(sessions: fixture.sessions, history: fixture.history,
                prepare: { _, _ in try await withCheckedThrowingContinuation { pending = $0 } },
                resolve: { selection in try selection.resolve(displays: [VideoDisplay(id: 1, frame: fixture.display.frame, scale: 1)], windowFrame: nil) },
                countdown: CaptureCountdown(schedule: clock.schedule), presentsControls: false, reportError: { _, _ in }, screenCaptureGranted: { true })
            controller.video = video
            // Same callback wiring as AppDelegate; keep the actual VideoSession.
            video.onCountdown = { [weak controller] in controller?.videoCountdownStatus($0) }
            video.onReturnToPicker = { [weak controller] in controller?.videoReturnToPicker($0) }
            controller.handle(try key(kVK_ANSI_V))
            controller.mouseDown(at: CGPoint(x: 100, y: 100))
            controller.mouseDragged(to: CGPoint(x: 300, y: 250))
            controller.mouseUp(at: CGPoint(x: 300, y: 250))
            controller.handle(try key(kVK_ANSI_R))
            let target = try XCTUnwrap(controller.selection)
            controller.handle(try key(kVK_Return))
            try await eventually { clock.hasJobs }
            XCTAssertEqual(controller.pickerHUDContent.actions, [HUDKey("esc", action: "Cancel")])
            controller.handle(try key(kVK_ANSI_S))
            XCTAssertEqual(controller.pickerHUDContent.captureType, .video, "Ordinary picker keys are disabled")
            if cancelDuringPreparation {
                clock.advance(to: 3)
                try await eventually { pending != nil }
                XCTAssertTrue(controller.pickerHUDContent.isCountingDown)
            }
            controller.handle(try key(kVK_Escape))
            XCTAssertFalse(video.isActive)
            XCTAssertFalse(controller.pickerHUDContent.isCountingDown)
            XCTAssertTrue(fixture.sessions.acceptsCallbacks(fixture.sessions.callbackSession))
            XCTAssertEqual(controller.pickerHUDContent.picker, .region)
            XCTAssertEqual(controller.pickerHUDContent.regionState, .ready)
            XCTAssertEqual(controller.pickerHUDContent.captureType, .video)
            XCTAssertEqual(controller.pickerHUDContent.actions.first, HUDKey("↵", action: "Record"))
            assertTarget(controller.selection, matches: target)
            pending?.resume(throwing: CancellationError())
            clock.advance(to: 10)
            fixture.sessions.finish(fixture.sessions.callbackSession)
            try await eventually { !fixture.sessions.isSessionActive }
            XCTAssertFalse(controller.pickerHUDContent.isCountingDown)
            assertTarget(controller.selection, matches: target)
        }
    }

    func testControllerUnfinishedRegionHidesCaptureActionsAndReturnStillFinishesAndCaptures() throws {
        let fixture = ControllerFixture()
        defer { fixture.remove() }
        let controller = fixture.controller
        controller.handle(try key(kVK_ANSI_V))
        for drawing in [false, true] {
            if drawing {
                controller.mouseDown(at: CGPoint(x: 100, y: 100))
                controller.mouseDragged(to: CGPoint(x: 300, y: 250))
            }
            for code in [kVK_ANSI_S, kVK_ANSI_R] {
                controller.handle(try key(code))
                XCTAssertEqual(controller.pickerHUDContent.regionState, drawing ? .drawing : .empty)
                XCTAssertFalse(controller.pickerHUDContent.actions.contains { ["Copy", "Record", "Edit"].contains($0.action) })
            }
            if !drawing {
                controller.handle(try key(kVK_Return))
                XCTAssertFalse(controller.pickerHUDContent.isCountingDown)
                XCTAssertEqual(controller.pickerHUDContent.regionState, .empty)
            }
        }
        let draft = try XCTUnwrap(controller.selection)
        controller.handle(try key(kVK_Return))
        XCTAssertEqual(controller.pickerHUDContent.regionState, .ready, "Return retains the existing finish-and-capture semantics")
        XCTAssertTrue(controller.pickerHUDContent.isCountingDown, "Return must dispatch Record for the finished rectangle")
        assertTarget(controller.selection, matches: draft)
    }

    func testEveryPreparedPickerStateRendersItsApplicableGuidanceIncludingCountdownAndPreparing() throws {
        for visual in VisualStyle.allCases {
            let theme = ThemeCatalog.resolve(style: visual, colorScheme: .dark)
            let hud = PickerHUD(scale: 2, style: theme.hud)
            hud.prepare(theme: theme)
            for type in PickerHUD.CaptureType.allCases {
                for picker in PickerHUD.Picker.allCases {
                    for region in PickerHUD.RegionState.allCases {
                        for countdown in [false, true] {
                            let content = PickerHUD.Content(captureType: type, picker: picker, regionState: region, isCountingDown: countdown)
                            for width: CGFloat in [320, 800] {
                                hud.show(content, status: countdown ? "Preparing…" : "", size: CGSize(width: width, height: 900), visible: true)
                                XCTAssertNotNil(text(content.captureName, in: hud.root))
                                for key in content.actions + content.navigation {
                                    let layer = try XCTUnwrap(text(key.action == "Copy" ? "Copy to clipboard" : key.action, in: hud.root))
                                    XCTAssertTrue(hud.root.bounds.contains(hud.root.convert(layer.bounds, from: layer)), "\(key.action)")
                                }
                                XCTAssertNil(text("Window", in: hud.root))
                                XCTAssertNil(text("Element", in: hud.root))
                                if countdown {
                                    XCTAssertNil(text("Record", in: hud.root))
                                    XCTAssertNil(text("Window", in: hud.root))
                                    XCTAssertNotNil(text("Preparing…", in: hud.root))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testRegionGuidanceTracksRealDrawingWithoutAdvertisingCaptureUntilFinished() throws {
        let frame = CGRect(x: -800, y: 0, width: 800, height: 600)
        let display = CaptureTarget(kind: .display(1), frame: frame,
            anchor: CGPoint(x: -400, y: 300), label: "Display")
        let region = RegionSelector(displays: [display], start: display.anchor)
        XCTAssertEqual(region.hudState, .empty)
        region.mouseDown(at: CGPoint(x: -500, y: 100))
        region.mouseDragged(to: CGPoint(x: -200, y: 300))
        XCTAssertNotNil(region.target, "The outline is visible while drawing")
        XCTAssertEqual(region.hudState, .drawing)
        XCTAssertFalse(PickerHUD.Content(picker: .region, regionState: region.hudState).actions.contains { $0.action == "Copy" })
        _ = region.mouseUp(at: CGPoint(x: -200, y: 300))
        XCTAssertEqual(region.hudState, .ready)
        let target = try XCTUnwrap(region.target)
        var content = PickerHUD.Content(picker: .region, regionState: region.hudState)
        _ = content.handleCaptureTypeKey(kVK_ANSI_R)
        XCTAssertEqual(region.target?.frame, target.frame)
        XCTAssertEqual(region.status(captureType: .video), "v or drag to redraw · click it to record · 0 $ g G M jump")
        XCTAssertEqual(region.status(captureType: .screenshot), "v or drag to redraw · click it to copy · 0 $ g G M jump")
    }

    func testPhysicalCaptureTypeKeysPreservePickerContextAndYieldToHintsAndHistoryOff() {
        var content = PickerHUD.Content(picker: .region, regionState: .drawing)
        XCTAssertEqual(content.handleCaptureTypeKey(kVK_ANSI_R), .handled)
        XCTAssertEqual(content.captureType, .video)
        XCTAssertEqual(content.picker, .region)
        XCTAssertEqual(content.regionState, .drawing)
        XCTAssertEqual(content.handleCaptureTypeKey(kVK_ANSI_S), .handled)
        XCTAssertEqual(content.captureType, .screenshot)
        content.historyAvailable = false
        XCTAssertEqual(content.handleCaptureTypeKey(kVK_ANSI_R), .unavailable)
        XCTAssertEqual(content.captureType, .screenshot)
        content.picker = .hint
        for key in [kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_F] {
            XCTAssertEqual(content.handleCaptureTypeKey(key), .unhandled)
        }
        XCTAssertEqual(content.captureType, .screenshot)
        XCTAssertEqual(PickerHUD.Content().captureType, .screenshot)
    }

    func testCaptureTypeIsProminentWithOnlyTheAlternativeSwitchAndContextualActions() {
        let screenshot = PickerHUD.Content(captureType: .screenshot, picker: .window)
        XCTAssertEqual(screenshot.captureName, "Screenshot")
        XCTAssertEqual(screenshot.typeSwitch, HUDKey("r", action: "Switch to video"))
        XCTAssertEqual(screenshot.actions, [HUDKey("↵", action: "Copy"), HUDKey("e", action: "Edit"), HUDKey("esc", action: "Cancel")])
        let video = PickerHUD.Content(captureType: .video, picker: .window)
        XCTAssertEqual(video.captureName, "Video")
        XCTAssertEqual(video.typeSwitch, HUDKey("s", action: "Switch to screenshot"))
        XCTAssertEqual(video.actions, [HUDKey("↵", action: "Record"), HUDKey("esc", action: "Cancel")])
    }

    func testPickerChoicesRemainStableWhileHintsPermissionsAndRegionActionsAreContextual() {
        for picker in PickerHUD.Picker.allCases {
            var content = PickerHUD.Content(picker: picker)
            XCTAssertEqual(content.choices.map(\.picker), [.window, .element, .screen, .region])
            XCTAssertEqual(content.choices.filter(\.isActive).map(\.picker), [picker == .hint ? .element : picker])
            XCTAssertTrue(content.choices.allSatisfy { $0.key.keys.isEmpty }, "Choices must not invent direct shortcuts")
            if picker == .hint {
                XCTAssertNil(content.typeSwitch)
                XCTAssertEqual(content.navigation, [HUDKey(action: "Type a hint"), HUDKey("⌫", action: "Undo")])
                XCTAssertEqual(content.actions, [HUDKey("esc", action: "Back")])
            }
            content.accessibilityAvailable = false
            XCTAssertEqual(content.choices[1].key.unavailableReason, PickerHUD.elementUnavailableReason)
            content.historyAvailable = false
            if picker != .hint { XCTAssertEqual(content.typeSwitch?.unavailableReason, PickerHUD.historyUnavailableReason) }
        }
        var region = PickerHUD.Content(picker: .region)
        region.regionState = .empty
        XCTAssertEqual(region.actions, [HUDKey("esc", action: "Back"), HUDKey("q", action: "Cancel")])
        XCTAssertTrue(region.navigation.contains(HUDKey("v", action: "Start region")))
        region.regionState = .drawing
        XCTAssertEqual(region.actions, [HUDKey("esc", action: "Cancel region"), HUDKey("q", action: "Cancel")])
        XCTAssertFalse(region.navigation.contains { $0.keys.contains("tab") })
        XCTAssertTrue(region.navigation.contains(HUDKey("v", action: "Finish region")))
        region.regionState = .ready
        XCTAssertEqual(region.actions.first, HUDKey("↵", action: "Copy"))
        region.captureType = .video
        XCTAssertEqual(region.actions.first, HUDKey("↵", action: "Record"))
        XCTAssertFalse(region.actions.contains { $0.action == "Edit" })
        region.isCountingDown = true
        XCTAssertEqual(region.actions, [HUDKey("esc", action: "Cancel")])
        XCTAssertNil(region.typeSwitch)
        XCTAssertTrue(region.navigation.isEmpty)
        XCTAssertTrue(region.choices.isEmpty)
    }

    func testUnavailableEntryRetainsItsReasonAndDimsTheWholeControl() {
        let reason = "Element selection needs Accessibility. Enable it in Vishot Settings."
        let key = PickerHUD.elementsKey(accessibilityAvailable: false)
        XCTAssertFalse(key.isEnabled)
        XCTAssertEqual(key.unavailableReason, reason)
        let disabled = HUD.makeEntry(key, scale: 2, style: ThemeCatalog.pixel.hud)
        let enabledKey = PickerHUD.elementsKey(accessibilityAvailable: true)
        XCTAssertTrue(enabledKey.isEnabled)
        XCTAssertNil(enabledKey.unavailableReason)
        XCTAssertEqual(enabledKey.keys, ["f"])
        XCTAssertEqual(enabledKey.action, "Select elements")
        let enabled = HUD.makeEntry(enabledKey, scale: 2, style: ThemeCatalog.pixel.hud)
        XCTAssertLessThan(disabled.layer.opacity, enabled.layer.opacity)
        XCTAssertEqual(disabled.layer.bounds.size, enabled.layer.bounds.size)
        XCTAssertTrue(HUDKey("hjkl", action: "move").isEnabled)
    }

    func testThreeAreasWrapWithoutClippingAndPermissionFeedbackKeepsControlsStill() throws {
        for visual in VisualStyle.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for scale: CGFloat in [1, 2] {
                    let theme = ThemeCatalog.resolve(style: visual, colorScheme: scheme)
                    let hud = PickerHUD(scale: scale, style: theme.hud)
                    hud.prepare(theme: theme)
                    let content = PickerHUD.Content(accessibilityAvailable: false)
                    for width: CGFloat in [320, 800, 1440] {
                        let size = CGSize(width: width, height: 900)
                        hud.show(content, status: "", size: size, visible: true)
                        for label in ["Screenshot", "Switch to video", "Select elements", "Whole screen", "Select region", "Copy to clipboard", "Edit", "Cancel"] {
                            let layer = try XCTUnwrap(text(label, in: hud.root))
                            let rect = hud.root.convert(layer.bounds, from: layer)
                            XCTAssertTrue(hud.root.bounds.contains(rect), "\(label) clipped at \(width)")
                            XCTAssertFalse(layer.isHidden)
                        }
                        let element = try XCTUnwrap(text("Select elements", in: hud.root))
                        let point = element.convert(CGPoint(x: element.bounds.midX, y: element.bounds.midY), to: hud.root)
                            .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                        XCTAssertEqual(hud.unavailableReason(at: point), PickerHUD.elementUnavailableReason)
                        XCTAssertTrue(hud.contains(point))
                        XCTAssertFalse(hud.contains(CGPoint(x: -1, y: -1)))
                        let before = element.convert(element.bounds, to: hud.root)
                        hud.show(content, status: PickerHUD.elementUnavailableReason, size: size, visible: true)
                        XCTAssertEqual(element.convert(element.bounds, to: hud.root), before)
                        XCTAssertEqual(hud.unavailableReason(at: point), PickerHUD.elementUnavailableReason)
                        XCTAssertLessThanOrEqual(hud.root.frame.maxX, size.width)
                        XCTAssertGreaterThanOrEqual(hud.root.frame.minX, 0)
                    }
                }
            }
        }
    }

    func testHoverFollowsVisibleEntryThroughStatusResizingClippingAndAvailabilityChanges() throws {
        for scale: CGFloat in [1, 2] {
            for width: CGFloat in [320, 800, 1440] {
                let hud = PickerHUD(scale: scale)
                let reason = "Element selection needs Accessibility. Enable it in Vishot Settings."
                hud.prepare(theme: ThemeCatalog.pixel)
                var content = PickerHUD.Content(accessibilityAvailable: false)
                let size = CGSize(width: width, height: 900)
                hud.show(content, status: "", size: size, visible: true)
                let entry = try XCTUnwrap(text("Select elements", in: hud.root)?.superlayer)
                let point = hud.root.convert(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY), from: entry)
                    .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                let row = try XCTUnwrap(entry.superlayer)
                let visible = row.bounds.contains(row.convert(CGPoint(x: entry.bounds.midX, y: entry.bounds.midY), from: entry))
                XCTAssertEqual(hud.unavailableReason(at: point), visible ? reason : nil)
                hud.show(content, status: reason, size: size, visible: true)
                XCTAssertEqual(hud.unavailableReason(at: point), visible ? reason : nil, "status must not move the hovered entry")
                let entryRect = row.convert(entry.bounds, from: entry)
                let clipped = entryRect.intersection(row.bounds)
                if !clipped.isEmpty {
                    let visiblePoint = row.convert(CGPoint(x: clipped.minX + 0.5, y: clipped.midY), to: hud.root)
                        .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                    XCTAssertEqual(hud.unavailableReason(at: visiblePoint), reason)
                }
                if entryRect.maxX > row.bounds.maxX {
                    let clippedPoint = row.convert(CGPoint(x: row.bounds.maxX + 1, y: entryRect.midY), to: hud.root)
                        .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                    XCTAssertNil(hud.unavailableReason(at: clippedPoint))
                }
                let move = try XCTUnwrap(text("Whole screen", in: hud.root)?.superlayer)
                let movePoint = hud.root.convert(CGPoint(x: move.bounds.midX, y: move.bounds.midY), from: move)
                    .applying(CGAffineTransform(translationX: hud.root.frame.minX, y: hud.root.frame.minY))
                XCTAssertNil(hud.unavailableReason(at: movePoint))
                hud.show(content, status: "", size: size, visible: false)
                XCTAssertNil(hud.unavailableReason(at: point))
                content.accessibilityAvailable = true
                hud.show(content, status: "", size: size, visible: true)
                XCTAssertNil(hud.unavailableReason(at: point))
                content.accessibilityAvailable = false
                hud.show(content, status: "", size: size, visible: true)
                XCTAssertEqual(hud.unavailableReason(at: point), visible ? reason : nil)
                content.isCountingDown = true
                hud.show(content, status: "", size: size, visible: true)
                XCTAssertNil(hud.unavailableReason(at: point))
            }
        }
    }

    private func text(_ value: String, in layer: CALayer) -> CATextLayer? {
        if let text = layer as? CATextLayer, text.string as? String == value { return text }
        for child in layer.sublayers ?? [] {
            if let found = text(value, in: child) { return found }
        }
        return nil
    }

    private func key(_ code: Int, characters: String = "я", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
    }

    private func assertTarget(_ actual: CaptureTarget?, matches expected: CaptureTarget, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual?.frame, expected.frame, file: file, line: line)
        XCTAssertEqual(actual?.anchor, expected.anchor, file: file, line: line)
        XCTAssertEqual(actual?.label, expected.label, file: file, line: line)
        switch (actual?.kind, expected.kind) {
        case (.window(let a)?, .window(let b)), (.display(let a)?, .display(let b)): XCTAssertEqual(a, b, file: file, line: line)
        case (.element(let a, let ar)?, .element(let b, let br)), (.region(let a, let ar)?, .region(let b, let br)):
            XCTAssertEqual(a, b, file: file, line: line)
            XCTAssertEqual(ar, br, file: file, line: line)
        default: XCTFail("Target kind changed", file: file, line: line)
        }
    }

    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Controller did not reach expected state")
        throw CancellationError()
    }

    private final class ControllerFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = CaptureSessionCoordinator()
        let history: HistoryLibrary
        let controller: OverlayController
        let display = CaptureTarget(kind: .display(1), frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            anchor: CGPoint(x: 400, y: 300), label: "Display")
        init() {
            history = HistoryLibrary(store: HistoryStore(url: root.appendingPathComponent("History")))
            let window = WindowInfo(id: 42, pid: 0, appName: "Window", frame: CGRect(x: 50, y: 50, width: 500, height: 400),
                anchor: CGPoint(x: 300, y: 250))
            let hints: [CaptureTarget] = (0..<26).map { index -> CaptureTarget in
                let x = CGFloat(100 + index * 10)
                let frame = CGRect(x: x, y: 100, width: 40, height: 40)
                let anchor = CGPoint(x: x + 20, y: 120)
                return CaptureTarget(kind: .element(windowID: 42, rect: frame),
                    frame: frame, anchor: anchor, label: "Element \(index)")
            }
            let display = display
            controller = OverlayController(sessions: sessions, history: history, presentsPanels: false,
                windowCatalog: { [window] }, displayCatalog: { [display] }, hintCatalog: { _ in hints })
            sessions.onCapture = { [weak controller] in controller?.show(session: $0) == true }
            sessions.capture()
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
