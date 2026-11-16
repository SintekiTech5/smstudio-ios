import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox
import Darwin

enum RemoteCameraNodeError: LocalizedError {
    case cameraPermissionDenied
    case cameraUnavailable
    case unsupportedVideoFormat
    case cameraConfiguration(String)
    case captureSession(String)
    case encoderCreation(OSStatus)
    case encoderConfiguration(OSStatus)
    case encoderNotHardwareAccelerated
    case effectsProcessing
    case encoding(OSStatus)
    case malformedEncodedSample
    case malformedNALUnit
    case serviceResolution(String)
    case serviceAddressUnavailable
    case invalidPairingCode

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied:
            return "Camera access was denied. Allow camera access in Settings to stream video."
        case .cameraUnavailable:
            return "No rear-facing camera is available."
        case .unsupportedVideoFormat:
            return "The rear camera does not support 1920x1080 capture at 30 fps."
        case .cameraConfiguration(let message):
            return "Camera configuration failed: \(message)"
        case .captureSession(let message):
            return "Capture session failed: \(message)"
        case .encoderCreation(let status):
            return "Unable to create the H.264 encoder (OSStatus \(status))."
        case .encoderConfiguration(let status):
            return "Unable to configure the H.264 encoder (OSStatus \(status))."
        case .encoderNotHardwareAccelerated:
            return "VideoToolbox did not create a hardware-accelerated H.264 encoder."
        case .effectsProcessing:
            return "The camera effects pipeline could not allocate an output frame."
        case .encoding(let status):
            return "H.264 encoding failed (OSStatus \(status))."
        case .malformedEncodedSample:
            return "VideoToolbox returned an invalid encoded sample."
        case .malformedNALUnit:
            return "VideoToolbox returned a malformed H.264 NAL unit."
        case .serviceResolution(let message):
            return "Bonjour service resolution failed: \(message)"
        case .serviceAddressUnavailable:
            return "The discovered Bonjour service did not provide a usable IP address."
        case .invalidPairingCode:
            return "Enter the six-digit pairing code shown on the Master Hub."
        }
    }
}

struct EncodedAccessUnit {
    let nalUnits: [Data]
    let isKeyFrame: Bool

    var annexBData: Data {
        var result = Data()
        for nal in nalUnits {
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(nal)
        }
        return result
    }
}

protocol RemoteCameraNodeDelegate: AnyObject {
    func remoteCameraNode(_ node: RemoteCameraNode, didChangeState state: RemoteCameraNode.State)
    func remoteCameraNode(_ node: RemoteCameraNode, didFail error: Error)
    func remoteCameraNode(_ node: RemoteCameraNode, didProduce accessUnit: EncodedAccessUnit)
}

private final class CompressionCallbackContext {
    weak var node: RemoteCameraNode?

    init(node: RemoteCameraNode) {
        self.node = node
    }
}

extension RemoteCameraNodeDelegate {
    func remoteCameraNode(_ node: RemoteCameraNode, didChangeState state: RemoteCameraNode.State) {}
    func remoteCameraNode(_ node: RemoteCameraNode, didFail error: Error) {}
    func remoteCameraNode(_ node: RemoteCameraNode, didProduce accessUnit: EncodedAccessUnit) {}
}

final class RemoteCameraNode: NSObject {
    enum State: Equatable {
        case stopped
        case requestingPermission
        case searching
        case connecting
        case streaming
    }

    static let serviceType = "_multicam-srt._tcp."

    weak var delegate: RemoteCameraNodeDelegate?

    private let captureQueue = DispatchQueue(label: "com.multicam.remote-camera.capture")
    private let captureQueueKey = DispatchSpecificKey<Void>()
    private let deliveryQueue = DispatchQueue.main
    private let transport = SRTTransport()
    private let effects = RemoteCameraEffects(width: 1920, height: 1080)
    private let stateLock = NSLock()
    private var storedState: State = .stopped
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var compressionSession: VTCompressionSession?
    private var compressionCallbackContext: UnsafeMutableRawPointer?
    private var browser: NetServiceBrowser?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var isStopping = false
    private var pairingCode = ""
    private var srtPassphrase = ""

    var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedState
    }

    override init() {
        super.init()
        captureQueue.setSpecific(key: captureQueueKey, value: ())
        transport.onError = { [weak self] error in
            guard let self else { return }
            self.report(error)
            if let transportError = error as? SRTTransportError {
                switch transportError {
                case .send, .notConnected:
                    if self.state != .stopped {
                        self.setState(.searching)
                    }
                case .invalidAddress, .connection, .backpressure:
                    break
                }
            }
        }
    }

    deinit {
        let browser = self.browser
        let cleanup = {
            self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            self.captureSession?.stopRunning()
            self.captureSession = nil
            self.videoOutput = nil
            self.invalidateEncoder()
            self.transport.disconnect()
        }
        if DispatchQueue.getSpecific(key: captureQueueKey) != nil {
            cleanup()
        } else {
            captureQueue.sync(execute: cleanup)
        }
        if let browser {
            DispatchQueue.main.async {
                browser.stop()
                browser.delegate = nil
            }
        }
    }

    func start(pairingCode: String) {
        guard pairingCode.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else {
            report(RemoteCameraNodeError.invalidPairingCode)
            return
        }
        captureQueue.async { [weak self] in
            guard let self, self.state == .stopped else { return }
            self.isStopping = false
            self.pairingCode = pairingCode
            self.srtPassphrase = Self.srtPassphrase(for: pairingCode)
            self.setState(.requestingPermission)
            self.requestCameraPermission()
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            DispatchQueue.main.async {
                self.browser?.stop()
                self.browser?.delegate = nil
                self.browser = nil
                self.services.removeAll()
            }

            func updateEffects(_ settings: RemoteCameraEffectsSettings) {
                effects.update(settings)
            }
            self.captureSession?.stopRunning()
            self.captureSession = nil
            self.videoOutput = nil
            self.invalidateEncoder()
            self.transport.disconnect()
            self.setState(.stopped)
        }
    }

    private func requestCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if configureCaptureAndEncoder() { beginBonjourSearch() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.captureQueue.async {
                    guard !self.isStopping else { return }
                    guard granted else {
                        self.setState(.stopped)
                        self.report(RemoteCameraNodeError.cameraPermissionDenied)
                        return
                    }
                    if self.configureCaptureAndEncoder() { self.beginBonjourSearch() }
                }
            }
        case .denied, .restricted:
            setState(.stopped)
            report(RemoteCameraNodeError.cameraPermissionDenied)
        @unknown default:
            setState(.stopped)
            report(RemoteCameraNodeError.cameraPermissionDenied)
        }
    }

    @discardableResult
    private func configureCaptureAndEncoder() -> Bool {
        guard !isStopping else { return false }

        do {
            let deviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInWideAngleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera
            ]
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: deviceTypes,
                mediaType: .video,
                position: .back
            )
            guard let device = discovery.devices.first(where: { $0.position == .back }) else {
                throw RemoteCameraNodeError.cameraUnavailable
            }

            guard let format = device.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let supports1080p = dimensions.width == 1920 && dimensions.height == 1080
                let supports30FPS = format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                }
                return supports1080p && supports30FPS
            }) else {
                throw RemoteCameraNodeError.unsupportedVideoFormat
            }

            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            device.unlockForConfiguration()

            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .inputPriority

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw RemoteCameraNodeError.cameraConfiguration("The camera input could not be added.")
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            output.alwaysDiscardsLateVideoFrames = true
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw RemoteCameraNodeError.cameraConfiguration("The video output could not be added.")
            }
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: captureQueue)
            session.commitConfiguration()

            try createEncoder()
            captureSession = session
            videoOutput = output
            session.startRunning()
            guard session.isRunning else {
                throw RemoteCameraNodeError.captureSession("The capture session did not start.")
            }
            return true
        } catch let error as RemoteCameraNodeError {
            captureSession?.stopRunning()
            captureSession = nil
            videoOutput = nil
            invalidateEncoder()
            report(error)
            setState(.stopped)
            return false
        } catch {
            captureSession?.stopRunning()
            captureSession = nil
            videoOutput = nil
            invalidateEncoder()
            report(RemoteCameraNodeError.cameraConfiguration(error.localizedDescription))
            setState(.stopped)
            return false
        }
    }

    private func createEncoder() throws {
        var session: VTCompressionSession?
        let callbackContext = Unmanaged.passRetained(CompressionCallbackContext(node: self))
        let callbackPointer = callbackContext.toOpaque()
        var callbackContextTransferred = false
        defer {
            if !callbackContextTransferred {
                callbackContext.release()
            }
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: 1920,
            kCVPixelBufferHeightKey: 1080,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: attributes as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: RemoteCameraNode.compressionOutputCallback,
            refcon: callbackPointer,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw RemoteCameraNodeError.encoderCreation(status)
        }

        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 4_000_000)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 30)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 30)),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        ]
        for (key, value) in properties {
            let propertyStatus = VTSessionSetProperty(session, key: key, value: value)
            guard propertyStatus == noErr else {
                VTCompressionSessionInvalidate(session)
                throw RemoteCameraNodeError.encoderConfiguration(propertyStatus)
            }
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw RemoteCameraNodeError.encoderConfiguration(prepareStatus)
        }

        var usingHardware: CFTypeRef?
        let hardwareStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &usingHardware
        )
        guard hardwareStatus == noErr, (usingHardware as? NSNumber)?.boolValue == true else {
            VTCompressionSessionInvalidate(session)
            throw RemoteCameraNodeError.encoderNotHardwareAccelerated
        }
        compressionSession = session
        compressionCallbackContext = callbackPointer
        callbackContextTransferred = true
    }

    private func beginBonjourSearch() {
        guard !isStopping else { return }
        setState(.searching)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != .stopped else { return }
            let serviceBrowser = NetServiceBrowser()
            serviceBrowser.delegate = self
            serviceBrowser.includesPeerToPeer = false
            serviceBrowser.schedule(in: .main, forMode: .common)
            self.browser = serviceBrowser
            serviceBrowser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        }
    }

    private func invalidateEncoder() {
        guard let session = compressionSession else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        compressionSession = nil
        if let callbackContext = compressionCallbackContext {
            Unmanaged<CompressionCallbackContext>.fromOpaque(callbackContext).release()
            compressionCallbackContext = nil
        }
    }

    private func encode(_ sampleBuffer: CMSampleBuffer) {
        guard !isStopping,
              let session = compressionSession,
              let capturedBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let imageBuffer = effects.process(capturedBuffer) else {
            report(RemoteCameraNodeError.effectsProcessing)
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration.isValid ? duration : CMTime(value: 1, timescale: 30),
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            report(RemoteCameraNodeError.encoding(status))
        }
    }

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            report(RemoteCameraNodeError.malformedEncodedSample)
            return
        }

        let notSync = (CMGetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_NotSync,
            attachmentModeOut: nil
        ) as? NSNumber)?.boolValue ?? false
        let isKeyFrame = !notSync
        var nals: [Data] = []
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let formatStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard formatStatus == noErr,
              (1...4).contains(nalUnitHeaderLength),
              parameterSetCount >= 2 else {
            report(RemoteCameraNodeError.malformedEncodedSample)
            return
        }

        if isKeyFrame {
            for index in 0..<parameterSetCount {
                var parameterSetPointer: UnsafePointer<UInt8>?
                var parameterSetSize = 0
                let parameterStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &parameterSetPointer,
                    parameterSetSizeOut: &parameterSetSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard parameterStatus == noErr,
                      let parameterSetPointer,
                      parameterSetSize > 0 else {
                    report(RemoteCameraNodeError.malformedEncodedSample)
                    return
                }
                nals.append(Data(bytes: parameterSetPointer, count: parameterSetSize))
            }
        }

        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else {
            report(RemoteCameraNodeError.malformedEncodedSample)
            return
        }
        var bytes = [UInt8](repeating: 0, count: totalLength)
        let copyStatus = bytes.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: buffer.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            report(RemoteCameraNodeError.malformedEncodedSample)
            return
        }

        var offset = 0
        let lengthFieldSize = Int(nalUnitHeaderLength)
        while offset < bytes.count {
            guard bytes.count - offset >= lengthFieldSize else {
                report(RemoteCameraNodeError.malformedNALUnit)
                return
            }
            var nalLength: UInt32 = 0
            for index in 0..<lengthFieldSize {
                nalLength = (nalLength << 8) | UInt32(bytes[offset + index])
            }
            offset += lengthFieldSize
            guard nalLength > 0, nalLength <= UInt32(bytes.count - offset) else {
                report(RemoteCameraNodeError.malformedNALUnit)
                return
            }
            nals.append(Data(bytes[offset..<(offset + Int(nalLength))]))
            offset += Int(nalLength)
        }

        guard !nals.isEmpty else {
            report(RemoteCameraNodeError.malformedEncodedSample)
            return
        }
        let accessUnit = EncodedAccessUnit(nalUnits: nals, isKeyFrame: isKeyFrame)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationTimeUs = CMTimeConvertScale(
            presentationTime, timescale: 1_000_000, method: .default
        )
        guard presentationTimeUs.isValid, presentationTimeUs.value >= 0 else {
            report(RemoteCameraNodeError.malformedEncodedSample)
            return
        }
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.remoteCameraNode(self, didProduce: accessUnit)
        }
        transport.sendVideo(
            accessUnit.annexBData,
            width: 1920,
            height: 1080,
            presentationTimeUs: UInt64(presentationTimeUs.value)
        )
    }

    private static func srtPassphrase(for pairingCode: String) -> String {
        let digest = SHA256.hash(data: Data("SMSTUDIO-SRT-v1:\(pairingCode)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func resolvedAddress(for service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for addressData in addresses {
            let host = addressData.withUnsafeBytes { rawBuffer -> String? in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    baseAddress.assumingMemoryBound(to: sockaddr.self),
                    socklen_t(addressData.count),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                return result == 0 ? String(cString: hostBuffer) : nil
            }
            if let host { return host }
        }
        return nil
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        storedState = newState
        stateLock.unlock()
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.remoteCameraNode(self, didChangeState: newState)
        }
    }

    private func report(_ error: Error) {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.remoteCameraNode(self, didFail: error)
        }
    }

    private static let compressionOutputCallback: VTCompressionOutputCallback = {
        outputRefcon, _, status, _, sampleBuffer in
        guard let outputRefcon else { return }
        let context = Unmanaged<CompressionCallbackContext>.fromOpaque(outputRefcon).takeUnretainedValue()
        guard let node = context.node else { return }
        guard status == noErr, let sampleBuffer else {
            if status != noErr {
                node.report(RemoteCameraNodeError.encoding(status))
            }
            return
        }
        node.handleEncodedSample(sampleBuffer)
    }
}

extension RemoteCameraNode: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        encode(sampleBuffer)
    }
}

extension RemoteCameraNode: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard state != .stopped,
              service.name == "\(pairingCode)-SMSTUDIO" else { return }
        service.delegate = self
        services[ObjectIdentifier(service)] = service
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        services.removeValue(forKey: ObjectIdentifier(service))
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        report(RemoteCameraNodeError.serviceResolution(
            errorDict[NetService.errorCode]?.stringValue ?? "The Bonjour search could not start."
        ))
    }
}

extension RemoteCameraNode: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard state == .searching else {
            sender.stop()
            return
        }
        guard let host = resolvedAddress(for: sender), sender.port > 0 else {
            report(RemoteCameraNodeError.serviceAddressUnavailable)
            return
        }
        sender.stop()
        services.removeValue(forKey: ObjectIdentifier(sender))
        setState(.connecting)
        transport.connect(
            host: host,
            port: sender.port,
            passphrase: srtPassphrase
        ) { [weak self] error in
            guard let self, self.state != .stopped else { return }
            self.setState(error == nil ? .streaming : .searching)
        }
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        services.removeValue(forKey: ObjectIdentifier(sender))
        report(RemoteCameraNodeError.serviceResolution(
            errorDict[NetService.errorCode]?.stringValue ?? "The service could not be resolved."
        ))
    }
}
