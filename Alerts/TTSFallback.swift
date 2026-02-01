//
//  TTSFallback.swift
//  HackBrown
//
//  iOS AVSpeechSynthesizer fallback when ElevenLabs is unavailable.
//  Provides immediate, on-device TTS without network dependency.
//

import Foundation
import AVFoundation

// MARK: - iOS TTS Fallback

/// iOS native TTS using AVSpeechSynthesizer
/// Uses @unchecked Sendable — synthesizer is used from async speak(); delegate callbacks run on main.
final class TTSFallback: NSObject, TTSProvider, @unchecked Sendable {
    
    // MARK: - Properties
    
    private let synthesizer = AVSpeechSynthesizer()
    private var isSpeaking = false
    
    var isReady: Bool {
        true  // Always ready (on-device)
    }
    
    // MARK: - Configuration
    
    /// Preferred voice names (in order) — avoid default Siri-like Samantha
    private static let preferredVoiceNames = ["Alex", "Daniel", "Fred", "Oliver"]
    
    /// Speaking rate (0.0 - 1.0, default ~0.5)
    private let speakingRate: Float = 0.52
    
    /// Pitch multiplier (0.5 - 2.0, default 1.0)
    private let pitchMultiplier: Float = 1.0
    
    /// Volume (0.0 - 1.0)
    private let volume: Float = 1.0
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }
    
    // MARK: - TTSProvider Methods
    
    func speak(_ phrase: String, alertType: AlertType) async -> Bool {
        // Stop any current speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: phrase)
        
        // Prefer distinct voices (Alex, Daniel, etc.) over default Siri-like Samantha
        utterance.voice = Self.selectPreferredVoice() ?? AVSpeechSynthesisVoice(language: "en-US")
        
        utterance.rate = speakingRate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = volume
        
        // Pre-speak pause (gives audio system time to activate)
        utterance.preUtteranceDelay = 0.1
        utterance.postUtteranceDelay = 0.1
        
        isSpeaking = true
        synthesizer.speak(utterance)
        
        // Wait for completion
        while isSpeaking {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
        
        return true
    }
    
    func preCacheAllPhrases() async {
        // iOS TTS doesn't need pre-caching
        print("[TTSFallback] iOS TTS ready (no pre-caching needed)")
    }
    
    func isCached(_ alertType: AlertType) -> Bool {
        // iOS TTS is always "cached" (on-device)
        true
    }
    
    // MARK: - Private Methods
    
    private static func selectPreferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        for name in preferredVoiceNames {
            if let voice = voices.first(where: {
                $0.name.range(of: name, options: .caseInsensitive) != nil && $0.language.hasPrefix("en")
            }) {
                print("[TTSFallback] Using voice: \(voice.name) (\(voice.language))")
                return voice
            }
        }
        let fallback = AVSpeechSynthesisVoice(language: "en-US")
        print("[TTSFallback] Using default en-US voice: \(fallback?.name ?? "nil")")
        return fallback
    }
    
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            print("[TTSFallback] Audio session error: \(error)")
        }
    }
    
    /// Stop any current speech
    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSFallback: AVSpeechSynthesizerDelegate {
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
}

// MARK: - Combined TTS Manager

/// Manages TTS with ElevenLabs primary and iOS fallback
final class TTSManager {
    
    private let elevenLabs: ElevenLabsTTS
    private let fallback: TTSFallback
    
    /// Whether to prefer ElevenLabs (set to false to always use iOS TTS)
    var preferElevenLabs: Bool = true
    
    /// Whether ElevenLabs is available
    var elevenLabsAvailable: Bool {
        elevenLabs.isReady
    }
    
    init() {
        elevenLabs = ElevenLabsTTS()
        fallback = TTSFallback()
    }
    
    /// Speak an alert, using ElevenLabs if available, otherwise fallback
    /// - Parameters:
    ///   - alertType: The type of alert (for caching/priority)
    ///   - customPhrase: Optional custom phrase to speak (overrides alertType.phrase)
    func speak(_ alertType: AlertType, customPhrase: String? = nil) async {
        let phrase = customPhrase ?? alertType.phrase
        
        if preferElevenLabs && elevenLabs.isReady {
            let success = await elevenLabs.speak(phrase, alertType: alertType)
            if success {
                return
            }
            print("[TTSManager] ElevenLabs failed, falling back to iOS TTS")
        }
        
        _ = await fallback.speak(phrase, alertType: alertType)
    }
    
    /// Pre-cache all phrases with ElevenLabs
    func preCacheAllPhrases() async {
        await elevenLabs.preCacheAllPhrases()
    }
    
    /// Check if a phrase is cached in ElevenLabs
    func isCached(_ alertType: AlertType) -> Bool {
        elevenLabs.isCached(alertType)
    }
    
    /// Stop any current speech
    func stopSpeaking() {
        fallback.stopSpeaking()
    }
}
