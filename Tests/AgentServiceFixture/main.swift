import AppKit
import VishotAgent
import ImageIO
import UniformTypeIdentifiers

// A real Launch Services app substitute; no permission, capture, or UI APIs.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var server: AgentServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = Bundle.main.bundleURL
        try? Data(String(getpid()).utf8).write(to: app.appendingPathComponent("fixture.pid"))
        guard Bundle.main.object(forInfoDictionaryKey: "FixtureMode") as? String == "ready" else { return }
        do {
            server = try AgentServer(endpoint: AgentEndpoint(appURL: app)) { request in
                guard CommandLine.arguments.contains(AgentEndpoint.backgroundArgument) else {
                    throw AgentFailure(.serviceFailure, "The CLI did not pass its background launch intent.")
                }
                if request.command == "capture", let id = request.windowID {
                    let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    let data = NSMutableData()
                    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
                    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                    guard CGImageDestinationFinalize(destination) else { throw AgentFailure(.encodingFailed, "Fixture encoding failed") }
                    return .captured(AgentCapturedImage(target: AgentWindow(id: id,
                        app: AgentApp(pid: getpid(), bundleID: nil, name: "Fixture"), title: "Background capture",
                        bounds: AgentBounds(x: 0, y: 0, width: 3, height: 2)), png: data as Data, width: 3, height: 2))
                }
                return .windows([AgentWindow(id: 77, app: AgentApp(pid: getpid(), bundleID: nil, name: "Fixture"),
                    title: "Background launch confirmed", bounds: AgentBounds(x: 0, y: 0, width: 200, height: 200))])
            }
            try server?.start()
        } catch { exit(1) }
    }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
