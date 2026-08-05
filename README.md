# SatCam 📷✨

**A tiny native macOS virtual camera that boosts the saturation (and contrast) of your built-in FaceTime HD camera — live, during your Microsoft Teams / Zoom / Meet calls.**

On Apple Silicon Macs the built-in camera is driven by Apple's ISP: it exposes **no UVC controls**, and neither macOS nor Teams offers a saturation setting. If you look washed-out on calls, your options are commercial apps or running OBS. SatCam is the third option: ~500 lines of Swift, GPU-accelerated, no dependencies, fully yours.

```
┌──────────────┐   AVFoundation   ┌─────────────────┐   CoreMediaIO sink   ┌──────────────────────┐
│ FaceTime HD  │ ───────────────► │  SatCam.app      │ ───────────────────► │  Camera Extension    │
│ (built-in)   │     720p BGRA    │  CIColorControls │    CMSampleBuffers   │  virtual "SatCam"    │
└──────────────┘                  │  (GPU, Metal)    │                      │  device              │
                                  └─────────────────┘                      └──────────┬───────────┘
                                    menu bar sliders                                  │ source stream
                                                                                     ▼
                                                                          Teams / Zoom / Meet / QuickTime
```

- **Menu bar app** — two sliders (saturation 0–2, contrast 0.5–1.5), applied in real time and persisted.
- **CMIOExtension** — the modern (macOS 12.3+) camera extension API. Apps see a regular camera named **SatCam**.
- **Cheap** — the filter runs on the GPU via CoreImage; expect ~2–3 % CPU, far less than OBS's full compositing pipeline.
- **Honest fallback** — when the app isn't pushing frames, the virtual camera shows a dark frame instead of freezing.

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple ID added in Xcode → Settings → Accounts, enrolled in the **paid Apple Developer Program**. ⚠️ Free Personal Teams cannot build this: activating a system extension requires the `com.apple.developer.system-extension.install` entitlement, which Apple does not grant to personal teams (activation fails with an opaque `OSSystemExtensionErrorDomain error 1`).

## Build & install

```sh
xcodegen generate

xcodebuild -project SatCam.xcodeproj -scheme SatCam -configuration Release \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<YOUR_TEAM_ID> build

# System extensions only activate from /Applications
cp -R ~/Library/Developer/Xcode/DerivedData/SatCam-*/Build/Products/Release/SatCam.app /Applications/
open /Applications/SatCam.app
```

Find your team ID in Xcode → Settings → Accounts, or with:

```sh
defaults read com.apple.dt.Xcode IDEProvisioningTeams
```

> **Note** — the bundle identifiers (`net.plog.SatCam*`) are mine; change them in `project.yml`, `ExtensionInstaller.swift` and the `kDeviceUID` constants if you fork this.

## First run

1. Click the 📷 icon in the menu bar → **Install extension**.
2. macOS will ask for approval: **System Settings → Privacy & Security → Allow** (under the blocked system software section).
3. Back in SatCam → **Start** → grant camera access.
4. In Teams: **Settings → Devices → Camera → SatCam**. Drag the saturation slider while watching the preview. Start around **1.3–1.4**.

Keep SatCam running during calls — it is the engine feeding the virtual camera.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `OSSystemExtensionErrorDomain error 1/8` | The app must run from `/Applications` and be signed with a valid (even free) Apple Development certificate. Re-copy after every rebuild. |
| “SatCam camera not found” | Install and approve the extension first; give macOS a few seconds after approval. |
| Dark gray image in Teams | The extension works but the app isn't streaming — click **Start**. |
| Extension won't update | `systemextensionsctl list`, then bump the build, re-copy to `/Applications`, and re-run **Install extension** (it replaces the old one). |
| Free certificate expired | Free Apple Development certificates last 1 year — rebuild and reinstall. |

## How it works

- `Extension/Provider.swift` — a `CMIOExtensionProvider` exposing one device with **two streams**: a *source* stream that consumer apps (Teams) read, and a *sink* stream that the SatCam app writes into. When no client feeds the sink, a timer publishes dark frames at 30 fps.
- `App/CameraPipeline.swift` — captures the built-in camera at 1280×720 BGRA with `AVCaptureSession`, runs `CIFilter.colorControls` in a Metal-backed `CIContext`, then enqueues the frames into the extension's sink stream through the CoreMediaIO C API (`CMIOStreamCopyBufferQueue` / `CMSimpleQueueEnqueue`).
- `App/ExtensionInstaller.swift` — activates the embedded system extension via `OSSystemExtensionRequest`.

## License

MIT — see [LICENSE](LICENSE).
