//
//  VideoManager.swift
//  HackBrown
//
//  Video discovery and loading utility for demo mode.
//  Scans bundle resources for video files and provides VideoFileFrameSource instances.
//

import Foundation
import AVFoundation

// MARK: - Demo Video Model

/// Represents a demo video file available in the app bundle
struct DemoVideo: Identifiable, Equatable {
    /// Unique identifier (filename)
    let id: String
    
    /// Display name (without extension)
    let name: String
    
    /// Full filename with extension
    let fileName: String
    
    /// File extension (.mov, .mp4, .m4v)
    let fileExtension: String
    
    /// URL to the video file
    let url: URL?
    
    /// Formatted display name for UI
    var displayName: String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
    
    /// File size in MB (if available)
    var fileSizeMB: Double? {
        guard let url = url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return nil
        }
        return Double(fileSize) / (1024 * 1024)
    }
}

// MARK: - Video Manager

/// Manages discovery and loading of demo videos from the app bundle
class VideoManager {
    
    /// Supported video file extensions
    static let supportedExtensions = ["mov", "mp4", "m4v"]
    
    // MARK: - Public Methods
    
    /// Scan the app bundle for all available video files
    /// - Returns: Array of DemoVideo objects, sorted alphabetically by display name
    static func scanBundleForVideos() -> [DemoVideo] {
        var videos: [DemoVideo] = []
        
        for ext in supportedExtensions {
            if let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) {
                for url in urls {
                    let fileName = url.lastPathComponent
                    let name = url.deletingPathExtension().lastPathComponent
                    
                    // Skip hidden files and system files
                    guard !name.hasPrefix(".") && !name.hasPrefix("__") else {
                        continue
                    }
                    
                    let video = DemoVideo(
                        id: fileName,
                        name: name,
                        fileName: fileName,
                        fileExtension: ext,
                        url: url
                    )
                    
                    videos.append(video)
                }
            }
        }
        
        // Sort by display name for consistent UI ordering
        return videos.sorted { $0.displayName < $1.displayName }
    }
    
    /// Load a specific video as a VideoFileFrameSource
    /// - Parameters:
    ///   - name: Video name (without extension)
    ///   - ext: File extension (.mov, .mp4, .m4v)
    /// - Returns: VideoFileFrameSource if successful, nil otherwise
    static func loadVideo(named name: String, ext: String) -> VideoFileFrameSource? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            print("[VideoManager] Video not found: \(name).\(ext)")
            return nil
        }
        
        print("[VideoManager] Loading video: \(name).\(ext)")
        return VideoFileFrameSource(url: url, fps: 30.0, loop: true)
    }
    
    /// Get the first available video in the bundle
    /// - Returns: First DemoVideo if any exist, nil otherwise
    static func getDefaultVideo() -> DemoVideo? {
        let videos = scanBundleForVideos()
        return videos.first
    }
    
    /// Check if any demo videos are available
    /// - Returns: true if at least one video is found
    static func hasVideosAvailable() -> Bool {
        return !scanBundleForVideos().isEmpty
    }
}
