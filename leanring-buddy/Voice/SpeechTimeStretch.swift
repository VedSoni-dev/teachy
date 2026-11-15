//
//  SpeechTimeStretch.swift
//  leanring-buddy
//
//  Makes recorded speech faster or slower without changing its pitch, off-line
//  (`AVAudioUnitTimePitch` in an engine that renders to memory instead of to the
//  speakers). Used for the voice picker's samples, so a preview is at the chosen
//  speed. Live speech uses the same audio unit inside the playback chain
//  (see `RealtimeVoice`).
//

import AVFoundation
import Foundation

nonisolated enum SpeechTimeStretch {
    /// 16-bit mono PCM in, 16-bit mono PCM out, `rate` times as fast (0.5…1.5).
    /// Returns the input unchanged if the rate is 1 or anything fails.
    static func stretch(pcm16: Data, sampleRate: Double, rate: Float) -> Data {
        let sampleCount = pcm16.count / 2
        guard sampleCount > 0, abs(rate - 1) > 0.02, rate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let inputChannel = input.floatChannelData?[0]
        else { return pcm16 }

        input.frameLength = AVAudioFrameCount(sampleCount)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<sampleCount { inputChannel[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0 }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = min(max(rate, 0.5), 1.5)
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let chunk: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
            try engine.start()
        } catch {
            return pcm16
        }
        defer { engine.stop() }
        player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
        player.play()

        guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else { return pcm16 }
        let expectedFrames = Int((Double(sampleCount) / Double(timePitch.rate)).rounded())
        var output = Data(capacity: expectedFrames * 2)
        var framesWritten = 0
        while framesWritten < expectedFrames {
            let wanted = min(chunk, AVAudioFrameCount(expectedFrames - framesWritten))
            guard let status = try? engine.renderOffline(wanted, to: rendered), status == .success,
                  let channel = rendered.floatChannelData?[0], rendered.frameLength > 0
            else { break }
            for index in 0..<Int(rendered.frameLength) {
                let clamped = max(-1, min(1, channel[index]))
                var sample = Int16(clamped * 32_767).littleEndian
                withUnsafeBytes(of: &sample) { output.append(contentsOf: $0) }
            }
            framesWritten += Int(rendered.frameLength)
        }
        return output.isEmpty ? pcm16 : output
    }
}
