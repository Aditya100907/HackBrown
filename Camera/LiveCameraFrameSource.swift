//
//  LiveCameraFrameSource.swift
//  HackBrown
//
//  AVFoundation-based live camera capture. Supports front or rear camera.
//  Conforms to FrameSource protocol for interchangeability with video file input.
//

import Foundation
import AVFoundation
import Combine

final class LiveCameraFrameSource: NSObject, FrameSource {
    
    // MARK: - FrameSource Protocol
    
    var framePublisher: AnyPublisher<Frame, Never> {
        frameSubject.eraseToAnyPublisher()
    }
    
    private(set) var isRunning: Bool = false
    
    // MARK: - Private Properties
    
    private let frameSubject = PassthroughSubject<Frame, Never>()
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.hackbrown.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.hackbrown.camera.output")
    private let cameraPosition: CameraPosition
    
    // MARK: - Configuration
    
    /// Target resolution preset. Lower = faster processing, higher latency tolerance.
    private let sessionPreset: AVCaptureSession.Preset = .hd1280x720
    
    /// Target frame rate
    private let targetFPS: Int32 = 30
    
    // MARK: - Initialization
    
    init(position: CameraPosition) {
        self.cameraPosition = position
        super.init()
        setupSession()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - FrameSource Methods
    
    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }
    
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }
    
    // MARK: - Session Setup
    
    private func setupSession() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }
    
    private func configureSession() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Set session preset
        if captureSession.canSetSessionPreset(sessionPreset) {
            captureSession.sessionPreset = sessionPreset
        }
        
        // Add video input
        guard let videoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: cameraPosition.avPosition
        ) else {
            print("[LiveCameraFrameSource] No camera available for position: \(cameraPosition)")
            return
        }
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            } else {
                print("[LiveCameraFrameSource] Cannot add video input")
                return
            }
            
            // Configure frame rate
            try videoDevice.lockForConfiguration()
            videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: targetFPS)
            videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: targetFPS)
            videoDevice.unlockForConfiguration()
            
        } catch {
            print("[LiveCameraFrameSource] Error setting up video input: \(error)")
            return
        }
        
        // Add video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true  // Drop stale frames for latency
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            
            // Set video orientation
            if let connection = videoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90  // Portrait orientation
                    }
                } else {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                }
                // Mirror front camera for natural selfie view
                if cameraPosition == .front && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
        } else {
            print("[LiveCameraFrameSource] Cannot add video output")
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension LiveCameraFrameSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = Frame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        
        frameSubject.send(frame)
    }
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Frame dropped due to late arrival - this is expected and fine for latency
    }
}
