import CoreMedia
import Foundation
import VideoToolbox

struct EncodedFrame {
    /// NAL unit con prefisso di lunghezza a 4 byte (formato AVCC, come vuole l'MP4).
    let data: Data
    let isKey: Bool
    let sps: Data
    let pps: Data
    let width: Int
    let height: Int

    /// Codec string per MSE, es. "avc1.640033".
    var codec: String {
        let b = [UInt8](sps)
        guard b.count >= 4 else { return "avc1.640033" }
        return String(format: "avc1.%02x%02x%02x", b[1], b[2], b[3])
    }
}

/// Encoder H.264 hardware in modalità a bassa latenza (niente B-frame).
/// `encode` va chiamato sempre dalla stessa coda seriale.
final class H264Encoder {
    var onFrame: ((EncodedFrame) -> Void)?
    var fps = 30
    /// Bit al secondo per un'area di riferimento di 2160×1620 pixel; scalato sulla risoluzione reale.
    var referenceBitrate = 6_000_000

    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var configuredFPS = 0
    private var configuredBitrate = 0
    private let lock = NSLock()
    private var forceKeyframe = true

    /// La prima sessione hardware del processo costa ~0,6 s (le successive ~50 ms): la si crea
    /// in background all'avvio, così il primo tablet che si collega non aspetta.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let encoder = H264Encoder()
            var pb: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb)
            guard let pb else { return }
            encoder.encode(pb, pts: .zero)
            if let session = encoder.session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
            encoder.invalidate()
        }
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || w != width || h != height || fps != configuredFPS {
            makeSession(width: w, height: h)
        }
        guard let session else { return }
        let bitrate = targetBitrate()
        if bitrate != configuredBitrate {
            setBitrate(session, bitrate)
        }

        lock.lock()
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.output(sample)
        }
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    deinit { invalidate() }

    private func targetBitrate() -> Int {
        let area = Double(width * height) / (2160.0 * 1620.0)
        return Int(Double(referenceBitrate) * min(max(area, 0.4), 2.0))
    }

    private func makeSession(width w: Int, height h: Int) {
        invalidate()
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let s = created else { return }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel) != noErr {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 10 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)

        session = s
        width = w
        height = h
        configuredFPS = fps
        setBitrate(s, targetBitrate())
        requestKeyframe()
    }

    private func setBitrate(_ s: VTCompressionSession, _ bitrate: Int) {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        configuredBitrate = bitrate
    }

    private func output(_ sample: CMSampleBuffer) {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false

        func parameterSet(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                             parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                             parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = parameterSet(0), let pps = parameterSet(1) else { return }

        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        let dims = CMVideoFormatDescriptionGetDimensions(format)
        onFrame?(EncodedFrame(data: data, isKey: !notSync, sps: sps, pps: pps,
                              width: Int(dims.width), height: Int(dims.height)))
    }
}
