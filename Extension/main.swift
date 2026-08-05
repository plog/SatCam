import Foundation
import CoreMediaIO

let providerSource = SatCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
