import Foundation
import SystemExtensions
import os.log

final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    @Published var status = ""
    private let logger = Logger(subsystem: "net.plog.SatCam", category: "installer")

    func install() {
        status = "Request submitted…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "net.plog.SatCam.Extension",
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approval required in System Settings"
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = result == .completed ? "Extension installed" : "Reboot required"
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        logger.error("activation failed: \(ns, privacy: .public) userInfo=\(ns.userInfo, privacy: .public)")
        var detail = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            logger.error("underlying: \(underlying, privacy: .public) userInfo=\(underlying.userInfo, privacy: .public)")
            detail += " ← \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
        }
        status = "Error: \(ns.localizedDescription) [\(detail)]"
    }
}
