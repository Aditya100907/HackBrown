//
//  ThirdEyeApp.swift
//  ThirdEye
//
//  Main app entry point for the driving assistant prototype.
//

import SwiftUI

@main
struct ThirdEyeApp: App {
    
    init() {
        // Load ElevenLabs API key from Info.plist at app launch
        ElevenLabsConfig.apiKey = ElevenLabsConfig.loadApiKeyFromBundle()
        
        if ElevenLabsConfig.isConfigured {
            print("[ThirdEyeApp] ElevenLabs API key loaded successfully")
        } else {
            print("[ThirdEyeApp] ElevenLabs API key not configured - using iOS TTS fallback")
            print("[ThirdEyeApp] To enable ElevenLabs, add your API key to Info.plist under ELEVENLABS_API_KEY")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
