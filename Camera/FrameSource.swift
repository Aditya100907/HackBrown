//
//  FrameSource.swift
//  HackBrown
//
//  Frame source abstraction: unified interface for live camera and video file inputs.
//  Downstream perception code depends only on this protocol.
//

import Foundation
import AVFoundation
import CoreVideo
import Combine

// MARK: - Frame Data

/// A single frame from any source (live camera or video file)
struct Frame {
    /// The pixel buffer containing image data
    let pixelBuffer: CVPixelBuffer
    
    /// Presentation timestamp
    let timestamp: CMTime
    
    /// Frame dimensions
    var width: Int {
        CVPixelBufferGetWidth(pixelBuffer)
    }
    
    var height: Int {
        CVPixelBufferGetHeight(pixelBuffer)
    }
}

// MARK: - Frame Source Protocol

/// Protocol for any frame source (live camera or video file).
/// Downstream code must depend only on this protocol so that
/// live and video-file inputs are interchangeable for testing/demos.
protocol FrameSource: AnyObject {
    /// Publisher that emits frames. Subscribe to receive frames at the source's native rate.
    var framePublisher: AnyPublisher<Frame, Never> { get }
    
    /// Whether the source is currently running
    var isRunning: Bool { get }
    
    /// Start emitting frames
    func start()
    
    /// Stop emitting frames
    func stop()
}

// MARK: - Camera Position

/// Which physical camera to use for live capture
enum CameraPosition {
    case front  // TrueDepth / selfie camera (driver monitoring)
    case back   // Rear camera (road monitoring, dashcam style)
    
    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}
