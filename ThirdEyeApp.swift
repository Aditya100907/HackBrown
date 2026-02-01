//
//  ThirdEyeApp.swift
//  ThirdEye
//
//  Main app entry point for the driving assistant prototype.
//

import SwiftUI
import SmartSpectraSwiftSDK

@main
struct ThirdEyeApp: App {
    
    init() {
        // Load ElevenLabs API key from Info.plist at app launch
        ElevenLabsConfig.apiKey = ElevenLabsConfig.loadApiKeyFromBundle()
        
        if ElevenLabsConfig.isConfigured {
            print("[ThirdEyeApp] ElevenLabs API key loaded successfully")
        } else {
            print("[ThirdEyeApp] ElevenLabs API key not configured - using iOS TTS fallback")
            print("[ThirdEyeApp] To enable ElevenLabs, copy .env.example to .env and add ELEVENLABS_API_KEY=your_key")
        }
        
        // Initialize SmartSpectra SDK
        let sdk = SmartSpectraSwiftSDK.shared
        sdk.setApiKey(Secrets.presageApiKey)
        sdk.setSmartSpectraMode(.continuous)
        sdk.setCameraPosition(.front)
        print("[ThirdEyeApp] SmartSpectra SDK initialized")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
