import XCTest
import VishotRendering
import VishotConfiguration
@testable import Vishot

final class RenderingIntegrationTests: XCTestCase {
    func testInterfaceAppearanceDoesNotRestyleScreenshotMarkup() throws {
        let image = try XCTUnwrap(CGContext(data: nil, width: 160, height: 160,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let annotations: [Annotation] = [.rect(CGRect(x: 12, y: 12, width: 40, height: 40), color: .red),
            .text("note", at: CGPoint(x: 20, y: 90), color: .purple)]
        for style in VisualStyle.allCases {
            let light = ThemeCatalog.resolve(style: style, colorScheme: .light)
            let dark = ThemeCatalog.resolve(style: style, colorScheme: .dark)
            // CLI annotation resolves this shared preference mapping without a GUI definition.
            let shared = AnnotationCatalog.annotation(style.annotationID)
            XCTAssertEqual(light.id, style.annotationID)
            XCTAssertEqual(dark.id, style.annotationID)
            let lightContext = try XCTUnwrap(AnnotationRenderer.imageSpaceContext(drawing: image, scale: 1))
            let darkContext = try XCTUnwrap(AnnotationRenderer.imageSpaceContext(drawing: image, scale: 1))
            let sharedContext = try XCTUnwrap(AnnotationRenderer.imageSpaceContext(drawing: image, scale: 1))
            AnnotationRenderer.draw(annotations, in: lightContext, style: light.annotation)
            AnnotationRenderer.draw(annotations, in: darkContext, style: dark.annotation)
            AnnotationRenderer.draw(annotations, in: sharedContext, style: shared)
            XCTAssertEqual(lightContext.makeImage()!.dataProvider!.data! as Data,
                           darkContext.makeImage()!.dataProvider!.data! as Data)
            XCTAssertEqual(lightContext.makeImage()!.dataProvider!.data! as Data,
                           sharedContext.makeImage()!.dataProvider!.data! as Data,
                           "GUI markup must match the CLI's shared selectable treatment")
            XCTAssertGreaterThan(light.hud.panel.background.usingColorSpace(.sRGB)!.redComponent, 0.9)
            XCTAssertLessThan(dark.hud.panel.background.usingColorSpace(.sRGB)!.redComponent, 0.2)
        }
    }
}
