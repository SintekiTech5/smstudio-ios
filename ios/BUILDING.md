# Building the native iOS app

The native SwiftUI app is defined by `project.yml` and the Swift sources in the
workspace root. Generate the Xcode project on a Mac with XcodeGen installed:

```sh
brew install cmake xcodegen
cd ios
xcodegen generate
open SMStudio.xcodeproj
```

The target includes the existing SRT C shim. The Android `libsrt.so` files
cannot be linked into an iOS app. Run
`bash ios/scripts/build-dependencies.sh` on a Mac with Xcode, CMake, and
OpenSSL's build prerequisites installed. The script builds pinned OpenSSL
3.5.4 and Haivision SRT 1.5.4 from source, with SRT encryption enabled, and
creates iOS device and simulator XCFrameworks under `ios/Vendor/`. It also
copies both dependency licenses into the app's resources. The generated
frameworks are ignored by Git and should be rebuilt by CI or locally.

In Xcode, select the `SMStudio` scheme and an iOS Simulator to build without
device signing. To install on a physical iPhone or distribute through
TestFlight, select a development team and configure the app's bundle
identifier and signing in Xcode.

This Windows workspace does not include Xcode or XcodeGen, so the iOS target
must be generated and compiled on a Mac or a hosted macOS runner.
`.github/workflows/ios-simulator.yml` builds the dependencies from source,
generates the Xcode project, builds the simulator app, and uploads it.
