import CoreGraphics
import Foundation
import NarratorCore
@preconcurrency import ScreenCaptureKit
import Vision
import ImageIO
import UniformTypeIdentifiers

actor ScreenText {
    enum Failure: Error { case windowUnavailable, grayscaleImage }
    private struct Cached {
        let hash: UInt64
        let lines: [TextLine]
    }
    private var cache: [CGWindowID: Cached] = [:]

    func read(pid: Int32, title: String?, frame: CGRect) async throws -> [TextLine] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame == frame
                && (title == nil || $0.title == title)
        }) else { throw Failure.windowUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let pixelWidth = frame.width * CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int(min(1280, pixelWidth)))
        configuration.height = max(1, Int(CGFloat(configuration.width) * frame.height / frame.width))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let hash = TextGeometry.dHash(try grayscaleSamples(image))
        let normalizedLines: [TextLine]
        if let previous = cache[window.windowID], previous.hash == hash {
            normalizedLines = previous.lines
        } else {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans", "en"]
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            normalizedLines = (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let trimmed = TextGeometry.trimmedText(text).text
                return trimmed.isEmpty ? nil : TextLine(text: trimmed, rect: observation.boundingBox)
            }
            try Task.checkCancellation()
            cache[window.windowID] = Cached(hash: hash, lines: normalizedLines)
        }
        let lines = normalizedLines.map { TextLine(text: $0.text, rect: TextGeometry.screenRect($0.rect, in: frame)) }
        return TextGeometry.sortedIndices(lines).map { lines[$0] }
    }

    func windowImage(windowID: UInt32, frame: CGRect, redactions: [CGRect]) async throws -> Data {
        let window = try await availableWindow(windowID, frame: frame)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(CGFloat(filter.pointPixelScale), 1280 / max(frame.width, frame.height))
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
        catch {
            _ = try await availableWindow(windowID, frame: frame)
            throw error
        }
        _ = try await availableWindow(windowID, frame: frame)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WindowImageError.encodingFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let sx = CGFloat(image.width) / frame.width, sy = CGFloat(image.height) / frame.height
        for rect in redactions {
            context.fill(CGRect(x: (rect.minX - frame.minX) * sx, y: (frame.maxY - rect.maxY) * sy,
                width: rect.width * sx, height: rect.height * sy).integral)
        }
        let data = NSMutableData()
        guard let masked = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw WindowImageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, masked, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WindowImageError.encodingFailed }
        return data as Data
    }

    private func availableWindow(_ windowID: UInt32, frame: CGRect) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let window = content.windows.first(where: { $0.windowID == windowID && $0.frame == frame }) else {
            throw WindowImageError.windowUnavailable
        }
        return window
    }

    private func grayscaleSamples(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                          bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw Failure.grayscaleImage }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        }
        return pixels
    }
}
