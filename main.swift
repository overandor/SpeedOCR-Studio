import Foundation
import ScreenCaptureKit
import AVFoundation
import Vision
import CoreImage
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO

// MARK: - CLI

struct Options {
    var fps: Int = 60
    var ocrFPS: Double = 6.0
    var displayIndex: Int = 0
    var accurateOCR: Bool = false
    var captureAudio: Bool = true
    var changeThreshold: Double = 0.018
    var forceOCRInterval: Double = 1.25
    var outputDirectory: URL?

    static func parse(_ args: [String]) throws -> Options {
        var result = Options()
        var i = 0

        func requireValue(_ flag: String) throws -> String {
            guard i + 1 < args.count else {
                throw CLIError.missingValue(flag)
            }
            i += 1
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--fps":
                let value = try requireValue(arg)
                guard let parsed = Int(value), (1...120).contains(parsed) else {
                    throw CLIError.invalidValue(arg, value)
                }
                result.fps = parsed

            case "--ocr-fps":
                let value = try requireValue(arg)
                guard let parsed = Double(value), parsed > 0, parsed <= 30 else {
                    throw CLIError.invalidValue(arg, value)
                }
                result.ocrFPS = parsed

            case "--display":
                let value = try requireValue(arg)
                guard let parsed = Int(value), parsed >= 0 else {
                    throw CLIError.invalidValue(arg, value)
                }
                result.displayIndex = parsed

            case "--accurate":
                result.accurateOCR = true

            case "--no-audio":
                result.captureAudio = false

            case "--change-threshold":
                let value = try requireValue(arg)
                guard let parsed = Double(value), parsed >= 0, parsed <= 1 else {
                    throw CLIError.invalidValue(arg, value)
                }
                result.changeThreshold = parsed

            case "--force-ocr-seconds":
                let value = try requireValue(arg)
                guard let parsed = Double(value), parsed >= 0.1 else {
                    throw CLIError.invalidValue(arg, value)
                }
                result.forceOCRInterval = parsed

            case "--output":
                let value = try requireValue(arg)
                result.outputDirectory = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)

            case "--help", "-h":
                print(Self.help)
                exit(0)

            default:
                throw CLIError.unknownFlag(arg)
            }
            i += 1
        }

        return result
    }

    static let help = """
    SpeedOCR Recorder — synchronized screen video + automatic OCR

    Usage:
      swift run -c release speedocr [options]

    Options:
      --fps N                    Video frame rate, 1...120 (default: 60)
      --ocr-fps N                Maximum OCR samples/second (default: 6)
      --display N                Display index (default: 0)
      --accurate                 Prefer OCR accuracy over throughput
      --no-audio                 Disable system-audio capture
      --change-threshold N       Visual-change threshold 0...1 (default: 0.018)
      --force-ocr-seconds N      OCR unchanged screen after N seconds (default: 1.25)
      --output PATH              Output directory
      -h, --help                 Show help

    Stop recording with Control-C.
    """
}

enum CLIError: LocalizedError {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownFlag(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value after \(flag)"
        case .invalidValue(let flag, let value):
            return "Invalid value for \(flag): \(value)"
        case .unknownFlag(let flag):
            return "Unknown option: \(flag). Use --help."
        }
    }
}

// MARK: - OCR records

struct OCRBox: Codable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCREvent: Codable {
    let elapsedSeconds: Double
    let wallClockISO8601: String
    let framePTSSeconds: Double
    let visualChange: Double
    let text: String
    let boxes: [OCRBox]
}

private struct OCRResult {
    let event: OCREvent
    let newTranscriptLines: [String]
}

// MARK: - Output writer

final class SidecarWriter {
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

// MARK: - Visual-change detector

final class FrameChangeDetector {
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

// MARK: - Recorder

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let options: Options
    private let captureQueue = DispatchQueue(label: "speedocr.capture", qos: .userInteractive)
    private let ocrQueue = DispatchQueue(label: "speedocr.ocr", qos: .userInitiated)

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sidecar: SidecarWriter?

    private var writerStarted = false
    private var firstPTS: CMTime?
    private var lastPTS: CMTime = .zero
    private var lastOCRWallTime: CFAbsoluteTime = 0
    private var lastForcedOCRWallTime: CFAbsoluteTime = 0
    private var ocrInFlight = false
    private var lastAcceptedNormalizedText = ""

    private let changeDetector = FrameChangeDetector()
    private let dateFormatter = ISO8601DateFormatter()
    private(set) var outputDirectory: URL?

    init(options: Options) {
        self.options = options
        super.init()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw RecorderError.noDisplays }
        guard content.displays.indices.contains(options.displayIndex) else { throw RecorderError.invalidDisplayIndex(options.displayIndex, content.displays.count) }

        let display = content.displays[options.displayIndex]
        let width = even(Int(CGDisplayPixelsWide(display.displayID)))
        let height = even(Int(CGDisplayPixelsHigh(display.displayID)))

        let directory = try makeOutputDirectory()
        outputDirectory = directory
        sidecar = try SidecarWriter(directory: directory)

        let videoURL = directory.appendingPathComponent("capture.mp4")
        assetWriter = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)

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
        guard assetWriter?.canAdd(vInput) == true else { throw RecorderError.cannotAddVideoInput }
        assetWriter?.add(vInput)
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
            if assetWriter?.canAdd(aInput) == true {
                assetWriter?.add(aInput)
                audioInput = aInput
            }
        }

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

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if options.captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        }
        self.stream = stream
        try await stream.startCapture()

        print("Recording display \(options.displayIndex) at \(width)x\(height), \(options.fps) fps")
        print("OCR: up to \(options.ocrFPS) samples/sec, \(options.accurateOCR ? "accurate" : "fast") mode")
        print("Output: \(directory.path)")
        print("Press Control-C to stop.")
    }

    func stop() async {
        if let stream {
            do { try await stream.stopCapture() } catch { fputs("Capture stop warning: \(error.localizedDescription)\n", stderr) }
        }
        await withCheckedContinuation { continuation in
            captureQueue.async {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()

                let finalElapsed: Double
                if let firstPTS = self.firstPTS {
                    finalElapsed = max(0, CMTimeGetSeconds(CMTimeSubtract(self.lastPTS, firstPTS)))
                } else { finalElapsed = 0 }

                do { try self.sidecar?.finish(finalElapsed: finalElapsed) } catch { fputs("Sidecar close warning: \(error.localizedDescription)\n", stderr) }

                guard let writer = self.assetWriter, self.writerStarted else { continuation.resume(); return }
                writer.finishWriting {
                    if writer.status == .failed { fputs("Video writer failed: \(writer.error?.localizedDescription ?? "unknown error")\n", stderr) }
                    continuation.resume()
                }
            }
        }

        if let outputDirectory {
            print("\nFinished.")
            print("Video:      \(outputDirectory.appendingPathComponent("capture.mp4").path)")
            print("OCR events: \(outputDirectory.appendingPathComponent("ocr.jsonl").path)")
            print("Transcript: \(outputDirectory.appendingPathComponent("transcript.txt").path)")
            print("Captions:   \(outputDirectory.appendingPathComponent("ocr.srt").path)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { fputs("ScreenCaptureKit stopped: \(error.localizedDescription)\n", stderr) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .screen: processVideo(sampleBuffer)
        case .audio: processAudio(sampleBuffer)
        @unknown default: break
        }
    }

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isCompleteFrame(sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp
        lastPTS = pts
        if !writerStarted {
            guard let writer = assetWriter, writer.startWriting() else { fputs("Unable to start video writer: \(assetWriter?.error?.localizedDescription ?? "unknown")\n", stderr); return }
            writer.startSession(atSourceTime: pts)
            writerStarted = true
            firstPTS = pts
        }
        if videoInput?.isReadyForMoreMediaData == true {
            if videoInput?.append(sampleBuffer) == false {
                fputs("Dropped video sample: \(assetWriter?.error?.localizedDescription ?? "append failed")\n", stderr)
            }
        }
        guard let pixelBuffer = sampleBuffer.imageBuffer, let firstPTS else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = 1.0 / options.ocrFPS
        guard !ocrInFlight, now - lastOCRWallTime >= minInterval else { return }
        let change = changeDetector.difference(for: pixelBuffer)
        let force = now - lastForcedOCRWallTime >= options.forceOCRInterval
        guard force || change >= options.changeThreshold else { return }
        lastOCRWallTime = now
        if force { lastForcedOCRWallTime = now }
        ocrInFlight = true
        let elapsed = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS)))
        let ptsSeconds = CMTimeGetSeconds(pts)
        let wallClock = dateFormatter.string(from: Date())
        let retainedPixelBuffer = pixelBuffer
        ocrQueue.async {
            let event = self.recognize(pixelBuffer: retainedPixelBuffer, elapsed: elapsed, ptsSeconds: ptsSeconds, wallClock: wallClock, visualChange: change)
            self.captureQueue.async {
                defer { self.ocrInFlight = false }
                guard let event else { return }
                let normalized = self.normalizeBlock(event.text)
                guard !normalized.isEmpty else { return }
                let similarity = self.tokenJaccard(normalized, self.lastAcceptedNormalizedText)
                guard similarity < 0.97 else { return }
                self.lastAcceptedNormalizedText = normalized
                do { try self.sidecar?.write(event) } catch { fputs("OCR sidecar write failed: \(error.localizedDescription)\n", stderr) }
            }
        }
    }

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard writerStarted, audioInput?.isReadyForMoreMediaData == true else { return }
        if audioInput?.append(sampleBuffer) == false {
            fputs("Dropped audio sample: \(assetWriter?.error?.localizedDescription ?? "append failed")\n", stderr)
        }
    }

    private func recognize(pixelBuffer: CVPixelBuffer, elapsed: Double, ptsSeconds: Double, wallClock: String, visualChange: Double) -> OCREvent? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.accurateOCR ? .accurate : .fast
        request.usesLanguageCorrection = options.accurateOCR
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.006
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { fputs("OCR failed: \(error.localizedDescription)\n", stderr); return nil }
        let observations = (request.results ?? []).sorted { lhs, rhs in
            let yDelta = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(yDelta) > 0.015 { return lhs.boundingBox.midY > rhs.boundingBox.midY }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        var boxes: [OCRBox] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let clean = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            boxes.append(OCRBox(text: clean, confidence: candidate.confidence, x: observation.boundingBox.origin.x, y: observation.boundingBox.origin.y, width: observation.boundingBox.size.width, height: observation.boundingBox.size.height))
        }
        guard !boxes.isEmpty else { return nil }
        let text = boxes.map { $0.text }.joined(separator: "\n")
        return OCREvent(elapsedSeconds: elapsed, wallClockISO8601: wallClock, framePTSSeconds: ptsSeconds, visualChange: visualChange, text: text, boxes: boxes)
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let first = attachments.first, let rawStatus = first[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) else { return true }
        return status == .complete
    }

    private func normalizeBlock(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\\p{L}\\p{N} ]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenJaccard(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let left = Set(a.split(separator: " ").map(String.init))
        let right = Set(b.split(separator: " ").map(String.init))
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(union.count)
    }

    private func makeOutputDirectory() throws -> URL {
        if let out = options.outputDirectory {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            return out
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = "SpeedOCR-\(formatter.string(from: Date()))"
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        let directory = base.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func even(_ value: Int) -> Int { max(2, value - (value % 2)) }
}

enum RecorderError: LocalizedError {
    case noDisplays
    case invalidDisplayIndex(Int, Int)
    case cannotAddVideoInput
    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No capturable display was found."
        case .invalidDisplayIndex(let requested, let count): return "Display index \(requested) is invalid; \(count) display(s) are available."
        case .cannotAddVideoInput: return "AVAssetWriter rejected the video input."
        }
    }
}

// MARK: - Main

@main
struct SpeedOCRRecorderMain {
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let recorder = Recorder(options: options)
            try await recorder.start()
            let stopped = DispatchSemaphore(value: 0)
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
            let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
            let stopOnce = NSLock()
            var stopping = false
            let stopHandler = {
                stopOnce.lock()
                if stopping { stopOnce.unlock(); return }
                stopping = true
                stopOnce.unlock()
                Task { await recorder.stop(); stopped.signal() }
            }
            sigint.setEventHandler(handler: stopHandler)
            sigterm.setEventHandler(handler: stopHandler)
            sigint.resume()
            sigterm.resume()
            stopped.wait()
        } catch {
            fputs("Error: \(error.localizedDescription)\n\n", stderr)
            fputs(Options.help + "\n", stderr)
            exit(1)
        }
    }
}
