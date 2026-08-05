import Foundation
import SystemExtensions

final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    @Published var status = ""

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
        status = "Error: \(error.localizedDescription)"
    }
}
