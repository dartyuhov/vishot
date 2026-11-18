import AVFoundation
import VishotConfiguration

/// Media-queue owned, timestamp-indexed PCM mixer. Each source retains at most
/// two seconds of PCM (plus a bounded packet index). Missing/expired packets are silence; late packets
/// never move the output cursor. Output is 48k mono with fixed 0.5/source gain
/// for two sources (unity for one), clamped before Int16 quantization.
/// Each source owns a bandlimited AVAudioConverter across contiguous packets.
/// Converted frame counts advance within a timestamp-anchored segment; gaps and
/// format changes flush/reset that segment, never concatenate elapsed silence.
final class RecordingAudioMixer {
    private struct Packet {
        let start: Double
        let rate: Double
        let values: [Float]
        var end: Double { start + Double(values.count) / rate }
    }
    private var packets: [String: [Packet]] = [:]
    private var latest: [String: Double] = [:]
    private final class Conversion {
        let converter: AVAudioConverter
        let start: Double
        var end: Double
        var frames: Int64 = 0
        init(format: AVAudioFormat, output: AVAudioFormat, start: Double) throws {
            guard let converter = AVAudioConverter(from: format, to: output) else {
                throw SettingsError(message: "Audio source PCM conversion is unavailable.")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.primeMethod = .normal
            self.converter = converter
            self.start = start
            end = start
        }
    }
    private var conversions: [String: Conversion] = [:]
    private let conversionFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let sourceCount: Int
    private let gain: Float
    private(set) var position: Int64 = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!

    init(sourceCount: Int) {
        self.sourceCount = max(1, sourceCount)
        gain = sourceCount > 1 ? 0.5 : 1
    }
    var deliveryWatermark: CMTime? {
        guard latest.count == sourceCount, let time = latest.values.min() else { return nil }
        return CMTime(seconds: time - 0.25, preferredTimescale: 48_000)
    }
    func discardPending() { packets.removeAll(); conversions.removeAll() }

    func finishSources() throws {
        for (source, conversion) in conversions { try convert(nil, source: source, state: conversion, finishing: true) }
        conversions.removeAll()
    }

    func prepareOutput(until endpoint: Double) throws -> Double {
        var safe = endpoint
        for (source, state) in Array(conversions) {
            let convertedEnd = state.start + Double(state.frames) / 48_000
            guard convertedEnd < state.end - 1.0 / 48_000 else { continue }
            if state.end <= endpoint {
                try convert(nil, source: source, state: state, finishing: true)
                conversions[source] = nil
            } else {
                // Converter-internal trailing input is not source silence.
                safe = min(safe, convertedEnd)
            }
        }
        return safe
    }

    func receive(_ sample: CMSampleBuffer, source: String, origin: CMTime) throws {
        guard sample.isValid, sample.presentationTimeStamp.isNumeric,
              let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              (8000...192000).contains(asbd.mSampleRate),
              (1...8).contains(asbd.mChannelsPerFrame), sample.numSamples > 0,
              Double(sample.numSamples) / asbd.mSampleRate <= 0.25 else {
            throw SettingsError(message: "Audio source format could not be converted to recording PCM.")
        }
        let start = (sample.presentationTimeStamp - origin).seconds
        let end = start + Double(sample.numSamples) / asbd.mSampleRate
        guard end > Double(position) / 48_000 else { return }
        if let latest = latest[source], start < latest - 0.0001 { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        if let previous = conversions[source], start < previous.end - 0.0001 { return }
        if let previous = conversions[source],
           previous.converter.inputFormat != inputFormat || abs(start - previous.end) > 0.5 / asbd.mSampleRate {
            try convert(nil, source: source, state: previous, finishing: true)
            conversions[source] = nil
        }
        let state = try conversions[source] ?? Conversion(format: inputFormat, output: conversionFormat, start: start)
        guard start >= state.end - 0.0001 else { return }
        conversions[source] = state
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            throw SettingsError(message: "Could not allocate recording PCM.")
        }
        input.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList) == noErr else {
            throw SettingsError(message: "Could not read recording audio.")
        }
        state.end = end
        try convert(input, source: source, state: state, finishing: false)
        latest[source] = start
    }

    private func convert(_ input: AVAudioPCMBuffer?, source: String, state: Conversion, finishing: Bool) throws {
        var supplied = false
        // A packet is at most 250ms. Capacity includes the converter's bounded
        // filter tail; .noDataNow preserves state between callbacks, while EOS
        // flushes only when a segment really ends (gap, format change or Stop).
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: conversionFormat, frameCapacity: 16_384) else {
                throw SettingsError(message: "Could not allocate resampled PCM.")
            }
            var error: NSError?
            let status = state.converter.convert(to: output, error: &error) { _, flag in
                if let input, !supplied { supplied = true; flag.pointee = .haveData; return input }
                flag.pointee = finishing ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error || error != nil { throw error ?? SettingsError(message: "Recording audio resampling failed.") }
            if let data = output.floatChannelData?[0], output.frameLength > 0 {
                let stamp = state.start + Double(state.frames) / 48_000
                let count = min(Int(output.frameLength), max(0, Int((state.end - stamp) * 48_000 + 0.5)))
                if count > 0 {
                    try retain(Packet(start: stamp, rate: 48_000,
                        values: Array(UnsafeBufferPointer(start: data, count: count))), source: source)
                }
                state.frames += Int64(output.frameLength)
            }
            if status == .inputRanDry || status == .endOfStream || output.frameLength == 0 { return }
        }
        throw SettingsError(message: "Recording audio converter exceeded its bounded work budget.")
    }

    private func retain(_ packet: Packet, source: String) throws {
        var queue = packets[source] ?? []
        guard queue.count < 4096,
              queue.reduce(0.0, { $0 + Double($1.values.count) / $1.rate }) + Double(packet.values.count) / packet.rate <= 2.00001 else {
            throw SettingsError(message: "Recording audio buffering overflowed before encoding; the playable portion was retained.")
        }
        queue.append(packet)
        packets[source] = queue
    }

    func sample(count: Int) throws -> CMSampleBuffer {
        var values = [Int16](repeating: 0, count: count)
        for index in values.indices {
            let time = Double(position + Int64(index)) / 48_000
            var value: Float = 0
            for queue in packets.values {
                guard let packet = queue.first(where: { time >= $0.start - 0.0000001 && time < $0.end }) else { continue }
                let offset = min(packet.values.count - 1, max(0, Int(((time - packet.start) * 48_000).rounded())))
                let converted = packet.values[offset]
                if converted.isFinite { value += converted * gain }
            }
            values[index] = Int16((max(-1, min(1, value)) * 32767).rounded())
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == noErr,
            let block else { throw SettingsError(message: "Could not allocate mixed PCM.") }
        let copied = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: position, timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 2
        var result: CMSampleBuffer?
        guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format.formatDescription, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &result) == noErr, let result else {
            throw SettingsError(message: "Could not create mixed PCM.")
        }
        return result
    }

    func advance(_ count: Int) {
        position += Int64(count)
        let time = Double(position) / 48_000
        for source in Array(packets.keys) { packets[source]?.removeAll { $0.end <= time } }
    }
}
