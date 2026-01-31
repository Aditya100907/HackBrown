//
//  PresageIntegration.swift
//  HackBrown
//
//  Presage SDK integration for driver attention/fatigue signals.
//  Consumes only 1-2 simple outputs. No long-term baselining, personalization, or backend.
//  Presage augments Vision signals, it does not replace them.
//

import Foundation
import CoreVideo

// MARK: - Presage Output (Simplified)

/// Simplified output from Presage SDK
/// We only consume 1-2 signals as per spec
struct PresageOutput {
    /// Attention score (0-1, higher = more attentive)
    let attentionScore: Float
    
    /// Fatigue/drowsiness indicator (0-1, higher = more fatigued)
    let fatigueScore: Float
    
    /// Timestamp of measurement
    let timestamp: Date
    
    /// Whether the reading is valid
    let isValid: Bool
}

// MARK: - Presage Provider Protocol

/// Protocol for Presage SDK integration
/// Allows swapping between real SDK and mock implementation
protocol PresageProvider {
    /// Whether Presage is initialized and ready
    var isReady: Bool { get }
    
    /// Start Presage session
    func start()
    
    /// Stop Presage session
    func stop()
    
    /// Process a frame and get attention/fatigue output
    /// - Parameter pixelBuffer: Front camera frame
    /// - Returns: Presage output with attention and fatigue scores
    func processFrame(_ pixelBuffer: CVPixelBuffer) -> PresageOutput
}

// MARK: - Mock Presage Implementation

/// Mock implementation of Presage for testing/development
/// Replace with real Presage SDK integration when available
final class MockPresageProvider: PresageProvider {
    
    private(set) var isReady: Bool = false
    
    /// Simulated attention baseline (varies slightly to simulate real behavior)
    private var baselineAttention: Float = 0.85
    
    /// Simulated fatigue level (gradually increases to simulate time-on-task)
    private var simulatedFatigue: Float = 0.1
    
    /// Session start time
    private var sessionStart: Date?
    
    func start() {
        isReady = true
        sessionStart = Date()
        simulatedFatigue = 0.1
        print("[MockPresage] Session started")
    }
    
    func stop() {
        isReady = false
        sessionStart = nil
        print("[MockPresage] Session stopped")
    }
    
    func processFrame(_ pixelBuffer: CVPixelBuffer) -> PresageOutput {
        guard isReady else {
            return PresageOutput(
                attentionScore: 0,
                fatigueScore: 0,
                timestamp: Date(),
                isValid: false
            )
        }
        
        // Simulate slight variation in attention
        let attentionNoise = Float.random(in: -0.05...0.05)
        let attention = min(1.0, max(0.0, baselineAttention + attentionNoise))
        
        // Gradually increase fatigue over time (simulates real driving fatigue)
        if let start = sessionStart {
            let elapsed = Date().timeIntervalSince(start)
            // Increase fatigue by 0.01 per minute, cap at 0.7
            simulatedFatigue = min(0.7, 0.1 + Float(elapsed / 60.0) * 0.01)
        }
        
        return PresageOutput(
            attentionScore: attention,
            fatigueScore: simulatedFatigue,
            timestamp: Date(),
            isValid: true
        )
    }
}

// MARK: - Real Presage Integration (Placeholder)

/// Real Presage SDK integration
/// TODO: Replace with actual Presage SDK calls when SDK is integrated
final class RealPresageProvider: PresageProvider {
    
    private(set) var isReady: Bool = false
    
    func start() {
        // TODO: Initialize Presage SDK
        // Example:
        // PresageSDK.shared.initialize(apiKey: "your-api-key")
        // PresageSDK.shared.startSession()
        
        isReady = true
        print("[RealPresage] Session started - TODO: Implement real SDK integration")
    }
    
    func stop() {
        // TODO: Stop Presage SDK session
        // Example:
        // PresageSDK.shared.stopSession()
        
        isReady = false
        print("[RealPresage] Session stopped")
    }
    
    func processFrame(_ pixelBuffer: CVPixelBuffer) -> PresageOutput {
        // TODO: Pass frame to Presage SDK and get results
        // Example:
        // let result = PresageSDK.shared.analyze(frame: pixelBuffer)
        // return PresageOutput(
        //     attentionScore: result.attention,
        //     fatigueScore: result.fatigue,
        //     timestamp: Date(),
        //     isValid: result.isValid
        // )
        
        // Fallback to mock for now
        return PresageOutput(
            attentionScore: 0.8,
            fatigueScore: 0.2,
            timestamp: Date(),
            isValid: true
        )
    }
}

// MARK: - Presage Integration Manager

/// Manager that handles Presage provider selection and thresholds
final class PresageIntegration {
    
    // MARK: - Configuration
    
    /// Attention score below this triggers a warning
    let lowAttentionThreshold: Float = 0.5
    
    /// Fatigue score above this triggers a warning
    let highFatigueThreshold: Float = 0.6
    
    // MARK: - Properties
    
    private let provider: PresageProvider
    
    var isReady: Bool {
        provider.isReady
    }
    
    // MARK: - Initialization
    
    /// Initialize with optional custom provider
    /// - Parameter provider: Custom provider (defaults to mock for hackathon)
    init(provider: PresageProvider? = nil) {
        // Use mock provider for hackathon demo
        // Switch to RealPresageProvider when SDK is integrated
        self.provider = provider ?? MockPresageProvider()
    }
    
    // MARK: - Session Control
    
    func start() {
        provider.start()
    }
    
    func stop() {
        provider.stop()
    }
    
    // MARK: - Analysis
    
    /// Process a frame and check for attention/fatigue issues
    /// - Parameter pixelBuffer: Front camera frame
    /// - Returns: Presage output
    func processFrame(_ pixelBuffer: CVPixelBuffer) -> PresageOutput {
        provider.processFrame(pixelBuffer)
    }
    
    /// Check if output indicates low attention
    func hasLowAttention(_ output: PresageOutput) -> Bool {
        output.isValid && output.attentionScore < lowAttentionThreshold
    }
    
    /// Check if output indicates high fatigue
    func hasHighFatigue(_ output: PresageOutput) -> Bool {
        output.isValid && output.fatigueScore > highFatigueThreshold
    }
}
