//
//  VoicePreviewPlayer+Publik.swift
//  leanring-buddy
//
//  The app's voice previews: the same publik realtime voice Teachy speaks with.
//

import Foundation

extension VoicePreviewPlayer {
    static let shared = VoicePreviewPlayer { text, voice, speed in
        try await RealtimeVoice.renderSample(text: text, voice: voice, speed: speed)
    }
}
