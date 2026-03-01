//
//  nomiminApp.swift
//  nomimin
//
//  Created by Hashizume, Naoki | Hassy | RTS on 2026/03/01.
//

import SwiftUI

#if os(iOS)
import GoogleMobileAds
#endif

@main
struct nomiminApp: App {
    init() {
        // AdMob初期化は後で有効化
        // #if os(iOS)
        // MobileAds.shared.start()
        // #endif
    }

    var body: some Scene {
        WindowGroup {
            EventListView()
        }
    }
}
