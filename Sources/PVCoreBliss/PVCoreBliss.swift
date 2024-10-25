//
//  PVVisualBoyAdvance.swift
//  PVVisualBoyAdvance
//
//  Created by Joseph Mattiello on 5/30/24.
//  Copyright © 2024 Provenance EMU. All rights reserved.
//

import Foundation
#if canImport(GameController)
@_exported import GameController
#endif
import PVCoreBridge
import PVLogging
import PVAudio
import PVEmulatorCore
import PVCoreBlissBridge
//import libbliss

@objc
@objcMembers
public final class PVCoreBliss: PVEmulatorCore, @unchecked Sendable {

    // MARK: Resources
    var knownCarts: String? {
        return Bundle.module.path(forResource: "knowncarts", ofType: "cfg")
    }
    
//    public override var alwaysUseGL: Bool {
//        return true
//    }
    // MARK: ROMs
        
    // MARK: Cheats

    // MARK: Buffers

    // MARK: Video

    // MARK: Audio

    // MARK: Lifecycle
    
    //TODO: Fix metal, but for now force openGL
    override public var alwaysUseMetal: Bool { false }
    override public var alwaysUseGL: Bool { true }
    
    lazy var _bridge: PVBlissGameCoreBridge = .init()
    
    public required init() {
        super.init()
        self.bridge = (_bridge as! any ObjCBridgedCoreBridge)
        _bridge.knownCartsPath = knownCarts
    }
}

//This may be needed, but not tested or integrated yet.
extension PVCoreBliss: KeyboardResponder {
    public var gameSupportsKeyboard: Bool { true }
    
    public var requiresKeyboard: Bool { false }
    
    public func keyDown(_ key: GCKeyCode) {
        _bridge.keyDown(UInt16(key.rawValue))
    }
    
    public func keyUp(_ key: GCKeyCode) {
        _bridge.keyUp(UInt16(key.rawValue))
    }
}

extension PVCoreBliss: PVIntellivisionSystemResponderClient {
    public func didPush(_ button: PVCoreBridge.PVIntellivisionButton, forPlayer player: Int) {
        (_bridge as! PVIntellivisionSystemResponderClient).didPush(button, forPlayer: player)
    }
    
    public func didRelease(_ button: PVCoreBridge.PVIntellivisionButton, forPlayer player: Int) {
        (_bridge as! PVIntellivisionSystemResponderClient).didRelease(button, forPlayer: player)
    }
}
