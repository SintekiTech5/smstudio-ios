import Foundation

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}

enum SRTTransportError: LocalizedError {
    case invalidAddress
    case connection(String)
    case send(String)
    case notConnected
    case backpressure

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "The resolved service address is invalid."
        case .connection(let message):
            return "SRT connection failed: \(message)"
        case .send(let message):
            return "SRT send failed: \(message)"
        case .notConnected:
            return "The SRT transport is not connected."
        case .backpressure:
            return "The SRT send queue is full; an encoded video frame was dropped."
        }
    }
}

final class SRTTransport {
    private let queue = DispatchQueue(label: "com.multicam.remote-camera.srt")
    private let queueKey = DispatchSpecificKey<Void>()
    private let pendingLock = NSLock()
    private let maximumPendingFrames = 4
    private let maximumSrtMessageBytes = 1316
    private let fragmentHeaderBytes = 16
    private var nextFragmentSequence: UInt32 = 0
    private var socket: Int32 = -1
    private var hasReportedDisconnected = false
    private var pendingFrames = 0
    private var hasReportedBackpressure = false

    var onError: ((Error) -> Void)?

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func connect(
        host: String,
        port: Int,
        passphrase: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeSocket()

            guard port > 0, port <= Int(UInt16.max), !host.isEmpty,
                  passphrase.count >= 10, passphrase.count <= 79 else {
                let error = SRTTransportError.invalidAddress
                completion?(error)
                self.report(error)
                return
            }

            var newSocket: Int32 = -1
            var errorBuffer = [CChar](repeating: 0, count: 512)
            let result = host.withCString { hostPointer in
                passphrase.withCString { passphrasePointer in
                    errorBuffer.withUnsafeMutableBufferPointer { errorPointer in
                        rnc_srt_connect(
                            hostPointer,
                            UInt16(port),
                            passphrasePointer,
                            &newSocket,
                            errorPointer.baseAddress,
                            errorPointer.count
                        )
                    }
                }
            }

            guard result == 0 else {
                let message = String(cString: errorBuffer)
                let error = SRTTransportError.connection(message)
                completion?(error)
                self.report(error)
                return
            }
            self.socket = newSocket
            self.hasReportedDisconnected = false
            completion?(nil)
        }
    }

    func send(_ bytes: Data, completion: ((Error?) -> Void)? = nil) {
        pendingLock.lock()
        guard pendingFrames < maximumPendingFrames else {
            let shouldReport = !hasReportedBackpressure
            hasReportedBackpressure = true
            pendingLock.unlock()
            if shouldReport {
                report(SRTTransportError.backpressure)
            }
            completion?(SRTTransportError.backpressure)
            return
        }
        pendingFrames += 1
        pendingLock.unlock()

        queue.async { [weak self] in
            guard let self else {
                completion?(SRTTransportError.notConnected)
                return
            }
            defer {
                self.pendingLock.lock()
                self.pendingFrames -= 1
                if self.pendingFrames < self.maximumPendingFrames {
                    self.hasReportedBackpressure = false
                }
                self.pendingLock.unlock()
            }
            guard self.socket >= 0 else {
                if !self.hasReportedDisconnected {
                    self.hasReportedDisconnected = true
                    self.report(SRTTransportError.notConnected)
                }
                completion?(SRTTransportError.notConnected)
                return
            }
            guard !bytes.isEmpty else {
                completion?(nil)
                return
            }

            for fragment in self.makeFragments(bytes) {
                let result = fragment.withUnsafeBytes { buffer in
                    rnc_srt_send(
                        self.socket,
                        buffer.bindMemory(to: UInt8.self).baseAddress,
                        buffer.count
                    )
                }
                guard result == fragment.count else {
                    let message = result < 0
                        ? String(cString: rnc_srt_last_error())
                        : "libsrt accepted only \(result) of \(fragment.count) bytes in one SRT message."
                    let error = SRTTransportError.send(message)
                    completion?(error)
                    self.report(error)
                    self.closeSocket()
                    return
                }
            }
            completion?(nil)
        }
    }

    func sendVideo(
        _ accessUnit: Data,
        width: UInt32,
        height: UInt32,
        presentationTimeUs: UInt64
    ) {
        guard !accessUnit.isEmpty, width > 0, height > 0 else { return }
        var message = Data()
        message.reserveCapacity(21 + accessUnit.count)
        message.appendLittleEndian(UInt32(0x4d434155))
        message.append(1)
        message.appendLittleEndian(width)
        message.appendLittleEndian(height)
        message.appendLittleEndian(presentationTimeUs)
        message.append(accessUnit)
        send(message)
    }

    func disconnect() {
        performSynchronously { [weak self] in
            guard let self else { return }
            self.closeSocket()
        }
    }

    private func makeFragments(_ message: Data) -> [Data] {
        let fragmentMagic: UInt32 = 0x4d434146
        let fragmentPayloadBytes = maximumSrtMessageBytes - fragmentHeaderBytes
        let fragmentCount = (message.count + fragmentPayloadBytes - 1) / fragmentPayloadBytes
        let sequence = nextFragmentSequence
        nextFragmentSequence &+= 1

        return (0..<fragmentCount).map { index in
            let offset = index * fragmentPayloadBytes
            let length = min(fragmentPayloadBytes, message.count - offset)
            var fragment = Data()
            fragment.reserveCapacity(fragmentHeaderBytes + length)
            fragment.appendLittleEndian(fragmentMagic)
            fragment.appendLittleEndian(sequence)
            fragment.appendLittleEndian(UInt16(index))
            fragment.appendLittleEndian(UInt16(fragmentCount))
            fragment.appendLittleEndian(UInt32(message.count))
            fragment.append(message.subdata(in: offset..<(offset + length)))
            return fragment
        }
    }

    private func closeSocket() {
        guard socket >= 0 else { return }
        rnc_srt_close(socket)
        socket = -1
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    private func performSynchronously(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeSocket()
        } else {
            queue.sync {
                closeSocket()
            }
        }
    }
}
