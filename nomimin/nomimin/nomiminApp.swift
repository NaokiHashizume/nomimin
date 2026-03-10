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
    @StateObject private var firebaseService = FirebaseService.shared
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
            Group {
                if firebaseService.isInitialized {
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
                } catch {
                    #if DEBUG
                    print("Firebase init error: \(error)")
                    #endif
                    // 認証失敗でもスピナーを止めて画面を表示する
                    firebaseService.isInitialized = true
                }
            }
            .task {
                // ATT ダイアログ表示（広告パーソナライズ許可）
                #if os(iOS) && !targetEnvironment(simulator)
                // 少し遅延させて起動後に表示
                try? await Task.sleep(for: .seconds(1))
                if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                    await ATTrackingManager.requestTrackingAuthorization()
                }
                #endif
            }
            .onOpenURL { url in
                // Share Extension: 予約確認データ
                if let parsed = ParsedReservation.fromURL(url) {
                    pendingConfirmedData = parsed
                }
                // Firestore docIDベース
                else if let documentID = EventShareCoder.decodeShareLink(url: url) {
                    pendingJoinDocumentID = documentID
                }
                // 旧: URL埋め込みデータ（後方互換）
                else if let data = EventShareCoder.decode(url: url) {
                    pendingImport = data
                }
            }
        }
    }
}
