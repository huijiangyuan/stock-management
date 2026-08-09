# Local compatibility patches

Vendored source: NextLevel `0.19.1`.

- Replaced `UIImagePickerController.isCameraDeviceAvailable` with the equivalent
  AVFoundation device lookup so Swift 6 does not require a MainActor hop from
  capture queues.
- Replaced `UIDevice.current.localizedModel` in optional asset-writer metadata
  with a static device label. UIKit isolates `UIDevice.current` to MainActor in
  the iOS 18 SDK, while NextLevel creates writer metadata off the main actor.
- Use NextLevel's explicit `deviceOrientation` state as the session-queue
  fallback instead of reading MainActor-isolated `UIDevice.current.orientation`.
- Mark the camera authorization completion as `@MainActor @Sendable`, matching
  the existing main-queue delivery contract under Swift 6 strict concurrency.
- Return an explicit start result from static photo capture, propagate native
  capture errors, and provide a deterministic stop completion callback.

These changes preserve preview, focus, and image output semantics while making
photo capture failure and session-stop completion explicit to the application.
