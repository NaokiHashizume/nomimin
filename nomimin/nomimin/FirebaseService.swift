//
//  FirebaseService.swift
//  nomimin
//
//  Firebase Firestore リアルタイム同期サービス
//

import Foundation
import Combine
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

// MARK: - Firestore変換モデル

struct FirestoreEvent: Codable {
    var title: String
    var ownerUID: String
    var memberUIDs: [String]
    var joinCode: String?
    var dateSlots: [String]  // ISO 8601
    var participants: [FirestoreParticipant]
    var confirmedInfo: FirestoreConfirmedInfo?
    var createdAt: Date
    var updatedAt: Date
}

struct FirestoreParticipant: Codable {
    var id: String
    var name: String
    var nearestStation: String
    var availabilities: [String: String]  // "2026-03-15T00:00:00Z": "yes"
}

struct FirestoreConfirmedInfo: Codable {
    var shopName: String
    var address: String?
    var date: Date
    var time: Date
    var memo: String
}

// MARK: - 変換ヘルパー

extension DateSlot {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var isoString: String {
        DateSlot.isoFormatter.string(from: date)
    }

    static func fromISO(_ string: String) -> DateSlot? {
        guard let date = isoFormatter.date(from: string) else { return nil }
        return DateSlot(date: date)
    }
}

extension Availability {
    var firestoreValue: String {
        switch self {
        case .yes: return "yes"
        case .maybe: return "maybe"
        case .no: return "no"
        }
    }

    static func fromFirestore(_ value: String) -> Availability {
        switch value {
        case "yes": return .yes
        case "maybe": return .maybe
        default: return .no
        }
    }
}

extension Participant {
    func toFirestore() -> FirestoreParticipant {
        let avails = Dictionary(
            uniqueKeysWithValues: availabilities.map { ($0.key.isoString, $0.value.firestoreValue) }
        )
        return FirestoreParticipant(
            id: id.uuidString,
            name: name,
            nearestStation: nearestStation,
            availabilities: avails
        )
    }

    static func fromFirestore(_ fp: FirestoreParticipant) -> Participant {
        let avails: [DateSlot: Availability] = Dictionary(
            uniqueKeysWithValues: fp.availabilities.compactMap { (key, value) in
                guard let slot = DateSlot.fromISO(key) else { return nil }
                return (slot, Availability.fromFirestore(value))
            }
        )
        return Participant(
            id: UUID(uuidString: fp.id) ?? UUID(),
            name: fp.name,
            nearestStation: fp.nearestStation,
            availabilities: avails
        )
    }
}

extension ConfirmedInfo {
    func toFirestore() -> FirestoreConfirmedInfo {
        FirestoreConfirmedInfo(shopName: shopName, address: address.isEmpty ? nil : address, date: date, time: time, memo: memo)
    }

    static func fromFirestore(_ fc: FirestoreConfirmedInfo) -> ConfirmedInfo {
        ConfirmedInfo(shopName: fc.shopName, address: fc.address ?? "", date: fc.date, time: fc.time, memo: fc.memo)
    }
}

extension Event {
    func toFirestore(ownerUID: String, memberUIDs: [String], joinCode: String? = nil) -> FirestoreEvent {
        FirestoreEvent(
            title: title,
            ownerUID: ownerUID,
            memberUIDs: memberUIDs,
            joinCode: joinCode,
            dateSlots: dateSlots.sorted().map { $0.isoString },
            participants: participants.map { $0.toFirestore() },
            confirmedInfo: confirmedInfo?.toFirestore(),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func fromFirestore(_ fe: FirestoreEvent, id: UUID) -> Event {
        var event = Event(
            id: id,
            title: fe.title,
            participants: fe.participants.map { Participant.fromFirestore($0) },
            dateSlots: fe.dateSlots.compactMap { DateSlot.fromISO($0) },
            confirmedInfo: fe.confirmedInfo.map { ConfirmedInfo.fromFirestore($0) }
        )
        event.createdAt = fe.createdAt
        event.updatedAt = fe.updatedAt
        return event
    }
}

// MARK: - Firebase Service

enum FirebaseError: LocalizedError {
    case notAuthenticated
    case documentNotFound
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "認証されていません"
        case .documentNotFound: return "イベントが見つかりません"
        case .encodingFailed: return "データの変換に失敗しました"
        }
    }
}

@MainActor
class FirebaseService: ObservableObject {
    static let shared = FirebaseService()

    @Published var currentUserUID: String?
    @Published var isInitialized = false

    private var db: Firestore!
    private var eventListeners: [String: ListenerRegistration] = [:]

    private init() {}

    // MARK: - 初期化

    func configure() {
        FirebaseApp.configure()
        db = Firestore.firestore()
    }

    // MARK: - 匿名認証

    func signInAnonymously() async throws {
        if let currentUser = Auth.auth().currentUser {
            currentUserUID = currentUser.uid
        } else {
            let result = try await Auth.auth().signInAnonymously()
            currentUserUID = result.user.uid
        }
        isInitialized = true
    }

    // MARK: - あいことば生成・付与

    func assignJoinCodeIfNeeded(documentID: String) async throws -> String {
        let code = try await generateJoinCode()
        try await db.collection("events").document(documentID).updateData([
            "joinCode": code
        ])
        return code
    }

    private func generateJoinCode() async throws -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // 紛らわしい文字(0,O,1,I)を除外
        for _ in 0..<10 { // 最大10回リトライ
            let code = String((0..<6).map { _ in chars.randomElement()! })
            // 重複チェック
            let snapshot = try await db.collection("events")
                .whereField("joinCode", isEqualTo: code)
                .getDocuments()
            if snapshot.documents.isEmpty {
                return code
            }
        }
        // フォールバック: 8文字にして衝突確率をさらに下げる
        let chars8 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<8).map { _ in chars8.randomElement()! })
    }

    // MARK: - イベント作成

    func createEvent(_ event: Event) async throws -> (documentID: String, joinCode: String) {
        guard let uid = currentUserUID else { throw FirebaseError.notAuthenticated }

        let joinCode = try await generateJoinCode()
        let docRef = db.collection("events").document()
        let firestoreEvent = event.toFirestore(ownerUID: uid, memberUIDs: [uid], joinCode: joinCode)

        let encoder = Firestore.Encoder()
        let data = try encoder.encode(firestoreEvent)
        try await docRef.setData(data)
        return (docRef.documentID, joinCode)
    }

    // MARK: - イベント更新

    func updateEvent(_ event: Event, documentID: String) async throws {
        let docRef = db.collection("events").document(documentID)

        let encoder = Firestore.Encoder()
        let participantsData = try event.participants.map { try encoder.encode($0.toFirestore()) }

        var updateData: [String: Any] = [
            "title": event.title,
            "dateSlots": event.dateSlots.sorted().map { $0.isoString },
            "participants": participantsData,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let confirmed = event.confirmedInfo {
            updateData["confirmedInfo"] = try encoder.encode(confirmed.toFirestore())
        } else {
            updateData["confirmedInfo"] = FieldValue.delete()
        }

        try await docRef.updateData(updateData)
    }

    // MARK: - イベント削除

    func deleteEvent(documentID: String) async throws {
        try await db.collection("events").document(documentID).delete()
    }

    // MARK: - イベント参加

    func joinEvent(documentID: String) async throws -> Event? {
        guard let uid = currentUserUID else { throw FirebaseError.notAuthenticated }

        let docRef = db.collection("events").document(documentID)
        let snapshot = try await docRef.getDocument()

        guard snapshot.exists, let data = snapshot.data() else {
            return nil
        }

        // memberUIDsに追加
        try await docRef.updateData([
            "memberUIDs": FieldValue.arrayUnion([uid])
        ])

        let decoder = Firestore.Decoder()
        let firestoreEvent = try decoder.decode(FirestoreEvent.self, from: data)

        // documentIDからUUIDを生成（一貫性のため）
        let eventUUID = UUID(uuidString: documentID) ?? UUID(uuidString: String(documentID.prefix(36))) ?? UUID()
        return Event.fromFirestore(firestoreEvent, id: eventUUID)
    }

    // MARK: - あいことばでイベント検索

    func fetchEventByJoinCode(_ code: String) async throws -> (documentID: String, event: Event)? {
        let snapshot = try await db.collection("events")
            .whereField("joinCode", isEqualTo: code.uppercased())
            .getDocuments()

        guard let doc = snapshot.documents.first else { return nil }

        let decoder = Firestore.Decoder()
        let firestoreEvent = try decoder.decode(FirestoreEvent.self, from: doc.data())
        let eventUUID = UUID(uuidString: doc.documentID) ?? UUID()
        return (doc.documentID, Event.fromFirestore(firestoreEvent, id: eventUUID))
    }

    // MARK: - あいことばでイベント参加

    func joinEventByCode(_ code: String) async throws -> (documentID: String, event: Event)? {
        guard let uid = currentUserUID else { throw FirebaseError.notAuthenticated }

        guard let result = try await fetchEventByJoinCode(code) else { return nil }

        // memberUIDsに追加
        try await db.collection("events").document(result.documentID).updateData([
            "memberUIDs": FieldValue.arrayUnion([uid])
        ])

        return result
    }

    // MARK: - イベント取得（プレビュー用）

    func fetchEvent(documentID: String) async throws -> Event? {
        let snapshot = try await db.collection("events").document(documentID).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }

        let decoder = Firestore.Decoder()
        let firestoreEvent = try decoder.decode(FirestoreEvent.self, from: data)
        let eventUUID = UUID(uuidString: documentID) ?? UUID()
        return Event.fromFirestore(firestoreEvent, id: eventUUID)
    }

    // MARK: - 手動同期（フェッチ）

    struct FetchedEvent {
        let event: Event
        let joinCode: String?
    }

    func fetchUserEvents() async throws -> [String: FetchedEvent] {
        guard let uid = currentUserUID else { throw FirebaseError.notAuthenticated }

        let snapshot = try await db.collection("events")
            .whereField("memberUIDs", arrayContains: uid)
            .getDocuments()

        let decoder = Firestore.Decoder()
        var events: [String: FetchedEvent] = [:]

        for doc in snapshot.documents {
            if let firestoreEvent = try? decoder.decode(FirestoreEvent.self, from: doc.data()) {
                let eventUUID = UUID(uuidString: doc.documentID) ?? UUID()
                let event = Event.fromFirestore(firestoreEvent, id: eventUUID)
                events[doc.documentID] = FetchedEvent(event: event, joinCode: firestoreEvent.joinCode)
            }
        }
        return events
    }
}
