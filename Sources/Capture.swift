import AppKit
import ScreenCaptureKit

/// Cattura un display con ScreenCaptureKit (cursore incluso) e consegna pixel buffer 4:2:0,
/// pronti sia per l'encoder H.264 sia per il JPEG.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    var fps: Int = 30
    var scale: CGFloat = 1.0

    private var stream: SCStream?
    private let frameQueue = DispatchQueue(label: "everywhere.capture", qos: .userInteractive)

    enum CaptureError: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "Schermo non trovato" }
    }

    func start(displayID: CGDirectDisplayID) async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixelScale = CGFloat(filter.pointPixelScale) * scale

        let config = SCStreamConfiguration()
        // H.264 richiede dimensioni pari.
        config.width = Int((CGFloat(display.width) * pixelScale).rounded()) & ~1
        config.height = Int((CGFloat(display.height) * pixelScale).rounded()) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = true
        config.queueDepth = 6

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit invia frame "idle" quando lo schermo non cambia: li ignoriamo.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onPixelBuffer?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if stream === self.stream { self.stream = nil }
        onStop?(error)
    }
}
