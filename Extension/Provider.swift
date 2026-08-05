import Foundation
import CoreMediaIO
import CoreVideo
import os.log

let kWidth: Int32 = 1280
let kHeight: Int32 = 720
let kFrameRate: Int32 = 30
let kDeviceUID = "net.plog.SatCam.Device"

let logger = Logger(subsystem: "net.plog.SatCam.Extension", category: "Provider")

// MARK: - Device

class SatCamDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var _streamSource: SatCamStreamSource!
    private var _sinkSource: SatCamSinkStreamSource!
    private var _streamingCounter = 0
    private var _sinkStarted = false
    private var _timer: DispatchSourceTimer?
    private let _timerQueue = DispatchQueue(label: "net.plog.SatCam.timer", qos: .userInteractive)
    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!

    init(localizedName: String) {
        super.init()
        self.device = CMIOExtensionDevice(localizedName: localizedName,
                                          deviceID: UUID(),
                                          legacyDeviceID: kDeviceUID,
                                          source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: kWidth, height: kHeight,
                                       extensions: nil,
                                       formatDescriptionOut: &_videoDescription)

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: kWidth,
            kCVPixelBufferHeightKey: kHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)
        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        let frameDuration = CMTime(value: 1, timescale: kFrameRate)
        let format = CMIOExtensionStreamFormat(formatDescription: _videoDescription,
                                               maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration,
                                               validFrameDurations: nil)

        _streamSource = SatCamStreamSource(localizedName: "SatCam Video",
                                           streamID: UUID(),
                                           streamFormat: format,
                                           device: device)
        _sinkSource = SatCamSinkStreamSource(localizedName: "SatCam Sink",
                                             streamID: UUID(),
                                             streamFormat: format,
                                             device: device)
        do {
            try device.addStream(_streamSource.stream)
            try device.addStream(_sinkSource.stream)
        } catch {
            fatalError("Unable to add streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) { p.model = "SatCam" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: source (towards Teams/consumers)

    func startStreaming() {
        _streamingCounter += 1
        guard _timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate))
        timer.setEventHandler { [weak self] in
            guard let self, !self._sinkStarted, self._streamingCounter > 0 else { return }
            self.sendBlankFrame()
        }
        timer.resume()
        _timer = timer
    }

    func stopStreaming() {
        _streamingCounter = max(0, _streamingCounter - 1)
        if _streamingCounter == 0 {
            _timer?.cancel()
            _timer = nil
        }
    }

    /// Dark frame shown while the SatCam app is not pushing anything.
    private func sendBlankFrame() {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPool, _bufferAuxAttributes, &pixelBuffer)
        guard let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x20, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pixelBuffer,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: _videoDescription,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &sbuf)
        if let sbuf {
            _streamSource.stream.send(sbuf,
                                      discontinuity: [],
                                      hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
        }
    }

    // MARK: sink (from the SatCam app)

    func startStreamingSink(client: CMIOExtensionClient) {
        _sinkStarted = true
        consumeBuffer(client)
    }

    func stopStreamingSink() {
        _sinkStarted = false
    }

    private func consumeBuffer(_ client: CMIOExtensionClient) {
        guard _sinkStarted else { return }
        _sinkSource.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, sequenceNumber, discontinuity, hasMoreSampleBuffers, error in
            guard let self else { return }
            if let sbuf {
                let hostNanos = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
                if self._streamingCounter > 0 {
                    self._streamSource.stream.send(sbuf,
                                                   discontinuity: [],
                                                   hostTimeInNanoseconds: hostNanos)
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                                          hostTimeInNanoseconds: hostNanos)
                self._sinkSource.stream.notifyScheduledOutputChanged(output)
            }
            self.consumeBuffer(client)
        }
    }
}

// MARK: - Stream source (what Teams sees)

class SatCamStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName,
                                          streamID: streamID,
                                          direction: .source,
                                          clockType: .hostTime,
                                          source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: kFrameRate)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard let source = device.source as? SatCamDeviceSource else { return }
        source.startStreaming()
    }

    func stopStream() throws {
        guard let source = device.source as? SatCamDeviceSource else { return }
        source.stopStreaming()
    }
}

// MARK: - Sink stream (what the SatCam app writes)

class SatCamSinkStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName,
                                          streamID: streamID,
                                          direction: .sink,
                                          clockType: .hostTime,
                                          source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: kFrameRate)
        }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 8 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard let source = device.source as? SatCamDeviceSource,
              let client = stream.streamingClients.first else { return }
        source.startStreamingSink(client: client)
    }

    func stopStream() throws {
        guard let source = device.source as? SatCamDeviceSource else { return }
        source.stopStreamingSink()
    }
}

// MARK: - Provider

class SatCamProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: SatCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = SatCamDeviceSource(localizedName: "SatCam")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Unable to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "plog" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
