//
//  nomiminApp.swift
//  nomimin
//
//  Created by Hashizume, Naoki | Hassy | RTS on 2026/03/01.
//

import SwiftUI
import FirebaseCore

#if os(iOS) && !targetEnvironment(simulator)
import GoogleMobileAds
import AppTrackingTransparency
#endif

@main
struct nomiminApp: App {
    @StateObject private var store = EventStore()
    @State private var pendingImport: SharedEventData?
    @State private var pendingJoinDocumentID: String?
    @State private var pendingConfirmedData: ParsedReservation?

    init() {
        FirebaseService.shared.configure()

        #if os(iOS) && !targetEnvironment(simulator)
        MobileAds.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            EventListView(
                store: store,
                pendingImport: $pendingImport,
                pendingJoinDocumentID: $pendingJoinDocumentID,
                pendingConfirmedData: $pendingConfirmedData
            )
            .task {
                do {
                    try await FirebaseService.shared.signInAnonymously()
                    await store.migrateLocalEventsIfNeeded()
                    await store.sync()
                } catch {
                    #if DEBUG
                    print("Firebase init error: \(error)")
                    #endif
                }
            }
            #if os(iOS) && !targetEnvironment(simulator)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task {
                    // アプリが完全にアクティブになってからATTダイアログを表示
                    try? await Task.sleep(for: .seconds(0.5))
                    if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                        await ATTrackingManager.requestTrackingAuthorization()
                    }
                }
            }
            #endif
            .onOpenURL { url in
                if let parsed = ParsedReservation.fromURL(url) {
                    pendingConfirmedData = parsed
                } else if let documentID = EventShareCoder.decodeShareLink(url: url) {
                    pendingJoinDocumentID = documentID
                } else if let data = EventShareCoder.decode(url: url) {
                    pendingImport = data
                }
            }
        }
    }
}
