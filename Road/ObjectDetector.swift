//
//  ObjectDetector.swift
//  HackBrown
//
//  CoreML YOLO-style object detector wrapper.
//  Detects vehicles, pedestrians, and cyclists in road frames.
//

import Foundation
import CoreML
import Vision
import CoreVideo

// MARK: - Detection Result

/// A single detected object from the YOLO model
struct DetectedObject: Identifiable {
    let id = UUID()
    
    /// Object class label
    let label: ObjectLabel
    
    /// Confidence score (0-1)
    let confidence: Float
    
    /// Bounding box in normalized coordinates (0-1)
    /// Origin is top-left, (x, y, width, height)
    let boundingBox: CGRect
    
    /// Area of bounding box (for tracking "growth")
    var area: CGFloat {
        boundingBox.width * boundingBox.height
    }
    
    /// Center point of bounding box
    var center: CGPoint {
        CGPoint(
            x: boundingBox.midX,
            y: boundingBox.midY
        )
    }
}

/// Object classes we care about for road hazard detection
enum ObjectLabel: String, CaseIterable {
    case car = "car"
    case truck = "truck"
    case bus = "bus"
    case motorcycle = "motorcycle"
    case bicycle = "bicycle"
    case person = "person"
    case unknown = "unknown"
    
    /// Whether this is a vehicle type
    var isVehicle: Bool {
        switch self {
        case .car, .truck, .bus, .motorcycle:
            return true
        default:
            return false
        }
    }
    
    /// Whether this is a vulnerable road user
    var isVulnerableRoadUser: Bool {
        switch self {
        case .person, .bicycle:
            return true
        default:
            return false
        }
    }
    
    /// Initialize from YOLO/COCO class name
    init(cocoClass: String) {
        let lowercased = cocoClass.lowercased()
        switch lowercased {
        case "car", "automobile":
            self = .car
        case "truck":
            self = .truck
        case "bus":
            self = .bus
        case "motorcycle", "motorbike":
            self = .motorcycle
        case "bicycle", "bike":
            self = .bicycle
        case "person", "pedestrian":
            self = .person
        default:
            self = .unknown
        }
    }
}

// MARK: - Object Detector

/// CoreML-based object detector using YOLO-style model
final class ObjectDetector {
    
    // MARK: - Properties
    
    /// Minimum confidence threshold for detections
    private let confidenceThreshold: Float
    
    /// Vision model for CoreML inference
    private var visionModel: VNCoreMLModel?
    
    /// Whether the detector is ready
    var isReady: Bool {
        visionModel != nil
    }
    
    // MARK: - Initialization
    
    /// Initialize with optional custom model
    /// - Parameters:
    ///   - modelURL: URL to .mlmodelc, or nil to use bundled model
    ///   - confidenceThreshold: Minimum confidence (default 0.5)
    init(modelURL: URL? = nil, confidenceThreshold: Float = 0.5) {
        self.confidenceThreshold = confidenceThreshold
        loadModel(from: modelURL)
    }
    
    // MARK: - Model Loading
    
    private func loadModel(from url: URL?) {
        // Try provided URL first
        if let url = url {
            loadModelFromURL(url)
            return
        }
        
        // Try to find bundled model
        if let bundledURL = findBundledModel() {
            loadModelFromURL(bundledURL)
            return
        }
        
        print("[ObjectDetector] No model found. Add a YOLO .mlmodel to Resources/")
    }
    
    private func findBundledModel() -> URL? {
        // Look for common YOLO model names in bundle (per PROJECT_SPEC: YOLO-style CoreML)
        let modelNames = ["YOLOv8", "YOLOv5", "YOLOv3", "YOLOv3Tiny", "yolov8s", "yolo", "ObjectDetector"]
        
        // Try .mlmodelc (compiled from .mlmodel at build time)
        for name in modelNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                return url
            }
        }
        
        // Try .mlpackage (YOLOv8-CoreML format)
        for name in modelNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
                return url
            }
        }
        
        return nil
    }
    
    private func loadModelFromURL(_ url: URL) {
        do {
            let mlModel = try MLModel(contentsOf: url)
            visionModel = try VNCoreMLModel(for: mlModel)
            print("[ObjectDetector] Model loaded successfully from: \(url.lastPathComponent)")
        } catch {
            print("[ObjectDetector] Failed to load model: \(error)")
        }
    }
    
    // MARK: - Detection
    
    /// Detect objects in a pixel buffer
    /// - Parameter pixelBuffer: Input image
    /// - Returns: Array of detected objects
    func detect(in pixelBuffer: CVPixelBuffer) -> [DetectedObject] {
        guard let visionModel = visionModel else {
            // Return empty if no model loaded (allows app to run without model)
            return []
        }
        
        var detections: [DetectedObject] = []
        let semaphore = DispatchSemaphore(value: 0)
        
        let request = VNCoreMLRequest(model: visionModel) { [weak self] request, error in
            defer { semaphore.signal() }
            
            guard let self = self else { return }
            
            if let error = error {
                print("[ObjectDetector] Detection error: \(error)")
                return
            }
            
            detections = self.processResults(request.results)
        }
        
        // Configure for better performance
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
            semaphore.wait()
        } catch {
            print("[ObjectDetector] Handler error: \(error)")
        }
        
        return detections
    }
    
    /// Async version of detect
    func detectAsync(in pixelBuffer: CVPixelBuffer) async -> [DetectedObject] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results = self.detect(in: pixelBuffer)
                continuation.resume(returning: results)
            }
        }
    }
    
    // MARK: - Result Processing
    
    private func processResults(_ results: [Any]?) -> [DetectedObject] {
        guard let observations = results as? [VNRecognizedObjectObservation] else {
            return []
        }
        
        return observations.compactMap { observation -> DetectedObject? in
            // Get top label
            guard let topLabel = observation.labels.first,
                  topLabel.confidence >= confidenceThreshold else {
                return nil
            }
            
            let label = ObjectLabel(cocoClass: topLabel.identifier)
            
            // Filter to only relevant classes
            guard label != .unknown else {
                return nil
            }
            
            // Convert Vision coordinates (origin bottom-left) to standard (origin top-left)
            let boundingBox = CGRect(
                x: observation.boundingBox.origin.x,
                y: 1 - observation.boundingBox.origin.y - observation.boundingBox.height,
                width: observation.boundingBox.width,
                height: observation.boundingBox.height
            )
            
            return DetectedObject(
                label: label,
                confidence: topLabel.confidence,
                boundingBox: boundingBox
            )
        }
    }
}

// MARK: - Mock Detector for Testing

/// Mock detector that returns simulated detections (for testing without model)
final class MockObjectDetector {
    
    func detect(in pixelBuffer: CVPixelBuffer) -> [DetectedObject] {
        // Return a simulated car detection for testing
        return [
            DetectedObject(
                label: .car,
                confidence: 0.85,
                boundingBox: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.3)
            )
        ]
    }
}
