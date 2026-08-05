import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMediaIO
import Combine

private let kDeviceUID = "net.plog.SatCam.Device"

final class CameraPipeline: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var saturation: Double {
        didSet { UserDefaults.standard.set(saturation, forKey: "saturation") }
    }
    @Published var contrast: Double {
        didSet { UserDefaults.standard.set(contrast, forKey: "contrast") }
    }
    @Published var running = false
    @Published var status = "Stopped"
    @Published var preview: CGImage?
    /// Only render preview frames while the popover is visible.
    var previewEnabled = false
    private var previewFrameCounter = 0

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "net.plog.SatCam.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var outputPool: CVPixelBufferPool?

    private var cmioDevice: CMIOObjectID = 0
    private var sinkStream: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?

    override init() {
        let d = UserDefaults.standard
        saturation = d.object(forKey: "saturation") as? Double ?? 1.35
        contrast = d.object(forKey: "contrast") as? Double ?? 1.0
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.status = "Camera access denied"; return }
                self.startPipeline()
            }
        }
    }

    private func startPipeline() {
        let extensionConnected = connectToExtension()
        guard setUpCapture() else { return }
        captureQueue.async { self.session.startRunning() }
        running = true
        status = extensionConnected ? "Running" : "Preview only — extension not installed"
    }

    func stop() {
        captureQueue.async { self.session.stopRunning() }
        if sinkStream != 0 { CMIODeviceStopStream(cmioDevice, sinkStream) }
        sinkQueue = nil
        cmioDevice = 0
        sinkStream = 0
        running = false
        status = "Stopped"
    }

    // MARK: - FaceTime HD capture

    private func setUpCapture() -> Bool {
        guard session.inputs.isEmpty else { return true }

        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                         mediaType: .video,
                                                         position: .unspecified)
        guard let camera = discovery.devices.first,
              let input = try? AVCaptureDeviceInput(device: camera) else {
            status = "Built-in camera not found"
            return false
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            status = "Camera input rejected"
            return false
        }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            status = "Video output rejected"
            return false
        }
        session.addOutput(videoOutput)
        session.commitConfiguration()
        return true
    }

    // MARK: - Processing + push to the extension

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let inputBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let filter = CIFilter.colorControls()
        filter.inputImage = CIImage(cvPixelBuffer: inputBuffer)
        filter.saturation = Float(saturation)
        filter.contrast = Float(contrast)
        guard let result = filter.outputImage else { return }

        if previewEnabled {
            previewFrameCounter += 1
            if previewFrameCounter % 2 == 0, let cg = ciContext.createCGImage(result, from: result.extent) {
                DispatchQueue.main.async { self.preview = cg }
            }
        }

        guard let queue = sinkQueue,
              CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }

        let width = CVPixelBufferGetWidth(inputBuffer)
        let height = CVPixelBufferGetHeight(inputBuffer)
        if outputPool == nil {
            let attrs: NSDictionary = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &outputPool)
        }
        guard let pool = outputPool else { return }
        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
        guard let outBuffer else { return }
        ciContext.render(result, to: outBuffer)

        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: outBuffer,
                                                     formatDescriptionOut: &formatDesc)
        guard let formatDesc else { return }

        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var outSample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: outBuffer,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: formatDesc,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &outSample)
        guard let outSample else { return }

        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(outSample).toOpaque())
    }

    // MARK: - CMIO discovery of the extension's device

    private func connectToExtension() -> Bool {
        guard let device = findDevice(uid: kDeviceUID) else { return false }
        let streams = streamList(of: device)
        guard streams.count >= 2 else { return false }
        let sink = streams[1]

        var queueUnmanaged: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueUnmanaged)
        guard status == 0, let q = queueUnmanaged?.takeRetainedValue() else { return false }

        guard CMIODeviceStartStream(device, sink) == 0 else { return false }

        cmioDevice = device
        sinkStream = sink
        sinkQueue = q
        return true
    }

    private func findDevice(uid: String) -> CMIOObjectID? {
        var addr = propertyAddress(kCMIOHardwarePropertyDevices)
        let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &dataSize) == 0,
              dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &addr, 0, nil, dataSize, &used, &ids) == 0 else { return nil }
        return ids.first { deviceUID(of: $0) == uid }
    }

    private func deviceUID(of id: CMIOObjectID) -> String? {
        var addr = propertyAddress(kCMIODevicePropertyDeviceUID)
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            CMIOObjectGetPropertyData(id, &addr, 0, nil, dataSize, &used, ptr)
        }
        guard status == 0 else { return nil }
        return uid as String?
    }

    private func streamList(of device: CMIOObjectID) -> [CMIOStreamID] {
        var addr = propertyAddress(kCMIODevicePropertyStreams)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize) == 0,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var ids = [CMIOStreamID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, dataSize, &used, &ids) == 0 else { return [] }
        return ids
    }

    private func propertyAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
}
