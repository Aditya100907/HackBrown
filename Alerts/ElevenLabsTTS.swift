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
    
    /// Voice ID — Arnold (crisp, authoritative, distinctly ElevenLabs; avoids iOS TTS soundalike)
    static var voiceId: String = "VR6AewLTigWG4xSOukaG"  // Arnold
    
    /// Model ID
    static var modelId: String = "eleven_monolingual_v1"
    
    /// API endpoint
    static let apiEndpoint = URL(string: "https://api.elevenlabs.io/v1/text-to-speech")!

    /// Whether API key is configured
    static var isConfigured: Bool {
        !apiKey.isEmpty
    }
    
    /// Load API key from Info.plist (key: ELEVENLABS_API_KEY)
    /// Call this at app launch to configure ElevenLabs
    static func loadApiKeyFromBundle() -> String {
        Bundle.main.object(forInfoDictionaryKey: "ELEVENLABS_API_KEY") as? String ?? ""
    }
}

// MARK: - TTS Provider Protocol

/// Protocol for TTS providers
protocol TTSProvider {
    /// Whether the provider is ready
    var isReady: Bool { get }
    
    /// Speak a phrase (may play from cache or generate)
    func speak(_ phrase: String, alertType: AlertType) async -> Bool
    
    /// Pre-cache all alert phrases
    func preCacheAllPhrases() async
    
    /// Check if a phrase is cached
    func isCached(_ alertType: AlertType) -> Bool
}

// MARK: - ElevenLabs TTS

/// ElevenLabs TTS implementation with local caching
final class ElevenLabsTTS: TTSProvider {
    
    // MARK: - Properties
    
    private var audioPlayer: AVAudioPlayer?
    private let cacheDirectory: URL
    private var cachedFiles: Set<String> = []
    
    var isReady: Bool {
        ElevenLabsConfig.isConfigured
    }
    
    // MARK: - Initialization
    
    init() {
        // Cache dir includes voiceId so changing voice invalidates old cached files
        let cachePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = cachePath.appendingPathComponent("ElevenLabsAudio", isDirectory: true)
            .appendingPathComponent(ElevenLabsConfig.voiceId, isDirectory: true)
        
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Load list of cached files
        loadCachedFilesList()
        
        // Configure audio session
        configureAudioSession()
    }
    
    // MARK: - TTSProvider Methods
    
    func speak(_ phrase: String, alertType: AlertType) async -> Bool {
        // Try to play from cache first
        if let cachedURL = getCachedURL(for: alertType), FileManager.default.fileExists(atPath: cachedURL.path) {
            return await playAudio(from: cachedURL)
        }
        
        // Generate and cache if not available
        guard isReady else {
            print("[ElevenLabsTTS] Not configured, cannot generate audio")
            return false
        }
        
        // Generate audio
        guard let audioData = await generateAudio(for: phrase) else {
            return false
        }
        
        // Cache for future use
        let cacheURL = getCachedURL(for: alertType)!
        do {
            try audioData.write(to: cacheURL)
            cachedFiles.insert(alertType.rawValue)
            print("[ElevenLabsTTS] Cached audio for: \(alertType.rawValue)")
        } catch {
            print("[ElevenLabsTTS] Failed to cache audio: \(error)")
        }
        
        // Play the generated audio
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
                // Small delay to avoid rate limiting
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }
        }
        
        print("[ElevenLabsTTS] Pre-caching complete")
    }
    
    func isCached(_ alertType: AlertType) -> Bool {
        cachedFiles.contains(alertType.rawValue)
    }
    
    // MARK: - Private Methods
    
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
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            cachedFiles.insert(name)
        }
        
        print("[ElevenLabsTTS] Found \(cachedFiles.count) cached audio files")
    }
    
    private func getCachedURL(for alertType: AlertType) -> URL? {
        cacheDirectory.appendingPathComponent("\(alertType.rawValue).mp3")
    }
    
    private func generateAudio(for text: String) async -> Data? {
        let urlString = "\(ElevenLabsConfig.apiEndpoint)/\(ElevenLabsConfig.voiceId)"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ElevenLabsConfig.apiKey, forHTTPHeaderField: "xi-api-key")
        
        let body: [String: Any] = [
            "text": text,
            "model_id": ElevenLabsConfig.modelId,
            "voice_settings": [
                "stability": 0.75,
                "similarity_boost": 0.75,
                "style": 0.5,
                "use_speaker_boost": true
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[ElevenLabsTTS] API error: \(response)")
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
