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
import CoreImage

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

/// COCO 80 class names (YOLO default)
private let cocoClassNames = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog",
    "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella",
    "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite",
    "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
    "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich",
    "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
    "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote",
    "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "book",
    "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
]

/// Object classes from YOLO/COCO (all 80 classes shown)
enum ObjectLabel: String, CaseIterable {
    case person, bicycle, car, motorcycle, airplane, bus, train, truck, boat
    case trafficLight = "traffic light"
    case fireHydrant = "fire hydrant"
    case stopSign = "stop sign"
    case parkingMeter = "parking meter"
    case bench, bird, cat, dog, horse, sheep, cow, elephant, bear, zebra, giraffe
    case backpack, umbrella, handbag, tie, suitcase, frisbee, skis, snowboard
    case sportsBall = "sports ball"
    case kite, baseballBat = "baseball bat", baseballGlove = "baseball glove"
    case skateboard, surfboard, tennisRacket = "tennis racket", bottle
    case wineGlass = "wine glass", cup, fork, knife, spoon, bowl, banana, apple
    case sandwich, orange, broccoli, carrot, hotDog = "hot dog", pizza, donut, cake
    case chair, couch, pottedPlant = "potted plant", bed, diningTable = "dining table"
    case toilet, tv, laptop, mouse, remote, keyboard, cellPhone = "cell phone"
    case microwave, oven, toaster, sink, refrigerator, book, clock, vase, scissors
    case teddyBear = "teddy bear", hairDrier = "hair drier", toothbrush
    case unknown = "unknown"
    
    /// Whether this is a ROAD vehicle (not planes, trains, boats!)
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
    
    /// Whether this is relevant for road safety (the ONLY things we care about)
    var isRoadRelevant: Bool {
        return isVehicle || isVulnerableRoadUser
    }
    
    /// Initialize from YOLO/COCO class index (0-79)
    init(cocoIndex: Int) {
        guard cocoIndex >= 0, cocoIndex < cocoClassNames.count else {
            self = .unknown
            return
        }
        let name = cocoClassNames[cocoIndex]
        self = Self(rawValue: name) ?? .unknown
    }
    
    /// Initialize from YOLO/COCO class name
    init(cocoClass: String) {
        let lowercased = cocoClass.lowercased()
        self = Self(rawValue: lowercased) ?? Self(rawValue: lowercased.replacingOccurrences(of: " ", with: "")) ?? .unknown
    }
}

// MARK: - Object Detector

/// CoreML-based object detector using YOLO-style model
final class ObjectDetector: @unchecked Sendable {
    
    // MARK: - Properties
    
    /// Minimum confidence threshold for detections
    private let confidenceThreshold: Float
    
    /// IoU threshold for non-maximum suppression
    private let iouThreshold: Float = 0.45
    
    /// Vision model for CoreML inference
    private var visionModel: VNCoreMLModel?
    
    /// Direct CoreML model for YOLOv8 raw output processing
    private var mlModel: MLModel?
    
    /// Whether the detector is ready
    var isReady: Bool {
        visionModel != nil || mlModel != nil
    }
    
    /// Whether using YOLOv8 raw output format
    private var isYOLOv8RawFormat: Bool = false
    
    /// Frame counter for debugging
    private var frameCount: Int = 0
    private var lastLogTime: Date = Date()
    
    // MARK: - Initialization
    
    /// Initialize with optional custom model
    /// - Parameters:
    ///   - modelURL: URL to .mlmodelc, or nil to use bundled model
    ///   - confidenceThreshold: Minimum confidence (default 0.4)
    init(modelURL: URL? = nil, confidenceThreshold: Float = 0.25) {
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
        let modelNames = ["yolov8n", "yolov8s", "yolov8m", "YOLOv8", "YOLOv5", "YOLOv3", "YOLOv3Tiny", "yolo", "ObjectDetector"]
        
        // Try .mlmodelc (compiled from .mlmodel or .mlpackage at build time)
        for name in modelNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                print("[ObjectDetector] Found compiled model: \(name).mlmodelc")
                return url
            }
        }
        
        // Try .mlpackage (YOLOv8-CoreML format - may be compiled to .mlmodelc)
        for name in modelNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
                print("[ObjectDetector] Found mlpackage: \(name).mlpackage")
                return url
            }
        }
        
        // Debug: List all resources in bundle
        if let resourcePath = Bundle.main.resourcePath {
            do {
                let items = try FileManager.default.contentsOfDirectory(atPath: resourcePath)
                let modelFiles = items.filter { $0.contains("yolo") || $0.contains("YOLO") || $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }
                if !modelFiles.isEmpty {
                    print("[ObjectDetector] Model-related files in bundle: \(modelFiles)")
                }
            } catch {
                print("[ObjectDetector] Could not list bundle contents: \(error)")
            }
        }
        
        return nil
    }
    
    private func loadModelFromURL(_ url: URL) {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all  // Use CPU, GPU, and Neural Engine
            
            print("[ObjectDetector] Loading model from: \(url.path)")
            let model = try MLModel(contentsOf: url, configuration: config)
            mlModel = model
            
            // Log model details
            print("[ObjectDetector] Model description:")
            print("[ObjectDetector]   Inputs: \(model.modelDescription.inputDescriptionsByName.keys.joined(separator: ", "))")
            print("[ObjectDetector]   Outputs: \(model.modelDescription.outputDescriptionsByName.keys.joined(separator: ", "))")
            
            // Log input details
            for (name, desc) in model.modelDescription.inputDescriptionsByName {
                print("[ObjectDetector]   Input '\(name)': type=\(desc.type.rawValue)")
                if let constraint = desc.imageConstraint {
                    print("[ObjectDetector]     Image: \(constraint.pixelsWide)x\(constraint.pixelsHigh)")
                }
                if let constraint = desc.multiArrayConstraint {
                    print("[ObjectDetector]     MultiArray shape: \(constraint.shape)")
                }
            }
            
            // Check if model outputs VNRecognizedObjectObservation or raw tensors
            // YOLOv8 models typically output raw tensors that need post-processing
            for (outputName, outputDesc) in model.modelDescription.outputDescriptionsByName {
                print("[ObjectDetector]   Output '\(outputName)': type=\(outputDesc.type.rawValue)")
                
                // If output is MultiArray, we need raw YOLOv8 processing
                if outputDesc.type == .multiArray {
                    isYOLOv8RawFormat = true
                    if let constraint = outputDesc.multiArrayConstraint {
                        print("[ObjectDetector]     MultiArray shape: \(constraint.shape)")
                    }
                }
            }
            
            if isYOLOv8RawFormat {
                print("[ObjectDetector] Using YOLOv8 raw tensor processing")
            }
            
            // Also try to create Vision model for standard detection
            do {
                visionModel = try VNCoreMLModel(for: model)
                print("[ObjectDetector] Vision model created successfully")
            } catch {
                print("[ObjectDetector] Could not create Vision model (will use raw processing): \(error.localizedDescription)")
            }
            
            print("[ObjectDetector] ✅ Model loaded successfully from: \(url.lastPathComponent)")
        } catch {
            print("[ObjectDetector] ❌ Failed to load model: \(error)")
        }
    }
    
    // MARK: - Detection
    
    /// Detect objects in a pixel buffer
    /// - Parameter pixelBuffer: Input image
    /// - Returns: Array of detected objects (ONLY road-relevant: cars, trucks, buses, motorcycles, people, bicycles)
    func detect(in pixelBuffer: CVPixelBuffer) -> [DetectedObject] {
        frameCount += 1
        
        // Log every 30 frames (~1 second at 30fps)
        let now = Date()
        if now.timeIntervalSince(lastLogTime) >= 2.0 {
            let fps = Double(frameCount) / now.timeIntervalSince(lastLogTime)
            print("[ObjectDetector] Processing frames at \(String(format: "%.1f", fps)) fps, model ready: \(isReady)")
            frameCount = 0
            lastLogTime = now
        }
        
        var detections: [DetectedObject] = []
        
        // First try Vision framework (works with properly formatted models)
        if let visionModel = visionModel, !isYOLOv8RawFormat {
            detections = detectWithVision(pixelBuffer: pixelBuffer, model: visionModel)
        }
        // Fall back to raw YOLOv8 processing
        else if let mlModel = mlModel {
            detections = detectWithRawYOLOv8(pixelBuffer: pixelBuffer, model: mlModel)
        }
        // Log if no model available
        else if frameCount == 1 {
            print("[ObjectDetector] No model available - returning empty detections")
        }
        
        // STRICT FILTER: Only return road-relevant objects (cars, trucks, buses, motorcycles, people, bicycles)
        // NO planes, NO trains, NO boats, NO animals, NO furniture, NO food, etc.
        return detections.filter { $0.label.isRoadRelevant }
    }
    
    /// Detect using Vision framework
    private func detectWithVision(pixelBuffer: CVPixelBuffer, model: VNCoreMLModel) -> [DetectedObject] {
        var detections: [DetectedObject] = []
        let semaphore = DispatchSemaphore(value: 0)
        
        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            defer { semaphore.signal() }
            
            guard let self = self else { return }
            
            if let error = error {
                print("[ObjectDetector] Vision detection error: \(error)")
                return
            }
            
            detections = self.processVisionResults(request.results)
        }
        
        // Configure for better performance
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
            semaphore.wait()
        } catch {
            print("[ObjectDetector] Vision handler error: \(error)")
        }
        
        return detections
    }
    
    /// Detect using raw YOLOv8 output processing
    private func detectWithRawYOLOv8(pixelBuffer: CVPixelBuffer, model: MLModel) -> [DetectedObject] {
        // Get input description to find the input name and expected format
        guard let inputDescription = model.modelDescription.inputDescriptionsByName.first else {
            print("[ObjectDetector] No input description found")
            return []
        }
        
        let inputName = inputDescription.key
        let inputDesc = inputDescription.value
        
        do {
            var inputFeatures: [String: Any] = [:]
            
            // Check if input expects image or multiarray
            if inputDesc.type == .image {
                // Model expects CVPixelBuffer directly
                // Resize to expected size if specified
                let targetWidth = inputDesc.imageConstraint?.pixelsWide ?? 640
                let targetHeight = inputDesc.imageConstraint?.pixelsHigh ?? 640
                
                if let resizedBuffer = resizePixelBuffer(pixelBuffer, width: targetWidth, height: targetHeight) {
                    inputFeatures[inputName] = resizedBuffer
                } else {
                    inputFeatures[inputName] = pixelBuffer
                }
            } else if inputDesc.type == .multiArray {
                // Model expects MLMultiArray - convert pixel buffer
                guard let resizedBuffer = resizePixelBuffer(pixelBuffer, width: 640, height: 640) else {
                    print("[ObjectDetector] Failed to resize pixel buffer")
                    return []
                }
                
                if let multiArray = pixelBufferToMultiArray(resizedBuffer) {
                    inputFeatures[inputName] = multiArray
                } else {
                    print("[ObjectDetector] Failed to convert pixel buffer to multi array")
                    return []
                }
            } else {
                // Try pixel buffer directly
                guard let resizedBuffer = resizePixelBuffer(pixelBuffer, width: 640, height: 640) else {
                    print("[ObjectDetector] Failed to resize pixel buffer")
                    return []
                }
                inputFeatures[inputName] = resizedBuffer
            }
            
            // Run inference
            let input = try MLDictionaryFeatureProvider(dictionary: inputFeatures)
            let output = try model.prediction(from: input)
            
            // Process YOLOv8 output
            // YOLOv8 output shape is typically (1, 84, 8400) where:
            // - 84 = 4 (bbox: x, y, w, h) + 80 (class scores)
            // - 8400 = number of detection anchors
            
            // Try to get the output (name may vary)
            var outputArray: MLMultiArray?
            for featureName in output.featureNames {
                if let array = output.featureValue(for: featureName)?.multiArrayValue {
                    outputArray = array
                    break
                }
            }
            
            guard let predictions = outputArray else {
                print("[ObjectDetector] Could not get output array from features: \(output.featureNames)")
                return []
            }
            
            return processYOLOv8Output(predictions)
            
        } catch {
            print("[ObjectDetector] YOLOv8 inference error: \(error)")
            return []
        }
    }
    
    /// Convert pixel buffer to MLMultiArray for models that expect tensor input
    private func pixelBufferToMultiArray(_ pixelBuffer: CVPixelBuffer) -> MLMultiArray? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        // Create MLMultiArray with shape [1, 3, height, width] (NCHW format)
        guard let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32) else {
            return nil
        }
        
        let pointer = UnsafeMutablePointer<Float>(OpaquePointer(array.dataPointer))
        let channelStride = width * height
        
        // Convert BGRA to RGB and normalize to 0-1
        for y in 0..<height {
            for x in 0..<width {
                let pixelOffset = y * bytesPerRow + x * 4
                let b = Float(buffer[pixelOffset]) / 255.0
                let g = Float(buffer[pixelOffset + 1]) / 255.0
                let r = Float(buffer[pixelOffset + 2]) / 255.0
                
                let idx = y * width + x
                pointer[0 * channelStride + idx] = r  // Red channel
                pointer[1 * channelStride + idx] = g  // Green channel
                pointer[2 * channelStride + idx] = b  // Blue channel
            }
        }
        
        return array
    }
    
    /// Process YOLOv8 raw output tensor
    private func processYOLOv8Output(_ output: MLMultiArray) -> [DetectedObject] {
        var detections: [DetectedObject] = []
        
        // Get dimensions
        let shape = output.shape.map { $0.intValue }
        
        // YOLOv8 output can be (1, 84, 8400) or (1, 8400, 84) depending on export settings
        // We need to handle both cases
        
        let numClasses = 80
        let numBoxes: Int
        let stride: Int
        let transposed: Bool
        
        if shape.count == 3 {
            if shape[1] == 84 {
                // Shape: (1, 84, 8400) - features first
                numBoxes = shape[2]
                stride = shape[1]
                transposed = false
            } else if shape[2] == 84 {
                // Shape: (1, 8400, 84) - boxes first
                numBoxes = shape[1]
                stride = shape[2]
                transposed = true
            } else {
                print("[ObjectDetector] Unexpected output shape: \(shape)")
                return []
            }
        } else {
            print("[ObjectDetector] Unexpected output dimensions: \(shape.count)")
            return []
        }
        
        let pointer = UnsafeMutablePointer<Float>(OpaquePointer(output.dataPointer))
        
        for i in 0..<numBoxes {
            // Get box coordinates and class scores
            var x, y, w, h: Float
            var classScores: [Float] = []
            
            if transposed {
                // (1, 8400, 84) format
                let offset = i * stride
                x = pointer[offset + 0]
                y = pointer[offset + 1]
                w = pointer[offset + 2]
                h = pointer[offset + 3]
                for c in 0..<numClasses {
                    classScores.append(pointer[offset + 4 + c])
                }
            } else {
                // (1, 84, 8400) format
                x = pointer[0 * numBoxes + i]
                y = pointer[1 * numBoxes + i]
                w = pointer[2 * numBoxes + i]
                h = pointer[3 * numBoxes + i]
                for c in 0..<numClasses {
                    classScores.append(pointer[(4 + c) * numBoxes + i])
                }
            }
            
            // Find best class
            var maxScore: Float = 0
            var maxIndex: Int = 0
            for (idx, score) in classScores.enumerated() {
                if score > maxScore {
                    maxScore = score
                    maxIndex = idx
                }
            }
            
            // Filter by confidence
            guard maxScore >= confidenceThreshold else { continue }
            
            // Convert to ObjectLabel and filter to only relevant road safety classes
            let label = ObjectLabel(cocoIndex: maxIndex)
            
            // Skip irrelevant classes (only show vehicles and vulnerable road users)
            guard label.isVehicle || label.isVulnerableRoadUser else { 
                continue 
            }
            
            // Convert from center format (cx, cy, w, h) to corner format (x, y, w, h)
            // Also normalize to 0-1 range (YOLOv8 outputs are in pixel coordinates for 640x640)
            let boxX = (x - w / 2) / 640.0
            let boxY = (y - h / 2) / 640.0
            let boxW = w / 640.0
            let boxH = h / 640.0
            
            // Clamp values to valid range
            let clampedX = max(0, min(1, CGFloat(boxX)))
            let clampedY = max(0, min(1, CGFloat(boxY)))
            let clampedW = max(0, min(1 - clampedX, CGFloat(boxW)))
            let clampedH = max(0, min(1 - clampedY, CGFloat(boxH)))
            
            let boundingBox = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
            
            detections.append(DetectedObject(
                label: label,
                confidence: maxScore,
                boundingBox: boundingBox
            ))
        }
        
        // Log raw detection counts by class for debugging
        if !detections.isEmpty {
            let classCounts = Dictionary(grouping: detections, by: { $0.label })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
            let summary = classCounts.map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ", ")
            print("[ObjectDetector] Raw detections by class: \(summary)")
        }
        
        // Apply non-maximum suppression
        let nmsDetections = nonMaximumSuppression(detections: detections, iouThreshold: iouThreshold)
        
        if !nmsDetections.isEmpty {
            print("[ObjectDetector] Detected \(nmsDetections.count) objects: \(nmsDetections.map { "\($0.label.rawValue) (\(Int($0.confidence * 100))%)" }.joined(separator: ", "))")
        }
        
        return nmsDetections
    }
    
    /// Non-maximum suppression to remove overlapping detections
    private func nonMaximumSuppression(detections: [DetectedObject], iouThreshold: Float) -> [DetectedObject] {
        guard !detections.isEmpty else { return [] }
        
        // Sort by confidence (highest first)
        var sorted = detections.sorted { $0.confidence > $1.confidence }
        var selected: [DetectedObject] = []
        
        while !sorted.isEmpty {
            let current = sorted.removeFirst()
            selected.append(current)
            
            // Remove overlapping boxes of same class
            sorted = sorted.filter { detection in
                if detection.label != current.label {
                    return true  // Keep different classes
                }
                let iou = calculateIoU(current.boundingBox, detection.boundingBox)
                return iou < CGFloat(iouThreshold)
            }
        }
        
        return selected
    }
    
    /// Calculate Intersection over Union
    private func calculateIoU(_ box1: CGRect, _ box2: CGRect) -> CGFloat {
        let intersection = box1.intersection(box2)
        if intersection.isNull { return 0 }
        
        let intersectionArea = intersection.width * intersection.height
        let unionArea = box1.width * box1.height + box2.width * box2.height - intersectionArea
        
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
    
    /// Resize pixel buffer to target size
    private func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var resizedBuffer: CVPixelBuffer?
        
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &resizedBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = resizedBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        let scaleX = CGFloat(width) / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let scaleY = CGFloat(height) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        context.render(scaledImage, to: outputBuffer)
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        
        return outputBuffer
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
    
    // MARK: - Vision Result Processing
    
    private func processVisionResults(_ results: [Any]?) -> [DetectedObject] {
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
