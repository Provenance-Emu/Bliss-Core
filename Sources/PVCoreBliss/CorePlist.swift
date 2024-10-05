//
//  CorePlist.swift
//
//
//  Created by Joseph Mattiello on 6/21/24.
//

import Foundation
import PVLogging
import PVCoreBridge
import PVEmulatorCore
import PVPlists

#if SWIFT_PACKAGE
public extension PVBundleFinder {
    static var BlissModule: Bundle { Bundle.module }
    static var BlissBundle: Bundle { Bundle(for: PVCoreBliss.self) }
}
#else
public extension PVBundleFinder {
    static public var BlissBundle: Bundle { Bundle(for: PVCoreBliss.self) }
}
#endif

@objc
extension PVCoreBliss: EmulatorCoreInfoPlistProvider {

    @objc
    public static var resourceBundle: Bundle { Bundle.module }

    @objc
    public override var resourceBundle: Bundle { Bundle.module }

    @objc(corePlistFromBundle)
    public static var corePlistFromBundle: EmulatorCoreInfoPlist {

        guard let plistPath = resourceBundle.url(forResource: "Core", withExtension: "plist") else {
            fatalError("Could not locate Core.plist")
        }

        guard let data = try? Data(contentsOf: plistPath) else {
            fatalError("Could not read Core.plist")
        }

        guard let plistObject = try? PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any] else {
            fatalError("Could not generate parse Core.plist")
        }

        guard let corePlist = EmulatorCoreInfoPlist.init(fromInfoDictionary: plistObject) else {
            fatalError("Could not generate EmulatorCoreInfoPlist from Core.plist")
        }

        return corePlist
    }

    /// Note: CorePlist is an enum generated by SwiftGen with a custom stencil
    /// Change the swiftgen config to the local path to see the outputs and tweak
    @objc(corePlist)
    public static var corePlist: EmulatorCoreInfoPlist { CorePlist.corePlist }

    @objc
    public var corePlist: EmulatorCoreInfoPlist { Self.corePlist }
}
