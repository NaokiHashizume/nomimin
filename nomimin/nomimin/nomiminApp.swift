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
        #if os(iOS)
        GADMobileAds.sharedInstance().start(completionHandler: nil)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            EventListView()
        }
    }
}
