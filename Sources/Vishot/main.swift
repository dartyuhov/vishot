import AppKit
import VishotAgent

// Local-file commands exit before creating NSApplication, delegates, hotkeys, or permission UI.
if CommandLine.arguments.dropFirst().first == AgentAnnotationArguments.renderArgument {
    exit(AnnotationCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
