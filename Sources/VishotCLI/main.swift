import Foundation
import MachO
import VishotCLIExecution

private func executableURL() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
}

// Keep the main run loop available for Launch Services without activating a CLI app.
DispatchQueue.global(qos: .userInitiated).async {
    let result = CLIExecution.execute(Array(CommandLine.arguments.dropFirst()), executableURL: executableURL)
    do { try FileHandle.standardOutput.write(contentsOf: result.output) }
    catch { exit(CLIResult.outputFailureStatus) }
    exit(result.exitStatus)
}
dispatchMain()
