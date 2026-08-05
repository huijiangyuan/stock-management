# Local compatibility patches

Vendored source: NextLevel `0.19.1`.

- Replaced `UIImagePickerController.isCameraDeviceAvailable` with the equivalent
  AVFoundation device lookup so Swift 6 does not require a MainActor hop from
  capture queues.
- Replaced `UIDevice.current.localizedModel` in optional asset-writer metadata
  with a static device label. UIKit isolates `UIDevice.current` to MainActor in
  the iOS 18 SDK, while NextLevel creates writer metadata off the main actor.

These changes do not alter photo capture, preview, focus, session lifecycle, or
image output behavior.
