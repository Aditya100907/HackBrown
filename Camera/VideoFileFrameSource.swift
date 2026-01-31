//
//  VideoFileFrameSource.swift
//  HackBrown
//
//  Video file reader that mimics live camera feed.
//  Reads prerecorded video and emits frames at a fixed FPS.
//  Same interface as LiveCameraFrameSource for testing/demos.
//

import Foundation
import AVFoundation
import Combine

final class VideoFileFrameSource: FrameSource {
    
    // MARK: - FrameSource Protocol
    
    var framePublisher: AnyPublisher<Frame, Never> {
        frameSubject.eraseToAnyPublisher()
    }
    
    private(set) var isRunning: Bool = false
    
    // MARK: - Private Properties
    
    private let frameSubject = PassthroughSubject<Frame, Never>()
    private let videoURL: URL
    private let targetFPS: Double
    private let loop: Bool
    
    private var asset: AVAsset?
    private var assetReader: AVAssetReader?
    private var videoTrackOutput: AVAssetReaderTrackOutput?
    private var frameTimer: DispatchSourceTimer?
    private let processingQueue = DispatchQueue(label: "com.hackbrown.videofile.processing")
    
    private var currentFrameIndex: Int = 0
    
    // MARK: - Initialization
    
    /// Initialize with a video file URL
    /// - Parameters:
    ///   - url: URL to the video file (bundle resource or file system)
    ///   - fps: Target frames per second to emit (default 30)
    ///   - loop: Whether to loop the video when it ends (default true for demo)
    init(url: URL, fps: Double = 30.0, loop: Bool = true) {
        self.videoURL = url
        self.targetFPS = fps
        self.loop = loop
    }
    
    /// Convenience initializer for bundle resources
    /// - Parameters:
    ///   - fileName: Name of the video file (without extension)
    ///   - fileExtension: File extension (e.g., "mp4", "mov")
    ///   - fps: Target frames per second
    ///   - loop: Whether to loop
    convenience init?(bundleResource fileName: String, withExtension fileExtension: String, fps: Double = 30.0, loop: Bool = true) {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension) else {
            print("[VideoFileFrameSource] Bundle resource not found: \(fileName).\(fileExtension)")
            return nil
        }
        self.init(url: url, fps: fps, loop: loop)
    }
    
    deinit {
        stop()
    }
    
    // MARK: - FrameSource Methods
    
    func start() {
        guard !isRunning else { return }
        
        processingQueue.async { [weak self] in
            self?.setupReader()
            self?.startFrameTimer()
            DispatchQueue.main.async {
                self?.isRunning = true
            }
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        frameTimer?.cancel()
        frameTimer = nil
        assetReader?.cancelReading()
        assetReader = nil
        videoTrackOutput = nil
        currentFrameIndex = 0
        
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
    }
    
    // MARK: - Private Methods
    
    private func setupReader() {
        asset = AVAsset(url: videoURL)
        
        guard let asset = asset else {
            print("[VideoFileFrameSource] Failed to create asset from URL: \(videoURL)")
            return
        }
        
        do {
            assetReader = try AVAssetReader(asset: asset)
        } catch {
            print("[VideoFileFrameSource] Failed to create asset reader: \(error)")
            return
        }
        
        // Get video track
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    print("[VideoFileFrameSource] No video track found")
                    return
                }
                
                await MainActor.run {
                    self.configureOutput(for: videoTrack)
                }
            } catch {
                print("[VideoFileFrameSource] Failed to load video tracks: \(error)")
            }
        }
    }
    
    private func configureOutput(for videoTrack: AVAssetTrack) {
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        videoTrackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)

        if let output = videoTrackOutput, assetReader?.canAdd(output) == true {
            assetReader?.add(output)
        }
        
        assetReader?.startReading()
    }
    
    private func startFrameTimer() {
        let interval = 1.0 / targetFPS
        
        frameTimer = DispatchSource.makeTimerSource(queue: processingQueue)
        frameTimer?.schedule(deadline: .now(), repeating: interval)
        frameTimer?.setEventHandler { [weak self] in
            self?.emitNextFrame()
        }
        frameTimer?.resume()
    }
    
    private func emitNextFrame() {
        guard let output = videoTrackOutput,
              let assetReader = assetReader else {
            return
        }
        
        // Check reader status
        if assetReader.status == .completed {
            if loop {
                // Restart from beginning
                restartReader()
            } else {
                stop()
            }
            return
        }
        
        guard assetReader.status == .reading else {
            return
        }
        
        // Get next sample buffer
        guard let sampleBuffer = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = Frame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        
        currentFrameIndex += 1
        frameSubject.send(frame)
    }
    
    private func restartReader() {
        assetReader?.cancelReading()
        assetReader = nil
        videoTrackOutput = nil
        currentFrameIndex = 0
        
        // Small delay before restarting to avoid tight loop on error
        processingQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupReader()
        }
    }
}

// MARK: - Video File Picker Helper

/// Helper to get video file URLs from common locations
enum VideoFileHelper {
    
    /// Get URL for a video in the app bundle
    static func bundleURL(name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
    }
    
    /// Get URL for a video in the Documents directory
    static func documentsURL(fileName: String) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(fileName)
    }
    
    /// Check if a file exists at the given URL
    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
