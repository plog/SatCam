import SwiftUI

@main
struct SatCamApp: App {
    @StateObject private var pipeline = CameraPipeline()
    @StateObject private var installer = ExtensionInstaller()

    var body: some Scene {
        MenuBarExtra("SatCam", systemImage: "camera.filters") {
            VStack(alignment: .leading, spacing: 12) {
                Text("SatCam").font(.headline)

                HStack {
                    Text("Saturation")
                    Slider(value: $pipeline.saturation, in: 0...2)
                    Text(String(format: "%.2f", pipeline.saturation))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Contrast")
                    Slider(value: $pipeline.contrast, in: 0.5...1.5)
                    Text(String(format: "%.2f", pipeline.contrast))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }

                Divider()

                HStack {
                    Button(pipeline.running ? "Stop" : "Start") {
                        pipeline.running ? pipeline.stop() : pipeline.start()
                    }
                    Text(pipeline.status).font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Button("Install extension") { installer.install() }
                    Text(installer.status).font(.caption).foregroundStyle(.secondary)
                }

                Button("Quit") { NSApp.terminate(nil) }
                    .font(.caption)
            }
            .padding(14)
            .frame(width: 340)
        }
        .menuBarExtraStyle(.window)
    }
}
