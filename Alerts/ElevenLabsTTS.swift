//
//  ElevenLabsTTS.swift
//  HackBrown
//
//  ElevenLabs TTS integration. Generates audio for fixed phrases and caches locally.
//  Falls back to iOS TTS if ElevenLabs fails.
//

import Foundation
import AVFoundation

// MARK: - ElevenLabs Configuration

/// ElevenLabs API configuration
struct ElevenLabsConfig {
    /// API key (set this before using, or load from Info.plist)
    static var apiKey: String = ""
    
    /// Voice ID — George (warm, captivating British male)
    static var voiceId: String = "JBFqnCBsd6RMkjVDRZzb"
    
    /// Model ID
    static var modelId: String = "eleven_multilingual_v2"
    
    /// API endpoint
    static let apiEndpoint = "https://api.elevenlabs.io/v1/text-to-speech"

    /// Whether API key is configured
    static var isConfigured: Bool {
        !apiKey.isEmpty
    }
    
    /// Load API key from Info.plist (key: ELEVENLABS_API_KEY)
    static func loadApiKeyFromBundle() -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "ELEVENLABS_API_KEY") as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Voice Urgency

/// Urgency tier: low risk = calm/stable, high risk = urgent/variable
enum VoiceUrgency: String, CaseIterable {
    case calm
    case normal
    case urgent
    
    var stability: Float {
        switch self {
        case .calm: return 0.92
        case .normal: return 0.50
        case .urgent: return 0.12
        }
    }
    
    var similarityBoost: Float {
        switch self {
        case .calm: return 0.65
        case .normal: return 0.78
        case .urgent: return 0.92
        }
    }
    
    /// ElevenLabs speed (0.7–1.2). Urgent = faster delivery.
    var speed: Float {
        switch self {
        case .calm: return 0.92
        case .normal: return 1.0
        case .urgent: return 1.18
        }
    }
    
    static func from(priority: Int) -> VoiceUrgency {
        if priority >= 170 { return .urgent }
        if priority >= 100 { return .normal }
        return .calm
    }
}

// MARK: - TTS Provider Protocol

/// Protocol for TTS providers
protocol TTSProvider {
    var isReady: Bool { get }
    func speak(_ phrase: String, alertType: AlertType, effectivePriority: Int?) async -> Bool
    func preCacheAllPhrases() async
    func isCached(_ alertType: AlertType) -> Bool
}

// MARK: - ElevenLabs TTS

/// ElevenLabs TTS implementation with local caching
final class ElevenLabsTTS: TTSProvider {
    
    private var audioPlayer: AVAudioPlayer?
    private let cacheDirectory: URL
    private var cachedFiles: Set<String> = []
    
    var isReady: Bool {
        ElevenLabsConfig.isConfigured
    }
    
    init() {
        let cachePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = cachePath.appendingPathComponent("ElevenLabsAudio", isDirectory: true)
            .appendingPathComponent(ElevenLabsConfig.voiceId, isDirectory: true)
        
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadCachedFilesList()
        configureAudioSession()
    }
    
    func speak(_ phrase: String, alertType: AlertType, effectivePriority: Int? = nil) async -> Bool {
        let priority = effectivePriority ?? alertType.priority
        let urgency = VoiceUrgency.from(priority: priority)
        let cacheKey = "\(alertType.rawValue)_\(urgency.rawValue)"
        let cacheURL = cacheDirectory.appendingPathComponent("\(cacheKey).mp3")
        
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return await playAudio(from: cacheURL)
        }
        
        guard isReady else {
            print("[ElevenLabsTTS] Not configured, cannot generate audio")
            return false
        }
        
        guard let audioData = await generateAudio(for: phrase, urgency: urgency) else {
            return false
        }
        
        do {
            try audioData.write(to: cacheURL)
            cachedFiles.insert(cacheKey)
            print("[ElevenLabsTTS] Cached audio for: \(cacheKey)")
        } catch {
            print("[ElevenLabsTTS] Failed to cache: \(error)")
        }
        
        return await playAudio(data: audioData)
    }
    
    func preCacheAllPhrases() async {
        guard isReady else {
            print("[ElevenLabsTTS] Not configured, skipping pre-cache")
            return
        }
        
        print("[ElevenLabsTTS] Pre-caching all alert phrases...")
        for alertType in AlertType.allCases {
            if !isCached(alertType) {
                _ = await speak(alertType.phrase, alertType: alertType)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        print("[ElevenLabsTTS] Pre-caching complete")
    }
    
    func isCached(_ alertType: AlertType) -> Bool {
        let urgency = VoiceUrgency.from(priority: alertType.priority)
        return cachedFiles.contains("\(alertType.rawValue)_\(urgency.rawValue)")
    }
    
    // MARK: - Private
    
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            print("[ElevenLabsTTS] Audio session error: \(error)")
        }
    }
    
    private func loadCachedFilesList() {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path),
              let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "mp3" {
            cachedFiles.insert(file.deletingPathExtension().lastPathComponent)  // e.g. system_ready_calm
        }
        print("[ElevenLabsTTS] Found \(cachedFiles.count) cached audio files")
    }
    
    private func generateAudio(for text: String, urgency: VoiceUrgency = .normal) async -> Data? {
        guard let url = URL(string: "\(ElevenLabsConfig.apiEndpoint)/\(ElevenLabsConfig.voiceId)") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ElevenLabsConfig.apiKey, forHTTPHeaderField: "xi-api-key")
        
        let body: [String: Any] = [
            "text": text,
            "model_id": ElevenLabsConfig.modelId,
            "voice_settings": [
                "stability": urgency.stability,
                "similarity_boost": urgency.similarityBoost,
                "speed": urgency.speed
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[ElevenLabsTTS] Invalid response")
                return nil
            }
            
            if httpResponse.statusCode != 200 {
                if let errorBody = String(data: data, encoding: .utf8) {
                    print("[ElevenLabsTTS] API error \(httpResponse.statusCode): \(errorBody)")
                } else {
                    print("[ElevenLabsTTS] API error \(httpResponse.statusCode)")
                }
                return nil
            }
            
            return data
        } catch {
            print("[ElevenLabsTTS] Request error: \(error)")
            return nil
        }
    }
    
    private func playAudio(from url: URL) async -> Bool {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            return true
        } catch {
            print("[ElevenLabsTTS] Playback error: \(error)")
            return false
        }
    }
    
    private func playAudio(data: Data) async -> Bool {
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            return true
        } catch {
            print("[ElevenLabsTTS] Playback error: \(error)")
            return false
        }
    }
}
