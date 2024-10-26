// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let HAVE_COCOATOUCH = "1"
let INLINE = "inline"
let NO_ZIP = "0"
let USE_STRUCTS = "1"
let __GCCUNIX__ = "1"
let __LIBRETRO__ = "0"

let package = Package(
    name: "PVCoreBliss",
    platforms: [
        .iOS(.v17),
        .tvOS(.v16),
        .watchOS(.v9),
        .macOS(.v11),
        .macCatalyst(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "PVBliss",
            targets: ["PVCoreBliss"]),
        .library(
            name: "PVBliss-Dynamic",
            type: .dynamic,
            targets: ["PVCoreBliss"]),
        .library(
            name: "PVBliss-Static",
            type: .static,
            targets: ["PVCoreBliss"]),
    ],
    dependencies: [
        .package(path: "../../PVCoreBridge"),
        .package(path: "../../PVCoreObjCBridge"),
        .package(path: "../../PVPlists"),
        .package(path: "../../PVEmulatorCore"),
        .package(path: "../../PVSupport"),
        .package(path: "../../PVAudio"),
        .package(path: "../../PVLogging"),
        .package(path: "../../PVObjCUtils"),

        .package(url: "https://github.com/Provenance-Emu/SwiftGenPlugin.git", branch: "develop"),
    ],
    targets: [
        // MARK: --------- Core -----------
        .target(
            name: "PVCoreBliss",
            dependencies: [
                "PVEmulatorCore",
                "PVCoreBridge",
                "PVLogging",
                "PVAudio",
                "PVSupport",
                "PVCoreBlissBridge",
                "libbliss",
            ],
            resources: [
                .process("Resources/Core.plist"),
                .copy("Resources/knowncarts.cfg"),
            ],
            cSettings: [
                   .headerSearchPath("../libbliss/Bliss/"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ],
            plugins: [
                .plugin(name: "SwiftGenPlugin", package: "SwiftGenPlugin")
            ]
        ),

        // MARK: --------- Bridge -----------
        .target(
            name: "PVCoreBlissBridge",
            dependencies: [
                "PVEmulatorCore",
                "PVCoreBridge",
                "PVCoreObjCBridge",
                "PVSupport",
                "PVPlists",
                "PVObjCUtils",
                "libbliss",
            ],
            resources: [
                .process("Resources/Core.plist"),
                .copy("Resources/knowncarts.cfg"),
            ],
            cSettings: [
                   .headerSearchPath("../libbliss/Bliss/"),
            ],
            cxxSettings: [
                .unsafeFlags([
                    "-fmodules",
                    "-fcxx-modules"
                ]),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        // MARK: --------- libbliss -----------

        .target(
            name: "libbliss",
            sources: Sources.libbliss,
            packageAccess: true,
            cSettings: [
                .headerSearchPath("Bliss")
            ],
            cxxSettings: [

            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),

        // MARK: --------- Tests -----------
        
//        .testTarget(
//            name: "PVBlissTests",
//            dependencies: ["PVCoreBliss"])
    ],
    swiftLanguageModes: [.v5, .v6],
    cLanguageStandard: .gnu99,
    cxxLanguageStandard: .gnucxx14
)

enum Sources {
    static let libbliss: [String] = [
        "Bliss/core/Emulator.cpp",
        "Bliss/core/Peripheral.cpp",
        "Bliss/core/audio/AY38914.cpp",
        "Bliss/core/audio/AY38914_Channel.cpp",
        "Bliss/core/audio/AY38914_Registers.cpp",
        "Bliss/core/audio/AudioMixer.cpp",
        "Bliss/core/audio/AudioOutputLine.cpp",
        "Bliss/core/audio/Pokey.cpp",
        "Bliss/core/audio/Pokey_Registers.cpp",
        "Bliss/core/audio/SP0256.cpp",
        "Bliss/core/audio/SP0256_Registers.cpp",
        "Bliss/core/cpu/6502c.cpp",
        "Bliss/core/cpu/CP1610.cpp",
        "Bliss/core/cpu/Processor.cpp",
        "Bliss/core/cpu/ProcessorBus.cpp",
        "Bliss/core/input/InputConsumerBus.cpp",
        "Bliss/core/input/InputConsumerObject.cpp",
        "Bliss/core/input/InputProducerManager.cpp",
        "Bliss/core/input/JoystickInputProducer.cpp",
        "Bliss/core/input/KeyboardInputProducer.cpp",
        "Bliss/core/memory/MemoryBus.cpp",
        "Bliss/core/memory/RAM.cpp",
        "Bliss/core/memory/ROM.cpp",
        "Bliss/core/memory/ROMBanker.cpp",
        "Bliss/core/rip/CRC32.cpp",
        "Bliss/core/rip/Rip.cpp",
        "Bliss/core/rip/ioapi.c",
        "Bliss/core/rip/ripxbf.c",
        "Bliss/core/rip/unzip.c",
        "Bliss/core/video/AY38900.cpp",
        "Bliss/core/video/AY38900_Registers.cpp",
        "Bliss/core/video/Antic.cpp",
        "Bliss/core/video/Antic_Registers.cpp",
        "Bliss/core/video/BackTabRAM.cpp",
        "Bliss/core/video/GRAM.cpp",
        "Bliss/core/video/GROM.cpp",
        "Bliss/core/video/GTIA.cpp",
        "Bliss/core/video/GTIA_Registers.cpp",
        "Bliss/core/video/MOB.cpp",
        "Bliss/core/video/VideoBus.cpp",
        "Bliss/drivers/a5200/Atari5200.cpp",
        "Bliss/drivers/a5200/JoyPad.cpp",
        "Bliss/drivers/intv/ECS.cpp",
        "Bliss/drivers/intv/ECSKeyboard.cpp",
        "Bliss/drivers/intv/HandController.cpp",
        "Bliss/drivers/intv/Intellivision.cpp",
        "Bliss/drivers/intv/Intellivoice.cpp"
    ]
}
