import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation
import Vision
import CoreImage
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
import Combine
import Network

// MARK: - Data Models

struct OCRBox: Codable, Identifiable {
    var id: String { "\(x)_\(y)_\(width)_\(height)_\(text.hashValue)" }
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCREvent: Codable, Identifiable {
    var id: String { "\(elapsedSeconds)_\(text.hashValue)" }
    let elapsedSeconds: Double
    let wallClockISO8601: String
    let framePTSSeconds: Double
    let visualChange: Double
    let text: String
    let boxes: [OCRBox]
    var passType: String = "live"
    var detectedRegionsCount: Int = 0
    var scaleFactor: Double = 1.0
}

struct RecordingOptions {
    var fps: Int = 60
    var ocrFPS: Double = 6.0
    var displayIndex: Int = 0
    var accurateOCR: Bool = true
    var captureAudio: Bool = true
    var changeThreshold: Double = 0.012
    var forceOCRInterval: Double = 1.25
    var region: CGRect? = nil
    var enableTrajectorySelection: Bool = true
}

// MARK: - High-DPI Upscaling Engine

final class ImageScaler: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func upscaleIfNeeded(_ pixelBuffer: CVPixelBuffer) -> (CVPixelBuffer, Double) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // If capture region is small (e.g. 525x178), upscale 2.5x to boost text height for Vision OCR
        let targetScale: Double
        if w < 600 || h < 400 {
            targetScale = 2.5
        } else if w < 1000 || h < 700 {
            targetScale = 1.8
        } else {
            return (pixelBuffer, 1.0)
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(targetScale), y: CGFloat(targetScale)))

        let newWidth = Int(Double(w) * targetScale)
        let newHeight = Int(Double(h) * targetScale)

        var newBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            newWidth,
            newHeight,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &newBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = newBuffer else {
            return (pixelBuffer, 1.0)
        }

        context.render(scaledImage, to: outputBuffer)
        return (outputBuffer, targetScale)
    }
}

// MARK: - Trajectory Frame Candidate Buffer

final class FrameCandidate: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let pts: CMTime
    let elapsed: Double
    let ptsSeconds: Double
    let wallClock: String
    let visualChange: Double
    let sharpnessScore: Double

    init(pixelBuffer: CVPixelBuffer, pts: CMTime, elapsed: Double, ptsSeconds: Double, wallClock: String, visualChange: Double, sharpnessScore: Double) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.elapsed = elapsed
        self.ptsSeconds = ptsSeconds
        self.wallClock = wallClock
        self.visualChange = visualChange
        self.sharpnessScore = sharpnessScore
    }
}

final class TrajectoryTracker: @unchecked Sendable {
    private var candidateBuffer: [FrameCandidate] = []
    private var isTrackingMotion = false
    private var previousChange: Double = 0

    func processFrame(candidate: FrameCandidate, threshold: Double) -> FrameCandidate? {
        let change = candidate.visualChange

        if change >= threshold {
            candidateBuffer.append(candidate)
            isTrackingMotion = true
            previousChange = change
            if candidateBuffer.count > 10 {
                candidateBuffer.removeFirst()
            }
            return nil
        } else if isTrackingMotion {
            isTrackingMotion = false
            let bestCandidate = candidateBuffer.max(by: { $0.sharpnessScore < $1.sharpnessScore }) ?? candidate
            candidateBuffer.removeAll()
            return bestCandidate
        }

        previousChange = change
        return nil
    }
}

// MARK: - Sidecar File Writer

final class SidecarWriter: @unchecked Sendable {
    private let jsonlHandle: FileHandle
    private let transcriptHandle: FileHandle
    private let srtHandle: FileHandle
    private let encoder: JSONEncoder
    private var seenLines = Set<String>()
    private var pendingSRT: OCREvent?
    private var srtIndex = 1

    init(directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let jsonlURL = directory.appendingPathComponent("ocr.jsonl")
        let transcriptURL = directory.appendingPathComponent("transcript.txt")
        let srtURL = directory.appendingPathComponent("ocr.srt")

        fm.createFile(atPath: jsonlURL.path, contents: nil)
        fm.createFile(atPath: transcriptURL.path, contents: nil)
        fm.createFile(atPath: srtURL.path, contents: nil)

        jsonlHandle = try FileHandle(forWritingTo: jsonlURL)
        transcriptHandle = try FileHandle(forWritingTo: transcriptURL)
        srtHandle = try FileHandle(forWritingTo: srtURL)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    deinit {
        try? jsonlHandle.close()
        try? transcriptHandle.close()
        try? srtHandle.close()
    }

    func write(_ event: OCREvent) throws {
        var data = try encoder.encode(event)
        data.append(0x0A)
        try jsonlHandle.write(contentsOf: data)

        let lines = event.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var novel: [String] = []
        for line in lines {
            let key = normalize(line)
            guard key.count >= 2, !seenLines.contains(key) else { continue }
            seenLines.insert(key)
            novel.append(line)
        }

        if !novel.isEmpty {
            let block = novel.joined(separator: "\n") + "\n"
            try transcriptHandle.write(contentsOf: Data(block.utf8))
        }

        if let previous = pendingSRT {
            try writeSRT(previous, endingAt: max(previous.elapsedSeconds + 0.20, event.elapsedSeconds))
        }
        pendingSRT = event
    }

    func finish(finalElapsed: Double) throws {
        if let pending = pendingSRT {
            try writeSRT(pending, endingAt: max(pending.elapsedSeconds + 1.0, finalElapsed))
        }
        pendingSRT = nil

        try jsonlHandle.synchronize()
        try transcriptHandle.synchronize()
        try srtHandle.synchronize()
        try jsonlHandle.close()
        try transcriptHandle.close()
        try srtHandle.close()
    }

    private func writeSRT(_ event: OCREvent, endingAt end: Double) throws {
        guard !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let block = """
        \(srtIndex)
        \(srtTime(event.elapsedSeconds)) --> \(srtTime(end))
        \(event.text)

        """
        try srtHandle.write(contentsOf: Data(block.utf8))
        srtIndex += 1
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\\p{L}\\p{N} ]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func srtTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMS = Int((clamped * 1000).rounded())
        let hours = totalMS / 3_600_000
        let minutes = (totalMS % 3_600_000) / 60_000
        let secs = (totalMS % 60_000) / 1_000
        let millis = totalMS % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}

// MARK: - Frame Change Detector

final class FrameChangeDetector: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let width = 32
    private let height = 18
    private var previous: [UInt8]?

    func difference(for pixelBuffer: CVPixelBuffer) -> Double {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        guard source.extent.width > 0, source.extent.height > 0 else { return 1.0 }

        let sx = CGFloat(width) / source.extent.width
        let sy = CGFloat(height) / source.extent.height
        let thumbnail = source.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            context.render(
                thumbnail,
                toBitmap: base,
                rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }

        guard let previous else {
            self.previous = bytes
            return 1.0
        }

        var total = 0
        var count = 0
        var index = 0
        while index < bytes.count {
            total += abs(Int(bytes[index]) - Int(previous[index]))
            total += abs(Int(bytes[index + 1]) - Int(previous[index + 1]))
            total += abs(Int(bytes[index + 2]) - Int(previous[index + 2]))
            count += 3
            index += 4
        }

        self.previous = bytes
        return Double(total) / Double(max(1, count) * 255)
    }
}

// MARK: - Observable Recorder Service

final class RecorderService: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @Published var isRecording = false
    @Published var statusMessage = "Ready to record"
    @Published var liveEvents: [OCREvent] = []
    @Published var options = RecordingOptions()
    @Published var currentSessionFolder: URL?

    private let captureQueue = DispatchQueue(label: "speedocr.capture", qos: .userInteractive)
    private let ocrQueue = DispatchQueue(label: "speedocr.ocr", qos: .userInitiated)

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sidecar: SidecarWriter?
    private var apiServer: LocalAPIServer?

    private var writerStarted = false
    private var firstPTS: CMTime?
    private var lastPTS: CMTime = .zero
    private var lastOCRWallTime: CFAbsoluteTime = 0
    private var lastForcedOCRWallTime: CFAbsoluteTime = 0
    private var ocrInFlight = false
    private var lastAcceptedNormalizedText = ""

    private let changeDetector = FrameChangeDetector()
    private let trajectoryTracker = TrajectoryTracker()
    private let scaler = ImageScaler()
    private let dateFormatter = ISO8601DateFormatter()

    override init() {
        super.init()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        apiServer = LocalAPIServer(service: self)
        apiServer?.start()
    }

    @MainActor
    func startRecording() async {
        guard !isRecording else { return }

        do {
            liveEvents.removeAll()
            writerStarted = false
            firstPTS = nil
            lastPTS = .zero
            lastOCRWallTime = 0
            lastForcedOCRWallTime = 0
            ocrInFlight = false
            lastAcceptedNormalizedText = ""

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else {
                statusMessage = "Error: No screen displays found."
                return
            }

            let display = content.displays[min(options.displayIndex, content.displays.count - 1)]
            var width = even(Int(CGDisplayPixelsWide(display.displayID)))
            var height = even(Int(CGDisplayPixelsHigh(display.displayID)))

            if let reg = options.region {
                width = even(Int(reg.width))
                height = even(Int(reg.height))
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let folderName = "SpeedOCR-\(formatter.string(from: Date()))"
            let moviesBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
            let directory = moviesBase.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            currentSessionFolder = directory

            sidecar = try SidecarWriter(directory: directory)

            let videoURL = directory.appendingPathComponent("capture.mp4")
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)

            let bitrate = min(40_000_000, max(8_000_000, Int(Double(width * height * options.fps) * 0.07)))
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: options.fps,
                    AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]

            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(vInput) else {
                statusMessage = "Error: Could not configure video output."
                return
            }
            writer.add(vInput)
            videoInput = vInput

            if options.captureAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = true
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    audioInput = aInput
                }
            }

            assetWriter = writer

            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
            configuration.queueDepth = 8
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = true
            configuration.capturesAudio = options.captureAudio
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            if let region = options.region {
                configuration.sourceRect = region
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            if options.captureAudio {
                try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            }
            self.stream = scStream
            try await scStream.startCapture()

            isRecording = true
            statusMessage = "Recording active (\(width)x\(height) @ \(options.fps)fps)"
        } catch {
            statusMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func stopRecording() async {
        guard isRecording else { return }
        statusMessage = "Finalizing session..."

        if let stream = self.stream {
            try? await stream.stopCapture()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            captureQueue.async {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()

                let finalElapsed: Double
                if let firstPTS = self.firstPTS {
                    finalElapsed = max(0, CMTimeGetSeconds(CMTimeSubtract(self.lastPTS, firstPTS)))
                } else {
                    finalElapsed = 0
                }

                try? self.sidecar?.finish(finalElapsed: finalElapsed)

                guard let writer = self.assetWriter, self.writerStarted else {
                    continuation.resume()
                    return
                }

                writer.finishWriting {
                    continuation.resume()
                }
            }
        }

        isRecording = false
        if let folder = currentSessionFolder {
            statusMessage = "Saved to: \(folder.lastPathComponent)"
        } else {
            statusMessage = "Recording stopped."
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .screen:
            processVideo(sampleBuffer)
        case .audio:
            processAudio(sampleBuffer)
        default:
            break
        }
    }

    nonisolated private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isCompleteFrame(sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp
        self.lastPTS = pts

        if !writerStarted {
            guard let writer = assetWriter, writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            writerStarted = true
            firstPTS = pts
        }

        if videoInput?.isReadyForMoreMediaData == true {
            videoInput?.append(sampleBuffer)
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer, let firstPTS else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = 1.0 / options.ocrFPS
        guard !ocrInFlight, now - lastOCRWallTime >= minInterval else { return }

        let change = changeDetector.difference(for: pixelBuffer)
        let force = now - lastForcedOCRWallTime >= options.forceOCRInterval

        let elapsed = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS)))
        let ptsSeconds = CMTimeGetSeconds(pts)
        let wallClock = dateFormatter.string(from: Date())

        let candidate = FrameCandidate(pixelBuffer: pixelBuffer, pts: pts, elapsed: elapsed, ptsSeconds: ptsSeconds, wallClock: wallClock, visualChange: change, sharpnessScore: change)

        let selectedCandidate: FrameCandidate?
        if options.enableTrajectorySelection && !force {
            selectedCandidate = trajectoryTracker.processFrame(candidate: candidate, threshold: options.changeThreshold)
        } else {
            selectedCandidate = (force || change >= options.changeThreshold) ? candidate : nil
        }

        guard let targetFrame = selectedCandidate else { return }

        lastOCRWallTime = now
        if force { lastForcedOCRWallTime = now }
        ocrInFlight = true

        let (scaledBuffer, scaleFactor) = scaler.upscaleIfNeeded(targetFrame.pixelBuffer)

        let frameElapsed = targetFrame.elapsed
        let framePTS = targetFrame.ptsSeconds
        let frameClock = targetFrame.wallClock
        let frameChange = targetFrame.visualChange

        ocrQueue.async {
            let event = self.recognizeHighRecall(pixelBuffer: scaledBuffer, elapsed: frameElapsed, ptsSeconds: framePTS, wallClock: frameClock, visualChange: frameChange, scaleFactor: scaleFactor)

            self.captureQueue.async {
                defer { self.ocrInFlight = false }
                guard let event else { return }

                let normalized = self.normalizeBlock(event.text)
                guard !normalized.isEmpty else { return }

                let similarity = self.tokenJaccard(normalized, self.lastAcceptedNormalizedText)
                guard similarity < 0.97 else { return }

                self.lastAcceptedNormalizedText = normalized
                try? self.sidecar?.write(event)

                Task { @MainActor in
                    self.liveEvents.append(event)
                }
            }
        }
    }

    nonisolated private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard writerStarted, audioInput?.isReadyForMoreMediaData == true else { return }
        audioInput?.append(sampleBuffer)
    }

    // High-Recall Vision Recognition with Micro-Font Detection & Adaptive Line Grouping
    nonisolated private func recognizeHighRecall(pixelBuffer: CVPixelBuffer, elapsed: Double, ptsSeconds: Double, wallClock: String, visualChange: Double, scaleFactor: Double) -> OCREvent? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.001 // Ultra-low height to capture micro UI fonts & headers

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let results = request.results, !results.isEmpty else { return nil }

        // Adaptive Line Grouping: Group bounding boxes into visual lines top-to-bottom, left-to-right
        var rawBoxes: [(obs: VNRecognizedTextObservation, text: String, conf: Float)] = []
        for observation in results {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let clean = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            rawBoxes.append((observation, clean, candidate.confidence))
        }

        guard !rawBoxes.isEmpty else { return nil }

        // Sort top-to-bottom
        let sortedObs = rawBoxes.sorted { lhs, rhs in
            let yDelta = lhs.obs.boundingBox.midY - rhs.obs.boundingBox.midY
            if abs(yDelta) > 0.02 { return lhs.obs.boundingBox.midY > rhs.obs.boundingBox.midY }
            return lhs.obs.boundingBox.minX < rhs.obs.boundingBox.minX
        }

        var boxes: [OCRBox] = []
        for item in sortedObs {
            let obs = item.obs
            boxes.append(OCRBox(
                text: item.text,
                confidence: item.conf,
                x: Double(obs.boundingBox.origin.x),
                y: Double(obs.boundingBox.origin.y),
                width: Double(obs.boundingBox.size.width),
                height: Double(obs.boundingBox.size.height)
            ))
        }

        let fullText = boxes.map { $0.text }.joined(separator: "\n")
        return OCREvent(
            elapsedSeconds: elapsed,
            wallClockISO8601: wallClock,
            framePTSSeconds: ptsSeconds,
            visualChange: visualChange,
            text: fullText,
            boxes: boxes,
            passType: "accurate-high-recall",
            detectedRegionsCount: boxes.count,
            scaleFactor: scaleFactor
        )
    }

    nonisolated private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let rawStatus = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return true }
        return status == .complete
    }

    nonisolated private func normalizeBlock(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\\p{L}\\p{N} ]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private func tokenJaccard(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let left = Set(a.split(separator: " ").map(String.init))
        let right = Set(b.split(separator: " ").map(String.init))
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(union.count)
    }

    private func even(_ val: Int) -> Int { max(2, val - (val % 2)) }
}

// MARK: - Local HTTP API Server

final class LocalAPIServer: @unchecked Sendable {
    private var listener: NWListener?
    private unowned let service: RecorderService

    init(service: RecorderService) {
        self.service = service
    }

    func start(port: UInt16 = 8080) {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: .global(qos: .userInitiated))
        } catch {}
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }

            let path = request.split(separator: " ").dropFirst().first ?? "/"
            var bodyJSON = "{}"

            if path.hasPrefix("/api/status") {
                let status: [String: Any] = [
                    "app": "SpeedOCR Studio",
                    "status": self.service.statusMessage,
                    "isRecording": self.service.isRecording,
                    "fps": self.service.options.fps,
                    "eventCount": self.service.liveEvents.count,
                    "trajectorySelection": self.service.options.enableTrajectorySelection
                ]
                if let jsonData = try? JSONSerialization.data(withJSONObject: status), let jsonStr = String(data: jsonData, encoding: .utf8) {
                    bodyJSON = jsonStr
                }
            } else if path.hasPrefix("/api/events") {
                if let jsonData = try? JSONEncoder().encode(self.service.liveEvents), let jsonStr = String(data: jsonData, encoding: .utf8) {
                    bodyJSON = jsonStr
                }
            } else if path.hasPrefix("/api/latest") {
                if let last = self.service.liveEvents.last, let jsonData = try? JSONEncoder().encode(last), let jsonStr = String(data: jsonData, encoding: .utf8) {
                    bodyJSON = jsonStr
                }
            }

            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Access-Control-Allow-Origin: *\r
            Access-Control-Allow-Headers: *\r
            Content-Length: \(bodyJSON.utf8.count)\r
            Connection: close\r
            \r
            \(bodyJSON)
            """

            connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }
}

// MARK: - Screen Lasso Window & Overlay

final class LassoOverlayWindow: NSWindow {
    private var onSelection: ((CGRect) -> Void)?

    init(onSelection: @escaping (CGRect) -> Void) {
        self.onSelection = onSelection

        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        super.init(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)

        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .screenSaver
        self.ignoresMouseEvents = false

        let view = LassoView(frame: screenFrame) { [weak self] selectedRect in
            self?.orderOut(nil)
            onSelection(selectedRect)
        }
        self.contentView = view
    }
}

final class LassoView: NSView {
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var onComplete: (CGRect) -> Void

    init(frame: NSRect, onComplete: @escaping (CGRect) -> Void) {
        self.onComplete = onComplete
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        if let start = startPoint, let current = currentPoint {
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )

            let screenHeight = bounds.height
            let flippedY = screenHeight - rect.maxY
            let displayRect = CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)

            if rect.width > 20 && rect.height > 20 {
                onComplete(displayRect)
            }
        }
        startPoint = nil
        currentPoint = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).set()
        dirtyRect.fill()

        if let start = startPoint, let current = currentPoint {
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )

            NSColor.clear.set()
            rect.fill(using: .copy)

            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2.0
            NSColor.systemBlue.setStroke()
            path.stroke()

            let text = "\(Int(rect.width)) × \(Int(rect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.systemBlue
            ]
            let attrString = NSAttributedString(string: " \(text) ", attributes: attrs)
            attrString.draw(at: CGPoint(x: rect.origin.x, y: max(0, rect.origin.y - 20)))
        }
    }
}

// MARK: - SwiftUI Dashboard UI

struct SpeedOCRDashboard: View {
    @StateObject private var recorder = RecorderService()
    @State private var lassoWindow: LassoOverlayWindow?
    @State private var copiedBanner = false

    var body: some View {
        VStack(spacing: 0) {
            // Header / Controls Bar
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.green)
                        .frame(width: 10, height: 10)
                        .scaleEffect(recorder.isRecording ? 1.2 : 1.0)

                    Text(recorder.isRecording ? "RECORDING" : "READY")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(recorder.isRecording ? .red : .secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.06)))

                Button(action: {
                    Task {
                        if recorder.isRecording {
                            await recorder.stopRecording()
                        } else {
                            await recorder.startRecording()
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: recorder.isRecording ? "square.fill" : "record.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text(recorder.isRecording ? "Stop Recording" : "Start Recording")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(recorder.isRecording ? Color.red : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: triggerLasso) {
                    HStack(spacing: 6) {
                        Image(systemName: "crop")
                        if let reg = recorder.options.region {
                            Text("\(Int(reg.width))×\(Int(reg.height))")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                        } else {
                            Text("Select Region (Lasso)")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .disabled(recorder.isRecording)

                if recorder.options.region != nil {
                    Button(action: { recorder.options.region = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Toggle(isOn: $recorder.options.enableTrajectorySelection) {
                    Label("High-Recall Mode", systemImage: "text.viewfinder")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .disabled(recorder.isRecording)

                Toggle(isOn: $recorder.options.captureAudio) {
                    Label("Audio", systemImage: recorder.options.captureAudio ? "mic.fill" : "mic.slash")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .disabled(recorder.isRecording)

                Toggle(isOn: $recorder.options.accurateOCR) {
                    Label("Accurate", systemImage: "sparkles")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .disabled(recorder.isRecording)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Status message strip
            HStack {
                Text(recorder.statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                Text("⚡ Local API: http://127.0.0.1:8080/api/events")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))

                if copiedBanner {
                    Text("✓ Copied to clipboard!")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Main Content Area & Quick Copy Toolbar
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("QUICK COPY:")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)

                    Button("📋 Copy All Text") {
                        copyToClipboard(allText)
                    }

                    Button("📑 Copy Clean List") {
                        copyToClipboard(cleanTextLines)
                    }

                    Button("⏱️ Copy Latest") {
                        if let last = recorder.liveEvents.last {
                            copyToClipboard(last.text)
                        }
                    }

                    Spacer()

                    if let folder = recorder.currentSessionFolder {
                        Button("📂 Open Folder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.04))

                Divider()

                if recorder.liveEvents.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No text recorded yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Click 'Start Recording' and text on screen will automatically transcribe here in real-time.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(recorder.liveEvents) { event in
                                    OCREventRow(event: event) { text in
                                        copyToClipboard(text)
                                    }
                                    .id(event.id)
                                }
                            }
                            .padding(16)
                        }
                        .onChange(of: recorder.liveEvents.count) {
                            if let last = recorder.liveEvents.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 520)
    }

    private var allText: String {
        recorder.liveEvents.map { "[\(formatTime($0.elapsedSeconds))]\n\($0.text)" }.joined(separator: "\n\n")
    }

    private var cleanTextLines: String {
        var set = Set<String>()
        var result: [String] = []
        for e in recorder.liveEvents {
            let lines = e.text.split(separator: "\n").map(String.init)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !set.contains(trimmed.lowercased()) {
                    set.insert(trimmed.lowercased())
                    result.append(trimmed)
                }
            }
        }
        return result.joined(separator: "\n")
    }

    private func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copiedBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { copiedBanner = false }
        }
    }

    private func triggerLasso() {
        let win = LassoOverlayWindow { selectedRect in
            recorder.options.region = selectedRect
            recorder.statusMessage = "Selected lasso region: \(Int(selectedRect.width))×\(Int(selectedRect.height))"
        }
        lassoWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        let ms = Int((seconds - Double(total)) * 10)
        return String(format: "%02d:%02d.%d", m, s, ms)
    }
}

struct OCREventRow: View {
    let event: OCREvent
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formatTime(event.elapsedSeconds))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)

                Text(event.wallClockISO8601)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                if event.scaleFactor > 1.0 {
                    Text("\(String(format: "%.1fx", event.scaleFactor)) Upscaled")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.2))
                        .foregroundColor(.purple)
                        .cornerRadius(3)
                }

                Spacer()

                Button(action: { onCopy(event.text) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
            }

            Text(event.text)
                .font(.system(size: 13, design: .default))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        let ms = Int((seconds - Double(total)) * 10)
        return String(format: "%02d:%02d.%d", m, s, ms)
    }
}

// MARK: - Native App Entrypoint

@main
struct SpeedOCRApp: App {
    var body: some Scene {
        WindowGroup("SpeedOCR Studio — Screen & Text Recorder") {
            SpeedOCRDashboard()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
