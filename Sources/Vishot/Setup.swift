import Foundation

/// The setup boundary: permission snapshots are transient; only finishing the guide is remembered.
final class SetupFlow {
    private let isComplete: () -> Bool
    private let rememberCompletion: () -> Void
    private let readAccess: () -> (screen: Bool, accessibility: Bool)
    private(set) var screenRecordingAllowed = false
    private(set) var accessibilityAllowed = false
    enum Step { case permissions, commandLine, guide }
    private(set) var step: Step = .permissions
    var isShowingGuide: Bool { step == .guide }
    private var continuedWithoutAccessibility = false
    var needsSetup: Bool { !isComplete() }

    init(isComplete: @escaping () -> Bool, rememberCompletion: @escaping () -> Void,
         readAccess: @escaping () -> (screen: Bool, accessibility: Bool)) {
        self.isComplete = isComplete
        self.rememberCompletion = rememberCompletion
        self.readAccess = readAccess
        refresh()
    }

    func refresh() {
        let access = readAccess()
        screenRecordingAllowed = access.screen
        accessibilityAllowed = access.accessibility
        if !access.screen || (!access.accessibility && !continuedWithoutAccessibility) { step = .permissions }
    }

    func continueToCLI(withoutAccessibility: Bool = false) {
        refresh()
        guard screenRecordingAllowed, accessibilityAllowed || withoutAccessibility || continuedWithoutAccessibility else { return }
        continuedWithoutAccessibility = !accessibilityAllowed && (withoutAccessibility || continuedWithoutAccessibility)
        step = .commandLine
    }

    func continueToGuide(withoutAccessibility: Bool = false) {
        refresh()
        guard screenRecordingAllowed, accessibilityAllowed || withoutAccessibility || continuedWithoutAccessibility else { return }
        continuedWithoutAccessibility = !accessibilityAllowed && (withoutAccessibility || continuedWithoutAccessibility)
        step = .guide
    }

    func returnToChecklist() {
        step = .permissions
        continuedWithoutAccessibility = false
    }

    func finish(dismiss: () -> Void, capture: (() -> Void)? = nil) {
        refresh()
        guard needsSetup, isShowingGuide, screenRecordingAllowed else { return }
        rememberCompletion()
        dismiss()
        capture?()
    }

    func dismissIncomplete(quit: () -> Void) {
        guard needsSetup else { return }
        refresh()
        returnToChecklist()
        if !screenRecordingAllowed { quit() }
    }
}
