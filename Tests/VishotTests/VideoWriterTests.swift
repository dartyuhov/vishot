import XCTest
import AVFoundation
import CoreImage
@testable import Vishot

@MainActor final class VideoWriterTests: XCTestCase {
    func testProductionWriterFinalizesImmediateRapidStaticTailAndDroppedGaps() async throws {
        for (times, stop) in [([0.0], 1.0 / 600), ([0.0], 1.0 / 30),
                              ([0.0, 1.0], 11.0), ([0.0, 0.5, 2.0], 12.0)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let rectangle = VideoRectangle(display: VideoDisplay(id: 1,
                frame: CGRect(x: 0, y: 0, width: 101, height: 55), scale: 1),
                rect: CGRect(x: 0, y: 0, width: 101, height: 55))
            let recorder = try await VideoRecorder.preparedWriter(rectangle: rectangle, directory: directory)
            let source = try buffer(width: 102, height: 56)
            let start = Task { try await recorder.start() }
            for time in times {
                let stamp = CMTime(seconds: 100 + time, preferredTimescale: 600)
                var accepted = false
                for _ in 0..<100 where !accepted {
                    accepted = await recorder.receiveFrame(source, at: stamp, host: stamp)
                    if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
                }
                XCTAssertTrue(accepted)
            }
            try await start.value
            let output = try await recorder.stop(at: CMTime(seconds: 100 + stop, preferredTimescale: 600))
            let asset = AVURLAsset(url: output.movie)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            XCTAssertEqual(duration, stop, accuracy: 1.0 / 30 + 0.00001)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let fps = try await track.load(.nominalFrameRate)
            print("Production synthetic MP4: input=\(times), stop=\(stop)s, duration=\(duration)s, nominalFrameRate=\(fps), canvas=102x56")
            XCTAssertLessThanOrEqual(fps, 30.001, "Ultra-short clips must not advertise hundreds of fps")
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertTrue(audio.isEmpty)
            try await VideoRecorder.validateMovie(at: output.movie, width: 102, height: 56)
            XCTAssertEqual(output.video.duration, duration)
            // Decode every presented sample, not just container metadata.
            let reader = try AVAssetReader(asset: asset)
            let decoded = AVAssetReaderTrackOutput(track: track, outputSettings:
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(decoded)
            XCTAssertTrue(reader.startReading())
            var stamps: [Double] = []
            while let sample = decoded.copyNextSampleBuffer() { stamps.append(CMTimeGetSeconds(sample.presentationTimeStamp)) }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(stamps.count, times.count)
            for (observed, expected) in zip(stamps, times) { XCTAssertEqual(observed, expected, accuracy: 0.002) }
        }
    }

    func testProductionIntakeRejectsLateAndNonmonotonicFramesAndCannotRestartAfterStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let recorder = try await VideoRecorder.preparedWriter(rectangle:
            VideoRectangle(display: VideoDisplay(id: 1, frame: rect, scale: 1), rect: rect), directory: directory)
        let source = try buffer(width: 16, height: 16)
        let first = CMTime(value: 100, timescale: 1)
        var accepted = false
        for _ in 0..<100 where !accepted {
            accepted = await recorder.receiveFrame(source, at: first, host: first)
            if !accepted { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(accepted)
        let duplicate = await recorder.receiveFrame(source, at: first, host: first)
        XCTAssertFalse(duplicate)
        let tooFast = await recorder.receiveFrame(source, at: first + CMTime(value: 1, timescale: 600), host: first)
        XCTAssertFalse(tooFast, "Intake must enforce at most 30fps independently of the OS request")
        recorder.closeIntake(at: first)
        let late = await recorder.receiveFrame(source, at: first + CMTime(value: 1, timescale: 1), host: first)
        XCTAssertFalse(late)
        _ = try await recorder.stop(at: first)
        do { try await recorder.start(); XCTFail("Finalized recorder must not restart") } catch {}
    }

    func testUnpaddedOddNativeImagePreservesLastEdgeAndAddsOpaqueBlackCanvas() throws {
        let canvas = try VideoCanvas(native: CGSize(width: 101, height: 55))
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 7, y: 9, width: 101, height: 55))
        let output = try buffer(width: 102, height: 56)
        CIContext().render(canvas.normalize(image), to: output,
            bounds: CGRect(x: 0, y: 0, width: 102, height: 56), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(output)
        for (x, y, red) in [(0, 0, 255), (100, 54, 255), (101, 54, 0), (100, 55, 0)] {
            // CI image coordinates are y-up; pixel buffer scanlines are top-down.
            let offset = (55 - y) * row + x * 4
            XCTAssertEqual(pixels[offset], 0)
            XCTAssertEqual(pixels[offset + 1], 0)
            XCTAssertEqual(pixels[offset + 2], UInt8(red))
            XCTAssertEqual(pixels[offset + 3], 255)
        }
    }

    private func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
