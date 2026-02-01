//
//  WarningSoundPlayer.swift
//  ThirdEye
//
//  Low-latency warning feedback using haptics + audio alerts.
//

import AVFoundation
import UIKit
import AudioToolbox

class WarningSoundPlayer {
    static let shared = WarningSoundPlayer()
    
    private init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("[WarningSoundPlayer] Audio session configured")
        } catch {
            print("[WarningSoundPlayer] Failed to configure audio session: \(error)")
        }
    }
    
    /// Play warning sound immediately
    /// - Parameter critical: If true, plays a more urgent sound pattern
    func playWarningSound(critical: Bool = false) {
        print("[WarningSoundPlayer] Playing warning sound - critical: \(critical)")
        
        // Haptic feedback (guaranteed to work on device)
        let feedback = UIImpactFeedbackGenerator(style: critical ? .heavy : .medium)
        feedback.impactOccurred()
        
        // Play alert tone
        if critical {
            playCriticalAlert()
        } else {
            playStandardAlert()
        }
    }
    
    private func playStandardAlert() {
        // Use system sound ID for alert
        AudioServicesPlaySystemSound(1016)  // Alarm/Alert sound
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AudioServicesPlaySystemSound(1016)
        }
    }
    
    private func playCriticalAlert() {
        // More urgent: 3 rapid alerts
        AudioServicesPlaySystemSound(1016)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AudioServicesPlaySystemSound(1016)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AudioServicesPlaySystemSound(1016)
        }
    }
}


