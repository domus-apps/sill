// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sill",
    defaultLocalization: "en",
    /* macOS 26+ renders apps linked against an older SDK in the legacy
       compatibility design (old-style traffic lights, pre-Liquid Glass
       chrome). This toolchain stamps the binary's LC_BUILD_VERSION sdk field
       from the deployment target, so the target must be >= 26 for the app
       to get the native current-OS appearance. */
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Sill",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Sill",
            linkerSettings: [
                /* Two rpaths for the two places Sparkle.framework lives:
                   ../Frameworks for the bundled app (Scripts/bundle.sh embeds
                   it at Contents/Frameworks), and the executable's own dir
                   for `swift run` — Xcode 26's build system stages the
                   framework next to the binary but writes no rpath for it. */
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path",
                ])
            ]
        ),
        .testTarget(
            name: "SillTests",
            dependencies: ["Sill"],
            path: "Tests/SillTests"
        )
    ]
)
