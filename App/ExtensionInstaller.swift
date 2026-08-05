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
        if ns.domain == OSSystemExtensionErrorDomain && ns.code == OSSystemExtensionError.unknown.rawValue {
            // Free personal teams are denied the system-extension.install
            // entitlement, which surfaces as this opaque error.
            status = "Unavailable: activating the virtual camera requires a paid Apple Developer team. Use the preview meanwhile."
        } else {
            status = "Error: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
    }
}
