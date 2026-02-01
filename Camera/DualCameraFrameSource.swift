//
//  DualCameraFrameSource.swift
//  HackBrown
//
//  AVFoundation-based dual camera capture using AVCaptureMultiCamSession.
//  Captures from both front and back cameras simultaneously for BeReal-style UI.
//  Only available on iPhone XS+ (A12 chip) with iOS 13+.
//

import Foundation
import AVFoundation
import Combine

/// Dual camera frame source that captures from both front and back cameras simultaneously.
/// Uses AVCaptureMultiCamSession which requires iPhone XS or newer (A12 chip+).
final class DualCameraFrameSource: NSObject {
    
    // MARK: - Static Properties
    
    /// Check if dual camera is supported on this device
    static var isSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }
    
    // MARK: - Publishers
    
    /// Publisher for front camera frames (driver monitoring)
    var frontFramePublisher: AnyPublisher<Frame, Never> {
        frontFrameSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for back camera frames (road monitoring)
    var backFramePublisher: AnyPublisher<Frame, Never> {
        backFrameSubject.eraseToAnyPublisher()
    }
    
    // MARK: - State
    
    private(set) var isRunning: Bool = false
    
    // MARK: - Private Properties
    
    private let frontFrameSubject = PassthroughSubject<Frame, Never>()
    private let backFrameSubject = PassthroughSubject<Frame, Never>()
    
    private let multiCamSession = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "com.hackbrown.dualcamera.session")
    private let frontOutputQueue = DispatchQueue(label: "com.hackbrown.dualcamera.front")
    private let backOutputQueue = DispatchQueue(label: "com.hackbrown.dualcamera.back")
    
    private var frontOutput: AVCaptureVideoDataOutput?
    private var backOutput: AVCaptureVideoDataOutput?
    private var frontInput: AVCaptureDeviceInput?
    private var backInput: AVCaptureDeviceInput?
    
    // MARK: - Configuration
    
    /// Primary camera resolution (front - used for driver monitoring)
    private let primaryPreset: AVCaptureSession.Preset = .hd1280x720
    
    /// Secondary camera resolution (back - visual only, lower res for performance)
    private let secondaryResolution = CGSize(width: 640, height: 480)
    
    /// Target frame rate for primary camera (reduced from 30 for efficiency)
    private let primaryFPS: Int32 = 24
    
    /// Target frame rate for secondary camera (lower for performance)
    private let secondaryFPS: Int32 = 12
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setupSession()
    }
    
    // MARK: - Public Methods
    
    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.multiCamSession.isRunning else { return }
            self.multiCamSession.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }
    
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.frontOutput?.setSampleBufferDelegate(nil, queue: nil)
            self.backOutput?.setSampleBufferDelegate(nil, queue: nil)
            if self.multiCamSession.isRunning {
                self.multiCamSession.stopRunning()
            }
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
        guard DualCameraFrameSource.isSupported else {
            print("[DualCameraFrameSource] Multi-cam not supported on this device")
            return
        }
        
        multiCamSession.beginConfiguration()
        defer { multiCamSession.commitConfiguration() }
        
        // Configure front camera (primary - driver monitoring)
        if !configureFrontCamera() {
            print("[DualCameraFrameSource] Failed to configure front camera")
            return
        }
        
        // Configure back camera (secondary - road view)
        if !configureBackCamera() {
            print("[DualCameraFrameSource] Failed to configure back camera")
            return
        }
        
        print("[DualCameraFrameSource] Dual camera session configured successfully")
    }
    
    private func configureFrontCamera() -> Bool {
        // Try ultra-wide first for wider field of view (zoomed out), fallback to wide-angle
        let deviceType: AVCaptureDevice.DeviceType
        if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front) {
            deviceType = .builtInUltraWideCamera
        } else {
            deviceType = .builtInWideAngleCamera
        }
        
        guard let frontDevice = AVCaptureDevice.default(
            deviceType,
            for: .video,
            position: .front
        ) else {
            print("[DualCameraFrameSource] No front camera available")
            return false
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: frontDevice)
            
            guard multiCamSession.canAddInput(input) else {
                print("[DualCameraFrameSource] Cannot add front camera input")
                return false
            }
            
            multiCamSession.addInputWithNoConnections(input)
            frontInput = input
            
            // Configure frame rate and zoom
            try frontDevice.lockForConfiguration()
            frontDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: primaryFPS)
            frontDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: primaryFPS)
            
            // Zoom out front camera to minimum (wider field of view)
            if frontDevice.activeFormat.videoMaxZoomFactor >= 1.0 {
                frontDevice.videoZoomFactor = 1.0
            }
            
            frontDevice.unlockForConfiguration()
            
            // Create output
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: frontOutputQueue)
            
            guard multiCamSession.canAddOutput(output) else {
                print("[DualCameraFrameSource] Cannot add front camera output")
                return false
            }
            
            multiCamSession.addOutputWithNoConnections(output)
            frontOutput = output
            
            // Create connection between input and output
            guard let inputPort = input.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .front).first else {
                print("[DualCameraFrameSource] No front camera input port")
                return false
            }
            
            let connection = AVCaptureConnection(inputPorts: [inputPort], output: output)
            
            guard multiCamSession.canAddConnection(connection) else {
                print("[DualCameraFrameSource] Cannot add front camera connection")
                return false
            }
            
            multiCamSession.addConnection(connection)
            
            // Configure connection - LANDSCAPE orientation for front camera
            // Front camera needs 180° rotation to appear right-side-up in landscape
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(180) {
                    connection.videoRotationAngle = 180  // Landscape left (flipped for front cam)
                }
            } else {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeLeft
                }
            }
            
            // Mirror front camera for natural selfie view
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
            
            return true
            
        } catch {
            print("[DualCameraFrameSource] Error setting up front camera: \(error)")
            return false
        }
    }
    
    private func configureBackCamera() -> Bool {
        guard let backDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            print("[DualCameraFrameSource] No back camera available")
            return false
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: backDevice)
            
            guard multiCamSession.canAddInput(input) else {
                print("[DualCameraFrameSource] Cannot add back camera input")
                return false
            }
            
            multiCamSession.addInputWithNoConnections(input)
            backInput = input
            
            // Configure frame rate (lower for secondary camera)
            try backDevice.lockForConfiguration()
            backDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: secondaryFPS)
            backDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: secondaryFPS)
            backDevice.unlockForConfiguration()
            
            // Create output
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: backOutputQueue)
            
            guard multiCamSession.canAddOutput(output) else {
                print("[DualCameraFrameSource] Cannot add back camera output")
                return false
            }
            
            multiCamSession.addOutputWithNoConnections(output)
            backOutput = output
            
            // Create connection between input and output
            guard let inputPort = input.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first else {
                print("[DualCameraFrameSource] No back camera input port")
                return false
            }
            
            let connection = AVCaptureConnection(inputPorts: [inputPort], output: output)
            
            guard multiCamSession.canAddConnection(connection) else {
                print("[DualCameraFrameSource] Cannot add back camera connection")
                return false
            }
            
            multiCamSession.addConnection(connection)
            
            // Configure connection - LANDSCAPE orientation (app is landscape-only)
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0  // Landscape right
                }
            } else {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeRight
                }
            }
            
            return true
            
        } catch {
            print("[DualCameraFrameSource] Error setting up back camera: \(error)")
            return false
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension DualCameraFrameSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    
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
        
        // Determine which camera this frame is from based on the output
        if output === frontOutput {
            frontFrameSubject.send(frame)
        } else if output === backOutput {
            backFrameSubject.send(frame)
        }
    }
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Frame dropped due to late arrival - expected for secondary camera
    }
}
