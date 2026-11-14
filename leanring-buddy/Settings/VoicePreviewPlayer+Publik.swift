//
//  VoicePreviewPlayer+Publik.swift
//  leanring-buddy
//
//  The app's voice previews: publik speech and nothing else.
//

import Foundation

extension VoicePreviewPlayer {
    static let shared = VoicePreviewPlayer { text, voice, speed in
        try await PublikAudio.speech(text: text, voice: voice, speed: speed)
    }
}
