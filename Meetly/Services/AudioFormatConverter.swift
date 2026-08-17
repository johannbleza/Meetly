import AVFoundation
import Foundation

enum AudioFormatConverter {
    static func rmsEnergy(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        return sqrt(sum / Float(frameLength * channelCount))
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        guard let sourceData = buffer.floatChannelData,
              let destData = copy.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        for channel in 0..<channelCount {
            destData[channel].update(from: sourceData[channel], count: frameLength)
        }
        return copy
    }

    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.format != format else { return buffer }

        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if error != nil { return nil }
        return output
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        guard let sourceFormat = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        return convert(sourceBuffer, to: targetFormat)
    }

    static func rmsEnergy(ofPCM16 data: Data) -> Float {
        guard data.count >= 2 else { return 0 }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        var sum: Float = 0
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                let normalized = Float(samples[index]) / Float(Int16.max)
                sum += normalized * normalized
            }
        }
        return sqrt(sum / Float(sampleCount))
    }

    static func pcm16ToWav(_ pcmData: Data, sampleRate: Int, channels: Int) -> Data {
        let byteRate = sampleRate * channels * MemoryLayout<Int16>.size
        let blockAlign = channels * MemoryLayout<Int16>.size
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndianUInt32(UInt32(36 + pcmData.count)))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndianUInt32(16))
        header.append(littleEndianUInt16(1)) // PCM
        header.append(littleEndianUInt16(UInt16(channels)))
        header.append(littleEndianUInt32(UInt32(sampleRate)))
        header.append(littleEndianUInt32(UInt32(byteRate)))
        header.append(littleEndianUInt16(UInt16(blockAlign)))
        header.append(littleEndianUInt16(16)) // bits per sample
        header.append(contentsOf: "data".utf8)
        header.append(littleEndianUInt32(UInt32(pcmData.count)))
        var wav = header
        wav.append(pcmData)
        return wav
    }

    private static func littleEndianUInt16(_ value: UInt16) -> Data {
        var value = value.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }

    private static func littleEndianUInt32(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
