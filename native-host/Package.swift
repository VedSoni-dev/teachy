// swift-tools-version:5.9
// The Chrome native-messaging host for Teachy. Not part of the Xcode project:
// build it with native-host/build.sh (or scripts/install-chrome-host.sh).
import PackageDescription

let package = Package(
    name: "teachy-browser-host",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "teachy-browser-host",
            path: "Sources/teachy-browser-host"
        )
    ]
)
