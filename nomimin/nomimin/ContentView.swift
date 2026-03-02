import SwiftUI
import MapKit
import Combine
import WebKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#if !targetEnvironment(simulator)
import GoogleMobileAds
#endif
#endif

// MARK: - プラットフォーム共通ユーティリティ

func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

// MARK: - 共有ユーティリティ

#if os(iOS)
func presentShareSheet(text: String) {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = windowScene.windows.first?.rootViewController else { return }
    var topVC = root
    while let presented = topVC.presentedViewController {
        topVC = presented
    }
    let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    if let popover = activityVC.popoverPresentationController {
        popover.sourceView = topVC.view
        popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
    topVC.present(activityVC, animated: true)
}
#endif

// MARK: - データモデル

enum Availability: String, CaseIterable, Identifiable, Codable {
    case yes = "◯"
    case maybe = "△"
    case no = "×"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .yes:   return .green
        case .maybe: return .orange
        case .no:    return .red
        }
    }
}

struct Participant: Identifiable, Codable {
    let id: UUID
    var name: String
    var nearestStation: String
    var availabilities: [DateSlot: Availability]

    init(id: UUID = UUID(), name: String, nearestStation: String, availabilities: [DateSlot: Availability]) {
        self.id = id
        self.name = name
        self.nearestStation = nearestStation
        self.availabilities = availabilities
    }

    enum CodingKeys: String, CodingKey {
        case id, name, nearestStation, availabilities
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(nearestStation, forKey: .nearestStation)
        let pairs = availabilities.map { AvailabilityEntry(dateSlot: $0.key, availability: $0.value) }
        try container.encode(pairs, forKey: .availabilities)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        nearestStation = try container.decode(String.self, forKey: .nearestStation)
        let pairs = try container.decode([AvailabilityEntry].self, forKey: .availabilities)
        availabilities = Dictionary(uniqueKeysWithValues: pairs.map { ($0.dateSlot, $0.availability) })
    }
}

private struct AvailabilityEntry: Codable {
    let dateSlot: DateSlot
    let availability: Availability
}

struct DateSlot: Hashable, Comparable, Codable {
    let date: Date

    var display: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        return f.string(from: date)
    }

    static func < (lhs: DateSlot, rhs: DateSlot) -> Bool {
        lhs.date < rhs.date
    }
}

// MARK: - 確定情報

struct ConfirmedInfo: Codable {
    var shopName: String
    var date: Date
    var time: Date
    var memo: String

    var displayDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(E)"
        return f.string(from: date)
    }

    var displayTime: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f.string(from: time)
    }

    func shareSummary(participants: [String]) -> String {
        var lines: [String] = []
        lines.append("🍻 飲み会のお知らせ")
        lines.append("")
        lines.append("📅 日時: \(displayDate) \(displayTime)〜")
        lines.append("🏠 お店: \(shopName)")
        if !memo.isEmpty {
            lines.append("📝 備考: \(memo)")
        }
        lines.append("")
        lines.append("👥 参加メンバー:")
        for name in participants {
            lines.append("  ・\(name)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - イベント管理

enum EventStatus: String, Codable {
    case planning = "調整中"
    case confirmed = "確定"
}

struct Event: Identifiable, Codable {
    let id: UUID
    var title: String
    var participants: [Participant]
    var dateSlots: [DateSlot]
    var confirmedInfo: ConfirmedInfo?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, participants: [Participant] = [], dateSlots: [DateSlot] = [], confirmedInfo: ConfirmedInfo? = nil) {
        self.id = id
        self.title = title
        self.participants = participants
        self.dateSlots = dateSlots
        self.confirmedInfo = confirmedInfo
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var status: EventStatus {
        confirmedInfo != nil ? .confirmed : .planning
    }

    var dateRange: String? {
        let sorted = dateSlots.sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if first == last { return first.display }
        return "\(first.display) ~ \(last.display)"
    }
}

@MainActor
class EventStore: ObservableObject {
    @Published var events: [Event] = []

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("nomimin", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("events.json")
    }

    init() {
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            events = try decoder.decode([Event].self, from: data)
        } catch {
            print("Failed to load events: \(error)")
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(events)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            print("Failed to save events: \(error)")
        }
    }

    func addEvent(title: String) -> Event {
        let event = Event(title: title)
        events.append(event)
        save()
        return event
    }

    func deleteEvent(id: UUID) {
        events.removeAll { $0.id == id }
        save()
    }

    func importEvent(from data: SharedEventData) {
        if events.contains(where: { $0.id.uuidString == data.id }) { return }
        let dateSlots = data.d.map { DateSlot(date: Date(timeIntervalSince1970: $0)) }
        let event = Event(
            id: UUID(uuidString: data.id) ?? UUID(),
            title: data.t,
            participants: [],
            dateSlots: dateSlots
        )
        events.append(event)
        save()
    }

    func binding(for eventID: UUID) -> Binding<Event>? {
        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return nil }
        return Binding(
            get: { self.events[index] },
            set: { newValue in
                self.events[index] = newValue
                self.events[index].updatedAt = Date()
                self.save()
            }
        )
    }
}

// MARK: - イベント共有リンク

struct SharedEventData: Codable {
    let t: String         // title
    let d: [TimeInterval] // dateSlots (timeIntervalSince1970)
    let id: String        // original event UUID
}

struct EventShareCoder {
    static func encode(event: Event) -> URL? {
        let shared = SharedEventData(
            t: event.title,
            d: event.dateSlots.sorted().map { $0.date.timeIntervalSince1970 },
            id: event.id.uuidString
        )
        guard let jsonData = try? JSONEncoder().encode(shared) else { return nil }

        let compressed = (try? (jsonData as NSData).compressed(using: .zlib) as Data) ?? jsonData

        let base64 = compressed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var components = URLComponents()
        components.scheme = "nomimin"
        components.host = "event"
        components.queryItems = [URLQueryItem(name: "d", value: base64)]
        return components.url
    }

    static func decode(url: URL) -> SharedEventData? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "nomimin",
              components.host == "event",
              let base64 = components.queryItems?.first(where: { $0.name == "d" })?.value
        else { return nil }

        var base64Std = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64Std.count % 4
        if remainder > 0 { base64Std += String(repeating: "=", count: 4 - remainder) }

        guard let compressed = Data(base64Encoded: base64Std) else { return nil }
        let jsonData = (try? (compressed as NSData).decompressed(using: .zlib) as Data) ?? compressed
        return try? JSONDecoder().decode(SharedEventData.self, from: jsonData)
    }
}

// MARK: - 中間地点検索結果

struct StationResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let mapItem: MKMapItem

    func openInMaps() {
        mapItem.openInMaps(launchOptions: nil)
    }
}

// MARK: - ホットペッパーAPIレスポンスモデル

struct HotPepperResponse: Codable {
    let results: HotPepperResults
}

struct HotPepperResults: Codable {
    let shop: [HotPepperShop]?
}

struct HotPepperShop: Codable {
    let id: String
    let name: String
    let address: String
    let access: String
    let lat: Double
    let lng: Double
    let open: String
    let genre: HotPepperGenre
    let budget: HotPepperBudget?
    let photo: HotPepperPhoto
    let urls: HotPepperURLs
    let coupon_urls: HotPepperURLs?
}

struct HotPepperGenre: Codable {
    let name: String
    let `catch`: String?
}

struct HotPepperBudget: Codable {
    let name: String?
    let average: String?
}

struct HotPepperPhoto: Codable {
    let pc: HotPepperPhotoSize?
    let mobile: HotPepperPhotoSize?
}

struct HotPepperPhotoSize: Codable {
    let l: String?
    let m: String?
    let s: String?
}

struct HotPepperURLs: Codable {
    let pc: String?
}

// MARK: - 飲食店検索結果

struct ShopResult: Identifiable {
    let id: String
    let name: String
    let category: String
    let address: String
    let access: String
    let budget: String
    let openTime: String
    let photoURL: URL?
    let hotpepperURL: URL?
    let couponURL: URL?
    let latitude: Double
    let longitude: Double

    @MainActor
    func openInMaps() {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = name
        mapItem.openInMaps()
    }
}

// MARK: - 中間地点検索サービス

@MainActor
class MidpointSearchService: ObservableObject {
    @Published var isSearching = false
    @Published var nearbyStations: [StationResult] = []
    @Published var centerCoordinate: CLLocationCoordinate2D?
    @Published var errorMessage: String?

    @Published var isSearchingShops = false
    @Published var shops: [ShopResult] = []
    @Published var shopErrorMessage: String?

    func search(stations: [String]) async {
        guard !stations.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        nearbyStations = []
        centerCoordinate = nil

        var coordinates: [CLLocationCoordinate2D] = []

        for station in stations {
            let request = MKLocalSearch.Request()
            let query = station.hasSuffix("駅") ? station : station + "駅"
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
                span: MKCoordinateSpan(latitudeDelta: 10.0, longitudeDelta: 10.0)
            )

            if let coord = await performSearch(request: request) {
                coordinates.append(coord)
            }
        }

        guard !coordinates.isEmpty else {
            errorMessage = "駅の位置情報が取得できませんでした。\n駅名が正しいか確認してください。"
            isSearching = false
            return
        }

        let avgLat = coordinates.map { $0.latitude }.reduce(0, +) / Double(coordinates.count)
        let avgLon = coordinates.map { $0.longitude }.reduce(0, +) / Double(coordinates.count)
        let center = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
        centerCoordinate = center

        let nearbyRequest = MKLocalSearch.Request()
        nearbyRequest.naturalLanguageQuery = "駅"
        nearbyRequest.region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )

        let nearbySearch = MKLocalSearch(request: nearbyRequest)
        do {
            let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MKLocalSearch.Response, Error>) in
                nearbySearch.start { response, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else if let response = response {
                        cont.resume(returning: response)
                    } else {
                        cont.resume(throwing: NSError(domain: "MidpointSearch", code: -1))
                    }
                }
            }
            nearbyStations = response.mapItems.prefix(5).map { Self.toStationResult($0) }
        } catch {
            errorMessage = "中間地点付近の駅を検索できませんでした。"
        }

        isSearching = false
    }

    private func performSearch(request: MKLocalSearch.Request) async -> CLLocationCoordinate2D? {
        let searchObj = MKLocalSearch(request: request)
        let response = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<MKLocalSearch.Response, Error>) in
            searchObj.start { response, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let response = response {
                    cont.resume(returning: response)
                } else {
                    cont.resume(throwing: NSError(domain: "MidpointSearch", code: -1))
                }
            }
        }
        guard let item = response?.mapItems.first else { return nil }
        return Self.extractCoordinate(from: item)
    }

    private static func extractCoordinate(from item: MKMapItem) -> CLLocationCoordinate2D {
        item.location.coordinate
    }

    private static func toStationResult(_ item: MKMapItem) -> StationResult {
        return StationResult(name: item.name ?? "不明な駅", address: "", mapItem: item)
    }

    // MARK: - 飲食店検索（ホットペッパーAPI）

    private let hotpepperAPIKey = "8fb7a3475e5af02f"

    func searchShops(keyword stationName: String) async {
        isSearchingShops = true
        shopErrorMessage = nil
        shops = []

        var components = URLComponents(string: "https://webservice.recruit.co.jp/hotpepper/gourmet/v1/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: hotpepperAPIKey),
            URLQueryItem(name: "keyword", value: stationName),
            URLQueryItem(name: "order", value: "4"),
            URLQueryItem(name: "count", value: "20"),
            URLQueryItem(name: "format", value: "json"),
        ]

        guard let url = components.url else {
            shopErrorMessage = "検索URLの生成に失敗しました。"
            isSearchingShops = false
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(HotPepperResponse.self, from: data)
            shops = (decoded.results.shop ?? []).map { Self.toShopResult($0) }
            if shops.isEmpty {
                shopErrorMessage = "この付近にホットペッパー掲載店が見つかりませんでした。"
            }
        } catch {
            print("HotPepper API error: \(error)")
            shopErrorMessage = "飲食店の検索に失敗しました。\n\(error.localizedDescription)"
        }

        isSearchingShops = false
    }

    private static func toShopResult(_ shop: HotPepperShop) -> ShopResult {
        let photoURLString = shop.photo.mobile?.l ?? shop.photo.pc?.l
        let hotpepperURLString = shop.urls.pc
        let couponURLString = shop.coupon_urls?.pc

        return ShopResult(
            id: shop.id,
            name: shop.name,
            category: shop.genre.name,
            address: shop.address,
            access: shop.access,
            budget: shop.budget?.name ?? "",
            openTime: shop.open,
            photoURL: photoURLString.flatMap { URL(string: $0) },
            hotpepperURL: hotpepperURLString.flatMap { URL(string: $0) },
            couponURL: couponURLString.flatMap { URL(string: $0) },
            latitude: shop.lat,
            longitude: shop.lng
        )
    }
}

// MARK: - イベント一覧ビュー

enum AppearanceMode: String, CaseIterable {
    case auto = "自動"
    case light = "ライト"
    case dark = "ダーク"

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var icon: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

struct EventListView: View {
    @ObservedObject var store: EventStore
    @Binding var pendingImport: SharedEventData?
    @State private var showingNewEvent = false
    @State private var newEventTitle = ""
    @State private var editingEventID: UUID?
    @State private var editingEventTitle = ""
    @State private var splitBillEventID: UUID?
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.auto.rawValue

    var body: some View {
        NavigationStack {
            Group {
                if store.events.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "party.popper")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("飲み会イベントがありません")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Button {
                            showingNewEvent = true
                        } label: {
                            Label("新しい飲み会を作成", systemImage: "plus.circle.fill")
                                .font(.body.bold())
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.events.sorted(by: { $0.updatedAt > $1.updatedAt })) { event in
                            NavigationLink(value: event.id) {
                                EventRow(event: event) {
                                    splitBillEventID = event.id
                                }
                            }
                            .contextMenu {
                                Button {
                                    editingEventTitle = event.title
                                    editingEventID = event.id
                                } label: {
                                    Label("名前を変更", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    store.deleteEvent(id: event.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { offsets in
                            let sorted = store.events.sorted(by: { $0.updatedAt > $1.updatedAt })
                            for offset in offsets {
                                store.deleteEvent(id: sorted[offset].id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("のみみん")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showingNewEvent = true
                    } label: {
                        Label("新規作成", systemImage: "plus")
                    }

                    Menu {
                        Menu {
                            ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                                Button {
                                    appearanceMode = mode.rawValue
                                } label: {
                                    Label {
                                        Text(mode.rawValue)
                                    } icon: {
                                        if appearanceMode == mode.rawValue {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("外観モード", systemImage: (AppearanceMode(rawValue: appearanceMode) ?? .auto).icon)
                        }
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { eventID in
                if let binding = store.binding(for: eventID) {
                    ContentView(event: binding)
                }
            }
            .alert("新しい飲み会", isPresented: $showingNewEvent) {
                TextField("イベント名", text: $newEventTitle)
                Button("作成") {
                    let title = newEventTitle.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty {
                        let _ = store.addEvent(title: title)
                    }
                    newEventTitle = ""
                }
                Button("キャンセル", role: .cancel) { newEventTitle = "" }
            } message: {
                Text("イベント名を入力してください")
            }
            .alert("イベント名を変更", isPresented: Binding(
                get: { editingEventID != nil },
                set: { if !$0 { editingEventID = nil } }
            )) {
                TextField("イベント名", text: $editingEventTitle)
                Button("変更") {
                    let title = editingEventTitle.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty, let id = editingEventID {
                        if let index = store.events.firstIndex(where: { $0.id == id }) {
                            store.events[index].title = title
                            store.save()
                        }
                    }
                    editingEventID = nil
                }
                Button("キャンセル", role: .cancel) { editingEventID = nil }
            }
            .sheet(isPresented: Binding(
                get: { splitBillEventID != nil },
                set: { if !$0 { splitBillEventID = nil } }
            )) {
                if let id = splitBillEventID,
                   let event = store.events.first(where: { $0.id == id }) {
                    SplitBillSheet(participantNames: event.participants.map { $0.name })
                }
            }
            .alert("イベントの招待", isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            )) {
                Button("参加する") {
                    if let data = pendingImport {
                        store.importEvent(from: data)
                    }
                    pendingImport = nil
                }
                Button("キャンセル", role: .cancel) { pendingImport = nil }
            } message: {
                if let data = pendingImport {
                    Text("「\(data.t)」（\(data.d.count)つの候補日）\nに参加しますか？")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 400)
        #endif
        .preferredColorScheme((AppearanceMode(rawValue: appearanceMode) ?? .auto).colorScheme)
    }
}

struct EventRow: View {
    let event: Event
    var onSplitBill: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.body.bold())

                if let info = event.confirmedInfo {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Label("\(event.participants.count)人", systemImage: "person.2")
                            Label("\(info.displayDate) \(info.displayTime)〜", systemImage: "calendar")
                        }
                        Label(info.shopName, systemImage: "mappin.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Label("\(event.participants.count)人", systemImage: "person.2")
                        if let range = event.dateRange {
                            Label(range, systemImage: "calendar")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if event.confirmedInfo != nil, event.participants.count >= 2, let action = onSplitBill {
                Button {
                    action()
                } label: {
                    Label("割勘", systemImage: "yensign.circle")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.purple.opacity(0.2)))
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
            }

            Text(event.status.rawValue)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(event.status == .confirmed ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                )
                .foregroundStyle(event.status == .confirmed ? .green : .blue)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - メインビュー（イベント詳細）

struct ContentView: View {
    @Binding var event: Event
    @State private var showingAddDate = false
    @State private var showingAddParticipant = false
    @State private var showingMidpoint = false
    @State private var showingSplitBill = false
    @State private var showingConfirm = false
    @State private var editingStationIndex: Int?

    private var participantsWithStations: [String] {
        event.participants.compactMap { p in
            let s = p.nearestStation.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 確定情報カード
            if let info = event.confirmedInfo {
                confirmedCard(info: info)
            }

                // メインコンテンツ
                if event.dateSlots.isEmpty {
                    emptyActionView(
                        icon: "calendar.badge.plus",
                        title: "日程を追加しましょう",
                        buttonLabel: "候補日を追加",
                        buttonIcon: "calendar.badge.plus"
                    ) {
                        showingAddDate = true
                    }
                } else if event.participants.isEmpty {
                    emptyActionView(
                        icon: "person.2",
                        title: "参加者を追加しましょう",
                        buttonLabel: "参加者を追加",
                        buttonIcon: "person.badge.plus"
                    ) {
                        showingAddParticipant = true
                    }
                } else {
                    scheduleTable
                }

                #if os(iOS)
                BannerAdView()
                    .frame(height: 50)
                #endif

                summaryBar
            }
        .navigationTitle(event.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAddDate = true
                } label: {
                    Label("日程追加", systemImage: "calendar.badge.plus")
                }

                Button {
                    showingAddParticipant = true
                } label: {
                    Label("参加者追加", systemImage: "person.badge.plus")
                }
                .disabled(event.dateSlots.isEmpty)

                Menu {
                    if !event.participants.isEmpty {
                        Button {
                            showingConfirm = true
                        } label: {
                            Label("確定", systemImage: "checkmark.seal.fill")
                        }

                        Button {
                            showingSplitBill = true
                        } label: {
                            Label("割り勘", systemImage: "yensign.circle")
                        }
                    }

                    if participantsWithStations.count >= 2 {
                        Button {
                            showingMidpoint = true
                        } label: {
                            Label("中間地点を探す", systemImage: "mappin.and.ellipse")
                        }
                    }

                    if !event.participants.isEmpty || participantsWithStations.count >= 2 {
                        Divider()
                    }
                } label: {
                    Label("その他", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingAddDate) {
            AddDateSheet(dateSlots: $event.dateSlots)
        }
        .sheet(isPresented: $showingAddParticipant) {
            AddParticipantSheet(dateSlots: event.dateSlots) { newParticipant in
                event.participants.append(newParticipant)
            }
        }
        .sheet(isPresented: $showingMidpoint) {
            MidpointSheet(stations: participantsWithStations)
        }
        .sheet(isPresented: $showingSplitBill) {
            SplitBillSheet(participantNames: event.participants.map { $0.name })
        }
        .sheet(isPresented: $showingConfirm) {
            ConfirmSheet(
                participantNames: event.participants.map { $0.name },
                existingInfo: event.confirmedInfo,
                topSlotDate: topSlotDate
            ) { info in
                event.confirmedInfo = info
            }
        }
        .sheet(isPresented: Binding(
            get: { editingStationIndex != nil },
            set: { if !$0 { editingStationIndex = nil } }
        )) {
            if let index = editingStationIndex, index < event.participants.count {
                EditStationSheet(
                    name: event.participants[index].name,
                    station: event.participants[index].nearestStation
                ) { newStation in
                    event.participants[index].nearestStation = newStation
                }
            }
        }
    }

    // MARK: - 確定情報カード

    private func confirmedCard(info: ConfirmedInfo) -> some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("飲み会が確定しました！")
                    .font(.subheadline.bold())
                Spacer()
                Button(role: .destructive) {
                    event.confirmedInfo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // 詳細
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "building.2").font(.caption).foregroundStyle(.blue).frame(width: 18)
                    Text(info.shopName).font(.subheadline)
                }
                HStack(spacing: 8) {
                    Image(systemName: "calendar").font(.caption).foregroundStyle(.blue).frame(width: 18)
                    Text(info.displayDate).font(.subheadline)
                }
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.caption).foregroundStyle(.blue).frame(width: 18)
                    Text("\(info.displayTime)〜").font(.subheadline)
                }
                if !info.memo.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "note.text").font(.caption).foregroundStyle(.blue).frame(width: 18)
                        Text(info.memo).font(.subheadline)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "person.2").font(.caption).foregroundStyle(.blue).frame(width: 18)
                    Text(event.participants.map { $0.name }.joined(separator: "、"))
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)

            Divider().padding(.horizontal)

            // アクションボタン
            HStack(spacing: 12) {
                Button {
                    #if os(iOS)
                    presentShareSheet(text: info.shareSummary(participants: event.participants.map { $0.name }))
                    #else
                    copyToClipboard(info.shareSummary(participants: event.participants.map { $0.name }))
                    #endif
                } label: {
                    Label("共有", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    showingConfirm = true
                } label: {
                    Label("編集", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color.green.opacity(0.06))
    }

    // MARK: - 空状態ビュー

    private func emptyActionView(icon: String, title: String, buttonLabel: String, buttonIcon: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.blue.opacity(0.5))

            Text(title)
                .font(.headline)

            Button(action: action) {
                Label(buttonLabel, systemImage: buttonIcon)
                    .font(.body.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - スケジュール表

    private var scheduleTable: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                // 固定日程列（左）
                VStack(spacing: 0) {
                    dateColumnHeader
                    Divider()
                    ForEach(event.dateSlots.sorted(), id: \.self) { slot in
                        dateRowCell(slot: slot)
                        Divider()
                    }
                }
                #if os(iOS)
                .frame(width: 110)
                #else
                .frame(width: 130)
                #endif

                Divider()

                // スクロール可能な参加者列（右）
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        participantHeaderRow
                        Divider()
                        ForEach(event.dateSlots.sorted(), id: \.self) { slot in
                            availabilityRow(slot: slot)
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var dateColumnHeader: some View {
        Text("日程")
            .font(.caption.bold())
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.gray.opacity(0.15))
    }

    /// 日程のスコアを計算（⚪︎=2点、△=1点、×=0点）
    private func slotScore(_ slot: DateSlot) -> Int {
        event.participants.reduce(0) { total, p in
            switch p.availabilities[slot] ?? .no {
            case .yes: return total + 2
            case .maybe: return total + 1
            case .no: return total + 0
            }
        }
    }

    private var maxSlotScore: Int {
        guard !event.participants.isEmpty else { return 0 }
        return event.dateSlots.map { slotScore($0) }.max() ?? 0
    }

    private func isTopSlot(_ slot: DateSlot) -> Bool {
        guard !event.participants.isEmpty, maxSlotScore > 0 else { return false }
        return slotScore(slot) == maxSlotScore
    }

    private func headerBackground(for slot: DateSlot) -> Color {
        if isTopSlot(slot) {
            return Color.green.opacity(0.25)
        }
        return Color.gray.opacity(0.15)
    }

    private func columnHighlight(for slot: DateSlot) -> Color {
        if isTopSlot(slot) {
            return Color.green.opacity(0.12)
        }
        return .clear
    }

    private var participantHeaderRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(event.participants.enumerated()), id: \.element.id) { index, participant in
                let hasStation = !participant.nearestStation.trimmingCharacters(in: .whitespaces).isEmpty

                ZStack(alignment: .topTrailing) {
                    Button {
                        editingStationIndex = index
                    } label: {
                        VStack(spacing: 2) {
                            Text(participant.name)
                                .font(.caption.bold())
                                .lineLimit(1)
                            if hasStation {
                                HStack(spacing: 2) {
                                    Image(systemName: "tram.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.blue)
                                    Text(participant.nearestStation)
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .lineLimit(1)
                                }
                            } else {
                                HStack(spacing: 2) {
                                    Image(systemName: "tram")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary.opacity(0.5))
                                    Text("最寄駅")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary.opacity(0.5))
                                }
                            }
                        }
                        .frame(width: 80, height: 50)
                        .background(Color.gray.opacity(0.15))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation {
                            event.participants.removeAll { $0.id == participant.id }
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                }
            }
        }
    }

    private func dateRowCell(slot: DateSlot) -> some View {
        let yesCount = event.participants.filter { ($0.availabilities[slot] ?? .no) == .yes }.count
        let maybeCount = event.participants.filter { ($0.availabilities[slot] ?? .no) == .maybe }.count
        let slotIndex = event.dateSlots.sorted().firstIndex(of: slot) ?? 0
        let stripe = slotIndex % 2 == 0 ? Color.clear : Color.gray.opacity(0.05)

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.display)
                    .font(.caption.bold())
                if !event.participants.isEmpty {
                    HStack(spacing: 3) {
                        Text("◯\(yesCount)")
                            .foregroundStyle(.green)
                        Text("△\(maybeCount)")
                            .foregroundStyle(.orange)
                    }
                    .font(.system(size: 9))
                }
            }

            Spacer()

            Button {
                withAnimation {
                    event.dateSlots.removeAll { $0 == slot }
                    for i in event.participants.indices {
                        event.participants[i].availabilities.removeValue(forKey: slot)
                    }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 50)
        .padding(.horizontal, 4)
        .background(headerBackground(for: slot).overlay(stripe))
    }

    private func availabilityRow(slot: DateSlot) -> some View {
        let slotIndex = event.dateSlots.sorted().firstIndex(of: slot) ?? 0
        let stripe = slotIndex % 2 == 0 ? Color.clear : Color.gray.opacity(0.05)

        return HStack(spacing: 0) {
            ForEach(Array(event.participants.enumerated()), id: \.element.id) { index, participant in
                let avail = participant.availabilities[slot] ?? .no
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        cycleAvailability(participantIndex: index, slot: slot)
                    }
                } label: {
                    Text(avail.rawValue)
                        .font(.title2)
                        .foregroundStyle(avail.color)
                        .frame(width: 80, height: 50)
                        .background(columnHighlight(for: slot).overlay(stripe))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - サマリーバー

    private var summaryBar: some View {
        Group {
            if !event.dateSlots.isEmpty && !event.participants.isEmpty {
                VStack(spacing: 8) {
                    Divider()

                    Text(availabilityHintText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            showingAddDate = true
                        } label: {
                            Label("日程", systemImage: "calendar.badge.plus")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showingAddParticipant = true
                        } label: {
                            Label("追加", systemImage: "person.badge.plus")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showingMidpoint = true
                        } label: {
                            Label("お店", systemImage: "mappin.and.ellipse")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.1))
                                .foregroundStyle(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showingConfirm = true
                        } label: {
                            Label("確定", systemImage: "checkmark.seal.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showingSplitBill = true
                        } label: {
                            Label("割勘", systemImage: "yensign.circle")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.purple.opacity(0.1))
                                .foregroundStyle(.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        if !event.dateSlots.isEmpty {
                            Button {
                                if let url = EventShareCoder.encode(event: event) {
                                    let shareText = "「\(event.title)」の日程調整に参加してね！\n\(url.absoluteString)"
                                    #if os(iOS)
                                    presentShareSheet(text: shareText)
                                    #else
                                    copyToClipboard(shareText)
                                    #endif
                                }
                            } label: {
                                Label("招待", systemImage: "link")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.teal.opacity(0.1))
                                    .foregroundStyle(.teal)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var topSlotDate: Date? {
        guard !event.participants.isEmpty, !event.dateSlots.isEmpty else { return nil }
        let scores = event.dateSlots.map { slot -> (DateSlot, Int) in
            let score = event.participants.reduce(0) { total, p in
                switch p.availabilities[slot] ?? .no {
                case .yes: return total + 2
                case .maybe: return total + 1
                case .no: return total + 0
                }
            }
            return (slot, score)
        }
        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0.date
    }

    private var hasAllYesDate: Bool {
        event.dateSlots.contains { slot in
            let yesCount = event.participants.filter { ($0.availabilities[slot] ?? .no) == .yes }.count
            return yesCount == event.participants.count
        }
    }

    // MARK: - ヘルパー

    private var availabilityHintText: String {
        #if os(iOS)
        "タップで回答変更 ◯→△→×"
        #else
        "クリックで回答変更 ◯→△→×"
        #endif
    }

    private func cycleAvailability(participantIndex: Int, slot: DateSlot) {
        let current = event.participants[participantIndex].availabilities[slot] ?? .no
        let next: Availability
        switch current {
        case .yes:   next = .maybe
        case .maybe: next = .no
        case .no:    next = .yes
        }
        event.participants[participantIndex].availabilities[slot] = next
    }
}

// MARK: - 日程追加シート

struct AddDateSheet: View {
    @Binding var dateSlots: [DateSlot]
    @Environment(\.dismiss) private var dismiss
    @State private var addedCount = 0
    @State private var currentMonth = Date()
    @State private var pendingDates: Set<Date> = []
    @State private var currentDragDates: Set<Date> = []
    @State private var preDragPendingDates: Set<Date> = []

    private var existingDateSet: Set<Date> {
        Set(dateSlots.map { Calendar.current.startOfDay(for: $0.date) })
    }

    private var daysInMonth: [Date?] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: currentMonth)
        guard let firstDay = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstDay) else { return [] }
        let firstWeekday = cal.component(.weekday, from: firstDay) - 1
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for day in range {
            var dc = comps
            dc.day = day
            if let d = cal.date(from: dc) {
                days.append(cal.startOfDay(for: d))
            }
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var rowCount: Int {
        let count = daysInMonth.count
        return count == 0 ? 0 : count / 7
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("日程追加")
                .font(.headline)
                .padding(.top)

            Text("カレンダーをなぞって複数の候補日を選択")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 月ナビゲーション
            HStack {
                Button { moveMonth(-1) } label: {
                    Image(systemName: "chevron.left").font(.body.bold())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(monthYearString(for: currentMonth))
                    .font(.subheadline.bold())
                Spacer()
                Button { moveMonth(1) } label: {
                    Image(systemName: "chevron.right").font(.body.bold())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            // 曜日ヘッダー
            HStack(spacing: 0) {
                ForEach(Array(["日","月","火","水","木","金","土"].enumerated()), id: \.offset) { i, s in
                    Text(s)
                        .font(.caption2.bold())
                        .foregroundStyle(i == 0 ? .red : i == 6 ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)

            // カレンダーグリッド
            calendarGridView
                .padding(.horizontal, 8)

            // 選択した日程を追加ボタン
            if !pendingDates.isEmpty {
                Button {
                    addPendingDates()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("\(pendingDates.count)日を追加")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }

            // 追加済みの日程
            if !dateSlots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("追加済みの日程（\(dateSlots.count)件）")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(dateSlots.sorted(), id: \.self) { slot in
                                HStack(spacing: 4) {
                                    Text(slot.display)
                                        .font(.caption)
                                    Button {
                                        withAnimation { dateSlots.removeAll { $0 == slot } }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.gray.opacity(0.15)))
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            // ボトムバー
            HStack {
                if addedCount > 0 {
                    Text("\(addedCount)件追加しました")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !pendingDates.isEmpty {
                    Button("リセット") { pendingDates.removeAll() }
                        .foregroundStyle(.secondary)
                }
                Button("完了") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 340, height: 560)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: - カレンダーグリッド

    private var calendarGridView: some View {
        let days = daysInMonth
        let cellHeight: CGFloat = 38
        let vSpacing: CGFloat = 2
        let rows = rowCount
        let totalHeight = CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * vSpacing

        return GeometryReader { geo in
            let cellWidth = geo.size.width / 7.0

            VStack(spacing: vSpacing) {
                ForEach(Array(0..<rows), id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(Array(0..<7), id: \.self) { col in
                            let index = row * 7 + col
                            if index < days.count, let date = days[index] {
                                dayCell(date: date)
                                    .frame(width: cellWidth, height: cellHeight)
                            } else {
                                Color.clear
                                    .frame(width: cellWidth, height: cellHeight)
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if currentDragDates.isEmpty {
                            preDragPendingDates = pendingDates
                        }
                        if let date = dateForPoint(value.location, cellWidth: cellWidth, cellHeight: cellHeight, vSpacing: vSpacing, days: days) {
                            if !existingDateSet.contains(date) {
                                currentDragDates.insert(date)
                                pendingDates.insert(date)
                            }
                        }
                    }
                    .onEnded { _ in
                        if currentDragDates.count == 1, let date = currentDragDates.first {
                            if preDragPendingDates.contains(date) {
                                pendingDates.remove(date)
                            }
                        }
                        currentDragDates.removeAll()
                        preDragPendingDates.removeAll()
                    }
            )
        }
        .frame(height: totalHeight)
    }

    private func dayCell(date: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(date)
        let isExisting = existingDateSet.contains(date)
        let isPending = pendingDates.contains(date)
        let day = cal.component(.day, from: date)
        let weekday = cal.component(.weekday, from: date)

        return ZStack {
            if isExisting {
                Circle().fill(Color.green.opacity(0.3))
            } else if isPending {
                Circle().fill(Color.blue.opacity(0.3))
            } else if isToday {
                Circle().stroke(Color.blue, lineWidth: 1.5)
            }

            Text("\(day)")
                .font(.caption)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(
                    isExisting ? .green :
                    isPending ? .blue :
                    weekday == 1 ? .red :
                    weekday == 7 ? .blue :
                    .primary
                )
        }
    }

    // MARK: - ヘルパー

    private func dateForPoint(_ point: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat, vSpacing: CGFloat, days: [Date?]) -> Date? {
        let col = Int(point.x / cellWidth)
        let row = Int(point.y / (cellHeight + vSpacing))
        guard col >= 0, col < 7, row >= 0 else { return nil }
        let index = row * 7 + col
        guard index >= 0, index < days.count else { return nil }
        return days[index]
    }

    private func moveMonth(_ offset: Int) {
        if let m = Calendar.current.date(byAdding: .month, value: offset, to: currentMonth) {
            currentMonth = m
        }
    }

    private func monthYearString(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月"
        return f.string(from: date)
    }

    private func addPendingDates() {
        for date in pendingDates.sorted() {
            let slot = DateSlot(date: Calendar.current.startOfDay(for: date))
            if !dateSlots.contains(slot) {
                withAnimation {
                    dateSlots.append(slot)
                    addedCount += 1
                }
            }
        }
        pendingDates.removeAll()
    }
}

// MARK: - 参加者追加シート

struct AddParticipantSheet: View {
    let dateSlots: [DateSlot]
    let onAdd: (Participant) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nearestStation = ""
    @State private var availabilities: [DateSlot: Availability] = [:]

    var body: some View {
        VStack(spacing: 16) {
            Text("参加者追加")
                .font(.headline)
                .padding(.top)

            // 名前・最寄駅入力
            VStack(spacing: 10) {
                HStack {
                    Text("名前:")
                        .font(.body)
                        .frame(width: 60, alignment: .trailing)
                    TextField("名前を入力", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }

                HStack {
                    Text("最寄駅:")
                        .font(.body)
                        .frame(width: 60, alignment: .trailing)
                    TextField("例: 渋谷", text: $nearestStation)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
            }
            .padding(.horizontal)

            Divider()

            // 参加可否選択
            Text("参加可否を選択")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(dateSlots.sorted(), id: \.self) { slot in
                        HStack {
                            Text(slot.display)
                                .font(.body)
                                .frame(width: 80, alignment: .leading)

                            Spacer()

                            ForEach(Availability.allCases) { avail in
                                let isSelected = (availabilities[slot] ?? .no) == avail
                                Button {
                                    availabilities[slot] = avail
                                } label: {
                                    Text(avail.rawValue)
                                        .font(.title3)
                                        .frame(width: 40, height: 40)
                                        .background(
                                            Circle()
                                                .fill(isSelected ? avail.color.opacity(0.2) : Color.clear)
                                        )
                                        .overlay(
                                            Circle()
                                                .stroke(isSelected ? avail.color : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }

            Divider()

            // ボタン
            HStack {
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("追加") {
                    let participant = Participant(
                        name: name.trimmingCharacters(in: .whitespaces),
                        nearestStation: nearestStation.trimmingCharacters(in: .whitespaces),
                        availabilities: availabilities
                    )
                    onAdd(participant)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 360, height: 440)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .onAppear {
            for slot in dateSlots {
                availabilities[slot] = .yes
            }
        }
    }
}

// MARK: - 最寄駅編集シート

struct EditStationSheet: View {
    let name: String
    @State private var station: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(name: String, station: String, onSave: @escaping (String) -> Void) {
        self.name = name
        self._station = State(initialValue: station)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("\(name) の最寄駅")
                .font(.headline)
                .padding(.top)

            HStack {
                Image(systemName: "tram.fill")
                    .foregroundStyle(.blue)
                TextField("例: 渋谷", text: $station)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal)

            Spacer()

            HStack {
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存") {
                    onSave(station.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 280, height: 160)
        #else
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
        #endif
    }
}

// MARK: - アプリ内ブラウザ

#if os(iOS)
struct WebView: UIViewRepresentable {
    let url: URL
    let webView: WKWebView

    init(url: URL, webView: WKWebView) {
        self.url = url
        self.webView = webView
    }

    func makeUIView(context: Context) -> WKWebView {
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url?.host != url.host || uiView.url == nil {
            uiView.load(URLRequest(url: url))
        }
    }
}
#else
struct WebView: NSViewRepresentable {
    let url: URL
    let webView: WKWebView

    init(url: URL, webView: WKWebView) {
        self.url = url
        self.webView = webView
    }

    func makeNSView(context: Context) -> WKWebView {
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url?.host != url.host || nsView.url == nil {
            nsView.load(URLRequest(url: url))
        }
    }
}
#endif

struct HotPepperBrowserSheet: View {
    let shopName: String
    let shopURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var webView = WKWebView()

    var body: some View {
        VStack(spacing: 0) {
            // ナビバー
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Button { webView.goBack() } label: {
                        Image(systemName: "chevron.left").font(.body)
                    }
                    .buttonStyle(.plain)

                    Button { webView.goForward() } label: {
                        Image(systemName: "chevron.right").font(.body)
                    }
                    .buttonStyle(.plain)

                    Button { webView.reload() } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text(shopName)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // ホットペッパーラベル
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
                Text("ホットペッパー")
                    .font(.caption.bold())
                    .foregroundStyle(.pink)
            }
            .padding(.vertical, 6)

            Divider()

            WebView(url: shopURL, webView: webView)
        }
        #if os(macOS)
        .frame(width: 520, height: 680)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

// MARK: - 中間地点シート

struct MidpointSheet: View {
    let stations: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var service = MidpointSearchService()
    @State private var selectedStationKeyword: String?
    @State private var browserShop: (name: String, url: URL)?
    @State private var customStationName = ""
    @State private var isCustomSearch = false

    var body: some View {
        VStack(spacing: 0) {
            Text("お店の最寄駅を探す")
                .font(.headline)
                .padding()

            Divider()

            // 結果エリア
            Group {
                if service.isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("検索中...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMsg = service.errorMessage {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.orange)
                                Text(errorMsg)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)

                            // 参加者の最寄駅
                            if !stations.isEmpty {
                                participantStationsList
                            }

                            // 別の駅で検索
                            customStationSearchField

                            if isCustomSearch || selectedStationKeyword != nil {
                                Divider().padding(.vertical, 4)
                                shopListSection
                            }
                        }
                        .padding(.bottom, 12)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            // 中間地点の駅
                            if !service.nearbyStations.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("中間地点の駅")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal)

                                    ForEach(service.nearbyStations) { station in
                                        stationButton(name: station.name, isSelected: selectedStationKeyword == station.name, color: .purple) {
                                            withAnimation {
                                                selectedStationKeyword = station.name
                                                isCustomSearch = false
                                                customStationName = ""
                                            }
                                            Task {
                                                await service.searchShops(keyword: station.name)
                                            }
                                        }
                                    }
                                }
                            }

                            // 参加者の最寄駅
                            if !stations.isEmpty {
                                participantStationsList
                            }

                            // 別の駅で検索
                            customStationSearchField

                            // 飲食店リスト
                            if selectedStationKeyword != nil || isCustomSearch {
                                Divider().padding(.vertical, 4)
                                shopListSection
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }

            Divider()

            HStack {
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("再検索") {
                    selectedStationKeyword = nil
                    isCustomSearch = false
                    Task {
                        await service.search(stations: stations)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isSearching)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 460, height: 600)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .onAppear {
            Task {
                await service.search(stations: stations)
            }
        }
        .sheet(isPresented: Binding(
            get: { browserShop != nil },
            set: { if !$0 { browserShop = nil } }
        )) {
            if let shop = browserShop {
                HotPepperBrowserSheet(shopName: shop.name, shopURL: shop.url)
            }
        }
    }

    // MARK: - 飲食店リストセクション

    @ViewBuilder
    private var customStationSearchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("別の駅で検索")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("駅名を入力", text: $customStationName)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let keyword = customStationName.trimmingCharacters(in: .whitespaces)
                    guard !keyword.isEmpty else { return }
                    withAnimation {
                        selectedStationKeyword = nil
                        isCustomSearch = true
                    }
                    Task {
                        await service.searchShops(keyword: keyword)
                    }
                } label: {
                    Text("検索")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(customStationName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding(.top, 4)
    }

    private var participantStationsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("参加者の最寄駅")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ForEach(Array(stations.enumerated()), id: \.offset) { _, name in
                stationButton(name: name, isSelected: selectedStationKeyword == name, color: .blue) {
                    withAnimation {
                        selectedStationKeyword = name
                        isCustomSearch = false
                        customStationName = ""
                    }
                    Task {
                        await service.searchShops(keyword: name)
                    }
                }
            }
        }
    }

    private func stationButton(name: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tram.fill")
                    .font(.body)
                    .foregroundStyle(isSelected ? .white : color)
                    .frame(width: 24)

                Text(name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? color : color.opacity(0.05))
        )
        .padding(.horizontal)
    }

    private var shopListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.orange)
                Text("\(selectedStationKeyword ?? customStationName)周辺のお店")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            if service.isSearchingShops {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("お店を検索中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if let errorMsg = service.shopErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            } else {
                ForEach(service.shops) { shop in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            // 写真サムネイル
                            if let photoURL = shop.photoURL {
                                AsyncImage(url: photoURL) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.gray.opacity(0.2)
                                        .overlay(
                                            Image(systemName: "fork.knife")
                                                .foregroundStyle(.gray)
                                        )
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(shop.name)
                                    .font(.body.weight(.medium))
                                    .lineLimit(2)

                                Text(shop.category)
                                    .font(.caption)
                                    .foregroundStyle(.orange)

                                if !shop.budget.isEmpty {
                                    HStack(spacing: 3) {
                                        Image(systemName: "yensign.circle")
                                            .font(.system(size: 10))
                                        Text(shop.budget)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                if !shop.access.isEmpty {
                                    HStack(spacing: 3) {
                                        Image(systemName: "figure.walk")
                                            .font(.system(size: 10))
                                        Text(shop.access)
                                            .lineLimit(1)
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()
                        }

                        // アクションボタン
                        HStack(spacing: 8) {
                            Spacer()

                            Button {
                                shop.openInMaps()
                            } label: {
                                Label("地図", systemImage: "map")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if let couponURL = shop.couponURL {
                                Button {
                                    browserShop = (name: shop.name, url: couponURL)
                                } label: {
                                    Label("クーポン", systemImage: "ticket")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.orange)
                            }

                            if let hpURL = shop.hotpepperURL {
                                Button {
                                    browserShop = (name: shop.name, url: hpURL)
                                } label: {
                                    Label("予約", systemImage: "calendar.badge.clock")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(.pink)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.04))
                    )
                    .padding(.horizontal)
                }
            }
        }
    }

    private static func extractCoordinate(from item: MKMapItem) -> CLLocationCoordinate2D {
        item.location.coordinate
    }
}

// MARK: - 確定情報入力シート

struct ConfirmSheet: View {
    let participantNames: [String]
    let existingInfo: ConfirmedInfo?
    let topSlotDate: Date?
    let onConfirm: (ConfirmedInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shopName: String = ""
    @State private var date = Date()
    @State private var time = Date()
    @State private var memo: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("飲み会を確定する")
                .font(.headline)
                .padding()

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // お店名
                    VStack(alignment: .leading, spacing: 6) {
                        Text("お店の名前")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        TextField("例: 鳥貴族 渋谷店", text: $shopName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    .padding(.horizontal)

                    // 日付
                    VStack(alignment: .leading, spacing: 6) {
                        Text("日付")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        DatePicker("日付", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .padding(.horizontal)

                    // 時間
                    VStack(alignment: .leading, spacing: 6) {
                        Text("集合時間")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        DatePicker("時間", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    .padding(.horizontal)

                    // メモ
                    VStack(alignment: .leading, spacing: 6) {
                        Text("備考（任意）")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        TextField("例: 改札前集合", text: $memo)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    .padding(.horizontal)

                    // 参加メンバー
                    VStack(alignment: .leading, spacing: 6) {
                        Text("参加メンバー")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(participantNames.enumerated()), id: \.offset) { _, name in
                                HStack(spacing: 6) {
                                    Image(systemName: "person.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                    Text(name)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // プレビュー
                    if !shopName.trimmingCharacters(in: .whitespaces).isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("共有テキストプレビュー")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            let previewInfo = ConfirmedInfo(shopName: shopName, date: date, time: time, memo: memo)
                            Text(previewInfo.shareSummary(participants: participantNames))
                                .font(.caption)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.08))
                                )
                                .padding(.horizontal)

                            Button {
                                #if os(iOS)
                                let text = ConfirmedInfo(shopName: shopName, date: date, time: time, memo: memo).shareSummary(participants: participantNames)
                                presentShareSheet(text: text)
                                #endif
                            } label: {
                                Label("共有", systemImage: "square.and.arrow.up")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical, 16)
            }

            Divider()

            HStack {
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("確定して保存") {
                    let info = ConfirmedInfo(shopName: shopName, date: date, time: time, memo: memo)
                    onConfirm(info)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(shopName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 400, height: 560)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .onAppear {
            if let existing = existingInfo {
                shopName = existing.shopName
                date = existing.date
                time = existing.time
                memo = existing.memo
            } else {
                if let topDate = topSlotDate {
                    date = topDate
                }
                var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                components.hour = 19
                components.minute = 0
                if let t = Calendar.current.date(from: components) {
                    time = t
                }
            }
        }
    }
}

// MARK: - 割り勘計算シート

enum SplitMode: String, CaseIterable, Identifiable {
    case equal = "均等割り"
    case organizerPaysMore = "幹事多め"

    var id: String { rawValue }
}

struct SplitBillSheet: View {
    let participantNames: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var totalAmountText = ""
    @State private var headCount: Int
    @State private var splitMode: SplitMode = .equal
    @State private var organizerIndex = 0
    @State private var payerSelection = 0  // 0〜N-1: 参加者, N: その他
    @State private var customPayerName = ""

    init(participantNames: [String]) {
        self.participantNames = participantNames
        _headCount = State(initialValue: participantNames.count)
    }

    private var totalAmount: Int {
        Int(totalAmountText) ?? 0
    }

    private var payerName: String {
        if payerSelection < participantNames.count {
            return participantNames[payerSelection]
        }
        let custom = customPayerName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? "支払い者" : custom
    }

    /// 均等割り: 100円単位で切り上げ
    private var equalPerPerson: Int {
        guard headCount > 0, totalAmount > 0 else { return 0 }
        let raw = Double(totalAmount) / Double(headCount)
        return Int(ceil(raw / 100.0)) * 100
    }

    /// 幹事多め: メンバーは1000円単位で切り捨て、幹事が残りを負担
    private var memberAmount: Int {
        guard headCount > 1, totalAmount > 0 else { return 0 }
        let raw = Double(totalAmount) / Double(headCount)
        return Int(floor(raw / 1000.0)) * 1000
    }

    private var organizerAmount: Int {
        guard headCount > 1, totalAmount > 0 else { return totalAmount }
        return totalAmount - memberAmount * (headCount - 1)
    }

    private func amountFor(index: Int) -> Int {
        if splitMode == .equal {
            return equalPerPerson
        } else {
            return (index == organizerIndex && index < participantNames.count) ? organizerAmount : memberAmount
        }
    }

    private var resultSummary: String {
        guard totalAmount > 0, headCount > 0 else { return "" }
        var lines: [String] = ["【割り勘計算結果】", "合計: ¥\(totalAmount)", "人数: \(headCount)人", "支払い: \(payerName)", ""]

        if splitMode == .equal {
            lines.append("一人あたり: ¥\(equalPerPerson)")
        } else {
            let orgName = organizerIndex < participantNames.count ? participantNames[organizerIndex] : "幹事"
            lines.append("幹事(\(orgName)): ¥\(organizerAmount)")
            lines.append("その他: ¥\(memberAmount)")
        }
        lines.append("")
        lines.append("▼ \(payerName)さんへの支払い")
        for (i, name) in displayNames.enumerated() {
            let amount = amountFor(index: i)
            let isPayer = payerSelection < participantNames.count && i == payerSelection
            if isPayer {
                lines.append("  \(name)（支払い済み）")
            } else {
                lines.append("  \(name) → \(payerName): ¥\(amount)")
            }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("割り勘計算")
                .font(.headline)
                .padding()

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // 合計金額
                    VStack(alignment: .leading, spacing: 6) {
                        Text("合計金額")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("¥")
                                .font(.title2.bold())
                            TextField("例: 30000", text: $totalAmountText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                        }
                    }
                    .padding(.horizontal)

                    // 参加人数
                    VStack(alignment: .leading, spacing: 6) {
                        Text("参加人数")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button {
                                if headCount > 1 { headCount -= 1 }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(headCount <= 1)

                            Text("\(headCount) 人")
                                .font(.body.monospacedDigit())
                                .frame(width: 50)

                            Button {
                                if headCount < 50 { headCount += 1 }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .disabled(headCount >= 50)
                        }
                    }
                    .padding(.horizontal)

                    // 支払い者
                    VStack(alignment: .leading, spacing: 6) {
                        Text("支払い者")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        Picker("支払い者", selection: $payerSelection) {
                            ForEach(Array(participantNames.enumerated()), id: \.offset) { i, name in
                                Text(name).tag(i)
                            }
                            Text("その他").tag(participantNames.count)
                        }
                        .frame(maxWidth: 200)

                        if payerSelection == participantNames.count {
                            TextField("支払い者の名前", text: $customPayerName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                        }
                    }
                    .padding(.horizontal)

                    // モード切替
                    VStack(alignment: .leading, spacing: 6) {
                        Text("割り勘モード")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        Picker("モード", selection: $splitMode) {
                            ForEach(SplitMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }
                    .padding(.horizontal)

                    // 幹事選択（幹事多めモード時）
                    if splitMode == .organizerPaysMore && !participantNames.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("幹事")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)

                            Picker("幹事", selection: $organizerIndex) {
                                ForEach(Array(participantNames.enumerated()), id: \.offset) { i, name in
                                    Text(name).tag(i)
                                }
                            }
                            .frame(maxWidth: 200)
                        }
                        .padding(.horizontal)
                    }

                    Divider()

                    // 計算結果
                    if totalAmount > 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("計算結果")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            if splitMode == .equal {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.fill")
                                        .foregroundStyle(.green)
                                    Text("一人あたり")
                                        .font(.body)
                                    Spacer()
                                    Text("¥\(equalPerPerson)")
                                        .font(.title2.bold())
                                        .foregroundStyle(.green)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.green.opacity(0.1))
                                )
                                .padding(.horizontal)
                            } else {
                                let orgName = organizerIndex < participantNames.count ? participantNames[organizerIndex] : "幹事"
                                VStack(spacing: 6) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.orange)
                                        Text("幹事(\(orgName))")
                                            .font(.body)
                                        Spacer()
                                        Text("¥\(organizerAmount)")
                                            .font(.title3.bold())
                                            .foregroundStyle(.orange)
                                    }
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.blue)
                                        Text("その他メンバー")
                                            .font(.body)
                                        Spacer()
                                        Text("¥\(memberAmount)")
                                            .font(.title3.bold())
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.orange.opacity(0.1))
                                )
                                .padding(.horizontal)
                            }

                            // 支払い者への送金一覧
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 4) {
                                    Image(systemName: "creditcard.fill")
                                        .font(.caption)
                                        .foregroundStyle(.purple)
                                    Text("\(payerName)さんへの支払い")
                                        .font(.caption.bold())
                                }
                                .padding(.horizontal, 12)

                                ForEach(Array(displayNames.enumerated()), id: \.offset) { i, name in
                                    let amount = amountFor(index: i)
                                    let isPayer = payerSelection < participantNames.count && i == payerSelection
                                    HStack {
                                        Text(name)
                                            .font(.caption)
                                        if isPayer {
                                            Spacer()
                                            Text("支払い済み")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        } else {
                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.secondary)
                                            Text(payerName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text("¥\(amount)")
                                                .font(.caption.bold())
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(isPayer ? Color.green.opacity(0.05) : Color.clear)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical, 16)
            }

            Divider()

            HStack {
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if totalAmount > 0 {
                    Button {
                        #if os(iOS)
                        presentShareSheet(text: resultSummary)
                        #else
                        copyToClipboard(resultSummary)
                        #endif
                    } label: {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 380, height: 580)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var displayNames: [String] {
        if headCount <= participantNames.count {
            let prefixCount = min(headCount, participantNames.count)
            return Array(participantNames[0..<prefixCount])
        } else {
            var names = participantNames
            for i in (participantNames.count + 1)...headCount {
                names.append("参加者\(i)")
            }
            return names
        }
    }
}

// MARK: - バナー広告

#if os(iOS)
#if targetEnvironment(simulator)
// シミュレータではAdMob SDKが動作しないためモック広告を表示
struct BannerAdView: View {
    var body: some View {
        ZStack {
            Color(.systemGray6)
            VStack(spacing: 2) {
                Text("テスト広告")
                    .font(.caption)
                    .bold()
                Text("実機では Google AdMob 広告が表示されます")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 50)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}
#else
struct BannerAdView: UIViewRepresentable {
    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = "ca-app-pub-3940256099942544/2934735716"
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            banner.rootViewController = root
        }
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}
#endif
#endif

// MARK: - プレビュー

#Preview {
    EventListView()
}
