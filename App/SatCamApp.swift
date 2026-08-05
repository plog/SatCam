import SwiftUI

@main
struct SatCamApp: App {
    @StateObject private var pipeline = CameraPipeline()
    @StateObject private var installer = ExtensionInstaller()

    var body: some Scene {
        MenuBarExtra("SatCam", systemImage: "camera.filters") {
            ContentView(pipeline: pipeline, installer: installer)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @ObservedObject var pipeline: CameraPipeline
    @ObservedObject var installer: ExtensionInstaller

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 8) {
                Image(systemName: "camera.filters")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("SatCam")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { pipeline.running },
                    set: { $0 ? pipeline.start() : pipeline.stop() }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(pipeline.running ? "Stop the virtual camera" : "Start the virtual camera")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Status
            HStack(spacing: 6) {
                Circle()
                    .fill(pipeline.running ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(pipeline.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            // Adjustments
            VStack(alignment: .leading, spacing: 14) {
                SliderRow(symbol: "drop.halffull",
                          title: "Saturation",
                          value: $pipeline.saturation,
                          range: 0...2,
                          neutral: 1.0)
                SliderRow(symbol: "circle.lefthalf.filled",
                          title: "Contrast",
                          value: $pipeline.contrast,
                          range: 0.5...1.5,
                          neutral: 1.0)
            }
            .padding(14)

            Divider()

            // Extension install (setup step)
            if !installer.status.hasPrefix("Extension installed") {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        installer.install()
                    } label: {
                        Label("Install Camera Extension…", systemImage: "puzzlepiece.extension")
                    }
                    if !installer.status.isEmpty {
                        Text(installer.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }

            // Footer
            HStack {
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit SatCam") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
    }
}

/// A labeled slider with an SF Symbol, a live value readout and
/// double-click-to-reset on the label, macOS-settings style.
struct SliderRow: View {
    let symbol: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.callout)
                    .onTapGesture(count: 2) { value = neutral }
                    .help("Double-click to reset")
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}
