//
//  SourceMode.swift
//  HackBrown
//
//  Enum representing the camera input mode selection.
//  Allows switching between live cameras and video file for testing/demos.
//

import Foundation

/// Input source mode for the app
enum SourceMode: String, CaseIterable, Identifiable {
    /// Live rear camera (dashcam position, facing road)
    case liveRear = "Live Rear Camera"
    
    /// Live front camera (facing driver)
    case liveFront = "Live Front Camera"
    
    /// Prerecorded video file (for testing/demos)
    case videoFile = "Video File"
    
    var id: String { rawValue }
    
    /// Description for UI display
    var description: String {
        switch self {
        case .liveRear:
            return "Road monitoring (dashcam view)"
        case .liveFront:
            return "Driver monitoring (selfie view)"
        case .videoFile:
            return "Playback from video file"
        }
    }
    
    /// SF Symbol icon name for UI
    var iconName: String {
        switch self {
        case .liveRear:
            return "car.fill"
        case .liveFront:
            return "person.fill"
        case .videoFile:
            return "film.fill"
        }
    }
    
    /// Whether this mode uses live camera
    var isLive: Bool {
        switch self {
        case .liveRear, .liveFront:
            return true
        case .videoFile:
            return false
        }
    }
    
    /// Camera position for live modes
    var cameraPosition: CameraPosition? {
        switch self {
        case .liveRear:
            return .back
        case .liveFront:
            return .front
        case .videoFile:
            return nil
        }
    }
}
