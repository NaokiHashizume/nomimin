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
        FirestoreConfirmedInfo(shopName: shopName, date: date, time: time, memo: memo)
    }

    static func fromFirestore(_ fc: FirestoreConfirmedInfo) -> ConfirmedInfo {
        ConfirmedInfo(shopName: fc.shopName, date: fc.date, time: fc.time, memo: fc.memo)
    }
}

extension Event {
    func toFirestore(ownerUID: String, memberUIDs: [String]) -> FirestoreEvent {
        FirestoreEvent(
            title: title,
            ownerUID: ownerUID,
            memberUIDs: memberUIDs,
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

    private let db = Firestore.firestore()
    private var eventListeners: [String: ListenerRegistration] = [:]

    private init() {}

    // MARK: - 初期化

    func configure() {
        FirebaseApp.configure()
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

    // MARK: - イベント作成

    func createEvent(_ event: Event) async throws -> String {
        guard let uid = currentUserUID else { throw FirebaseError.notAuthenticated }

        let docRef = db.collection("events").document()
        let firestoreEvent = event.toFirestore(ownerUID: uid, memberUIDs: [uid])

        let encoder = Firestore.Encoder()
        let data = try encoder.encode(firestoreEvent)
        try await docRef.setData(data)
        return docRef.documentID
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

    // MARK: - イベント取得（プレビュー用）

    func fetchEvent(documentID: String) async throws -> Event? {
        let snapshot = try await db.collection("events").document(documentID).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }

        let decoder = Firestore.Decoder()
        let firestoreEvent = try decoder.decode(FirestoreEvent.self, from: data)
        let eventUUID = UUID(uuidString: documentID) ?? UUID()
        return Event.fromFirestore(firestoreEvent, id: eventUUID)
    }

    // MARK: - リアルタイムリスナー

    func listenToUserEvents(onChange: @escaping ([String: Event]) -> Void) {
        guard let uid = currentUserUID else { return }

        removeListener(for: "userEvents")

        let listener = db.collection("events")
            .whereField("memberUIDs", arrayContains: uid)
            .addSnapshotListener { snapshot, error in
                guard let documents = snapshot?.documents else { return }

                let decoder = Firestore.Decoder()
                var events: [String: Event] = [:]

                for doc in documents {
                    if let firestoreEvent = try? decoder.decode(FirestoreEvent.self, from: doc.data()) {
                        let eventUUID = UUID(uuidString: doc.documentID) ?? UUID()
                        events[doc.documentID] = Event.fromFirestore(firestoreEvent, id: eventUUID)
                    }
                }
                onChange(events)
            }
        eventListeners["userEvents"] = listener
    }

    func listenToEvent(documentID: String, onChange: @escaping (Event?) -> Void) {
        removeListener(for: documentID)

        let listener = db.collection("events").document(documentID)
            .addSnapshotListener { snapshot, error in
                guard let snapshot = snapshot, snapshot.exists, let data = snapshot.data() else {
                    onChange(nil)
                    return
                }

                let decoder = Firestore.Decoder()
                if let firestoreEvent = try? decoder.decode(FirestoreEvent.self, from: data) {
                    let eventUUID = UUID(uuidString: documentID) ?? UUID()
                    onChange(Event.fromFirestore(firestoreEvent, id: eventUUID))
                }
            }
        eventListeners[documentID] = listener
    }

    func removeListener(for key: String) {
        eventListeners[key]?.remove()
        eventListeners.removeValue(forKey: key)
    }

    func removeAllListeners() {
        eventListeners.values.forEach { $0.remove() }
        eventListeners.removeAll()
    }
}
