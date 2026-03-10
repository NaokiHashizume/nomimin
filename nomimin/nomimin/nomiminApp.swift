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

// MARK: - Root View（@State が確実に動作するよう View に分離）

struct RootView: View {
    @StateObject private var store = EventStore()
    @StateObject private var firebaseService = FirebaseService.shared
    @State private var isReady = false
    @State private var pendingImport: SharedEventData?
    @State private var pendingJoinDocumentID: String?
    @State private var pendingConfirmedData: ParsedReservation?

    var body: some View {
        Group {
            if isReady {
                EventListView(
                    store: store,
                    pendingImport: $pendingImport,
                    pendingJoinDocumentID: $pendingJoinDocumentID,
                    pendingConfirmedData: $pendingConfirmedData
                )
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("初期化中...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                try await firebaseService.signInAnonymously()
                await store.migrateLocalEventsIfNeeded()
                await store.sync()
                isReady = true
            } catch {
                #if DEBUG
                print("Firebase init error: \(error)")
                #endif
                isReady = true
                print("isReady set to true in catch")
            }
        }
        .task {
            // ATT ダイアログ表示（広告パーソナライズ許可）
            #if os(iOS) && !targetEnvironment(simulator)
            try? await Task.sleep(for: .seconds(1))
            if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                await ATTrackingManager.requestTrackingAuthorization()
            }
            #endif
        }
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

// MARK: - App Entry Point

@main
struct nomiminApp: App {
    init() {
        FirebaseService.shared.configure()

        #if os(iOS) && !targetEnvironment(simulator)
        MobileAds.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
