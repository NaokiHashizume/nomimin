import SwiftUI
import MapKit
import Combine

// MARK: - データモデル

enum Availability: String, CaseIterable, Identifiable {
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

struct Participant: Identifiable {
    let id = UUID()
    var name: String
    var nearestStation: String
    var availabilities: [DateSlot: Availability]
}

struct DateSlot: Hashable, Comparable {
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

struct ConfirmedInfo {
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

// MARK: - 飲食店検索結果

struct ShopResult: Identifiable {
    let id = UUID()
    let name: String
    let category: String
    let phoneNumber: String
    let mapItem: MKMapItem

    func openInMaps() {
        mapItem.openInMaps(launchOptions: nil)
    }

    func openReservationSearch() {
        let query = "\(name) 予約".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://www.google.com/search?q=\(query)") {
            NSWorkspace.shared.open(url)
        }
    }

    var hasPhone: Bool { !phoneNumber.isEmpty }

    func callPhone() {
        let digits = phoneNumber.filter { $0.isNumber || $0 == "+" }
        if let url = URL(string: "tel:\(digits)") {
            NSWorkspace.shared.open(url)
        }
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

    // MARK: - 飲食店検索

    func searchShops(near coordinate: CLLocationCoordinate2D) async {
        isSearchingShops = true
        shopErrorMessage = nil
        shops = []

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "居酒屋 レストラン 飲食店"
        request.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )

        let searchObj = MKLocalSearch(request: request)
        do {
            let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MKLocalSearch.Response, Error>) in
                searchObj.start { response, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else if let response = response {
                        cont.resume(returning: response)
                    } else {
                        cont.resume(throwing: NSError(domain: "ShopSearch", code: -1))
                    }
                }
            }
            shops = response.mapItems.prefix(10).map { Self.toShopResult($0) }
            if shops.isEmpty {
                shopErrorMessage = "この付近に飲食店が見つかりませんでした。"
            }
        } catch {
            shopErrorMessage = "飲食店の検索に失敗しました。"
        }

        isSearchingShops = false
    }

    private static func toShopResult(_ item: MKMapItem) -> ShopResult {
        let category = item.pointOfInterestCategory?.rawValue
            .replacingOccurrences(of: "MKPOICategory", with: "") ?? ""
        let displayCategory: String
        switch category {
        case "Restaurant": displayCategory = "レストラン"
        case "Nightlife": displayCategory = "居酒屋・バー"
        case "Cafe": displayCategory = "カフェ"
        case "FoodMarket": displayCategory = "フードマーケット"
        default: displayCategory = "飲食店"
        }
        let phone = item.phoneNumber ?? ""
        return ShopResult(name: item.name ?? "不明な店舗", category: displayCategory, phoneNumber: phone, mapItem: item)
    }
}

// MARK: - メインビュー

struct ContentView: View {
    @State private var participants: [Participant] = []
    @State private var dateSlots: [DateSlot] = []
    @State private var showingAddDate = false
    @State private var showingAddParticipant = false
    @State private var showingMidpoint = false
    @State private var showingSplitBill = false
    @State private var showingConfirm = false
    @State private var confirmedInfo: ConfirmedInfo?
    @State private var selectedDate = Date()

    private var participantsWithStations: [String] {
        participants.compactMap { p in
            let s = p.nearestStation.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ツールバー
            HStack {
                Text("飲み会日程調整")
                    .font(.title2.bold())

                Spacer()

                if !participants.isEmpty {
                    Button {
                        showingConfirm = true
                    } label: {
                        Label("確定", systemImage: "checkmark.seal.fill")
                    }
                    .tint(.green)

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
                .disabled(dateSlots.isEmpty)
            }
            .padding()

            Divider()

            // 確定情報バナー
            if let info = confirmedInfo {
                confirmedBanner(info: info)
                Divider()
            }

            // メインコンテンツ
            if dateSlots.isEmpty {
                emptyStateView(
                    icon: "calendar",
                    title: "日程を追加しましょう",
                    message: "「日程追加」ボタンから候補日を追加してください"
                )
            } else if participants.isEmpty {
                emptyStateView(
                    icon: "person.2",
                    title: "参加者を追加しましょう",
                    message: "「参加者追加」ボタンからメンバーを追加してください"
                )
            } else {
                scheduleTable
            }

            summaryBar
        }
        .frame(minWidth: 520, minHeight: 400)
        .sheet(isPresented: $showingAddDate) {
            AddDateSheet(dateSlots: $dateSlots, selectedDate: $selectedDate)
        }
        .sheet(isPresented: $showingAddParticipant) {
            AddParticipantSheet(dateSlots: dateSlots) { newParticipant in
                participants.append(newParticipant)
            }
        }
        .sheet(isPresented: $showingMidpoint) {
            MidpointSheet(stations: participantsWithStations)
        }
        .sheet(isPresented: $showingSplitBill) {
            SplitBillSheet(participantNames: participants.map { $0.name })
        }
        .sheet(isPresented: $showingConfirm) {
            ConfirmSheet(
                participantNames: participants.map { $0.name },
                existingInfo: confirmedInfo
            ) { info in
                confirmedInfo = info
            }
        }
    }

    // MARK: - 確定情報バナー

    private func confirmedBanner(info: ConfirmedInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("確定: \(info.shopName)")
                    .font(.caption.bold())
                Text("\(info.displayDate) \(info.displayTime)〜")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                let summary = info.shareSummary(participants: participants.map { $0.name })
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
            } label: {
                Label("共有", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                confirmedInfo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    // MARK: - 空状態ビュー

    private func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - スケジュール表

    private var scheduleTable: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 0) {
                headerRow
                Divider()

                ForEach(Array(participants.enumerated()), id: \.element.id) { index, participant in
                    participantRow(index: index, participant: participant)
                    Divider()
                }
            }
            .padding(.horizontal)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                Text("名前")
                    .font(.caption.bold())
                Text("最寄駅")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, height: 44)
            .background(Color.gray.opacity(0.15))

            ForEach(dateSlots.sorted(), id: \.self) { slot in
                ZStack(alignment: .topTrailing) {
                    Text(slot.display)
                        .font(.caption.bold())
                        .frame(width: 80, height: 44)
                        .background(Color.gray.opacity(0.15))

                    Button {
                        withAnimation {
                            dateSlots.removeAll { $0 == slot }
                            for i in participants.indices {
                                participants[i].availabilities.removeValue(forKey: slot)
                            }
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

    private func participantRow(index: Int, participant: Participant) -> some View {
        let bgColor = index % 2 == 0 ? Color.clear : Color.gray.opacity(0.05)
        let hasStation = !participant.nearestStation.trimmingCharacters(in: .whitespaces).isEmpty

        return HStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(participant.name)
                        .font(.caption)
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
                    }
                }

                Spacer()

                Button {
                    withAnimation {
                        participants.removeAll { $0.id == participant.id }
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 130, height: 50)
            .padding(.horizontal, 4)
            .background(bgColor)

            ForEach(dateSlots.sorted(), id: \.self) { slot in
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
                        .background(bgColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - サマリーバー

    private var summaryBar: some View {
        Group {
            if !dateSlots.isEmpty && !participants.isEmpty {
                VStack(spacing: 8) {
                    Divider()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(dateSlots.sorted(), id: \.self) { slot in
                                let yesCount = participants.filter { ($0.availabilities[slot] ?? .no) == .yes }.count
                                let maybeCount = participants.filter { ($0.availabilities[slot] ?? .no) == .maybe }.count

                                VStack(spacing: 4) {
                                    Text(slot.display)
                                        .font(.caption.bold())
                                    HStack(spacing: 4) {
                                        Text("◯\(yesCount)")
                                            .foregroundStyle(.green)
                                        Text("△\(maybeCount)")
                                            .foregroundStyle(.orange)
                                    }
                                    .font(.caption)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(yesCount == participants.count ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 56)

                    Text("クリックで回答変更 ◯→△→×")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - ヘルパー

    private func cycleAvailability(participantIndex: Int, slot: DateSlot) {
        let current = participants[participantIndex].availabilities[slot] ?? .no
        let next: Availability
        switch current {
        case .yes:   next = .maybe
        case .maybe: next = .no
        case .no:    next = .yes
        }
        participants[participantIndex].availabilities[slot] = next
    }
}

// MARK: - 日程追加シート

struct AddDateSheet: View {
    @Binding var dateSlots: [DateSlot]
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss
    @State private var addedCount = 0

    private var isAlreadyAdded: Bool {
        let slot = DateSlot(date: Calendar.current.startOfDay(for: selectedDate))
        return dateSlots.contains(slot)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("日程追加")
                .font(.headline)
                .padding(.top)

            Text("カレンダーから複数の候補日を追加できます")
                .font(.caption)
                .foregroundStyle(.secondary)

            DatePicker("候補日", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)

            Button {
                let slot = DateSlot(date: Calendar.current.startOfDay(for: selectedDate))
                if !dateSlots.contains(slot) {
                    withAnimation {
                        dateSlots.append(slot)
                        addedCount += 1
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(isAlreadyAdded ? "追加済み" : "この日を追加")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isAlreadyAdded)
            .padding(.horizontal)

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
                                        withAnimation {
                                            dateSlots.removeAll { $0 == slot }
                                        }
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

            HStack {
                if addedCount > 0 {
                    Text("\(addedCount)件追加しました")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完了") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 340, height: 520)
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
        .frame(width: 360, height: 440)
        .onAppear {
            for slot in dateSlots {
                availabilities[slot] = .yes
            }
        }
    }
}

// MARK: - 中間地点シート

struct MidpointSheet: View {
    let stations: [String]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = MidpointSearchService()
    @State private var selectedStation: StationResult?

    var body: some View {
        VStack(spacing: 0) {
            Text("中間地点を探す")
                .font(.headline)
                .padding()

            Divider()

            // 参加者の最寄駅一覧
            VStack(alignment: .leading, spacing: 8) {
                Text("参加者の最寄駅")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(stations.enumerated()), id: \.offset) { _, station in
                            HStack(spacing: 4) {
                                Image(systemName: "tram.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                Text(station)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.blue.opacity(0.1)))
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 12)

            Divider()

            // 結果エリア
            Group {
                if service.isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("中間地点を計算中...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMsg = service.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if service.nearbyStations.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("「再検索」ボタンで中間地点を探します")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let center = service.centerCoordinate {
                                HStack(spacing: 6) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(String(format: "各駅の中間地点: 北緯%.3f° / 東経%.3f°", center.latitude, center.longitude))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal)
                                .padding(.top, 12)
                            }

                            // 中間地点に近い駅リスト
                            VStack(alignment: .leading, spacing: 6) {
                                Text("中間地点に近い駅（タップでお店検索）")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)

                                ForEach(service.nearbyStations) { station in
                                    let isSelected = selectedStation?.id == station.id
                                    Button {
                                        withAnimation {
                                            selectedStation = station
                                        }
                                        Task {
                                            let coord = MidpointSheet.extractCoordinate(from: station.mapItem)
                                            await service.searchShops(near: coord)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "tram.fill")
                                                .font(.body)
                                                .foregroundStyle(isSelected ? .white : .purple)
                                                .frame(width: 24)

                                            Text(station.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(isSelected ? .white : .primary)

                                            Spacer()

                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.white)
                                            }

                                            Button {
                                                station.openInMaps()
                                            } label: {
                                                Label("地図", systemImage: "map")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(isSelected ? Color.purple : Color.purple.opacity(0.05))
                                    )
                                    .padding(.horizontal)
                                }
                            }

                            // 飲食店リスト
                            if selectedStation != nil {
                                Divider()
                                    .padding(.vertical, 4)

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
                    selectedStation = nil
                    Task {
                        await service.search(stations: stations)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isSearching)
            }
            .padding()
        }
        .frame(width: 460, height: 600)
        .onAppear {
            Task {
                await service.search(stations: stations)
            }
        }
    }

    // MARK: - 飲食店リストセクション

    @ViewBuilder
    private var shopListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.orange)
                Text("\(selectedStation?.name ?? "")周辺のお店")
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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Image(systemName: "fork.knife.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(shop.name)
                                    .font(.body.weight(.medium))
                                HStack(spacing: 4) {
                                    Text(shop.category)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if shop.hasPhone {
                                        Text("・\(shop.phoneNumber)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Spacer()

                            if shop.hasPhone {
                                Button {
                                    shop.callPhone()
                                } label: {
                                    Label("電話", systemImage: "phone.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.blue)
                            }

                            Button {
                                shop.openInMaps()
                            } label: {
                                Label("地図", systemImage: "map")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                shop.openReservationSearch()
                            } label: {
                                Label("予約", systemImage: "calendar.badge.clock")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.green)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.05))
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
    let onConfirm: (ConfirmedInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shopName: String = ""
    @State private var date = Date()
    @State private var time = Date()
    @State private var memo: String = ""
    @State private var copied = false

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
                                let info = ConfirmedInfo(shopName: shopName, date: date, time: time, memo: memo)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(info.shareSummary(participants: participantNames), forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            } label: {
                                Label(copied ? "コピーしました!" : "テキストをコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
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
        .frame(width: 400, height: 560)
        .onAppear {
            if let existing = existingInfo {
                shopName = existing.shopName
                date = existing.date
                time = existing.time
                memo = existing.memo
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

    init(participantNames: [String]) {
        self.participantNames = participantNames
        _headCount = State(initialValue: participantNames.count)
    }

    private var totalAmount: Int {
        Int(totalAmountText) ?? 0
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

    private var resultSummary: String {
        guard totalAmount > 0, headCount > 0 else { return "" }
        var lines: [String] = ["【割り勘計算結果】", "合計: ¥\(totalAmount)", "人数: \(headCount)人", ""]

        if splitMode == .equal {
            lines.append("一人あたり: ¥\(equalPerPerson)")
            lines.append("")
            let count = min(headCount, participantNames.count)
            let names = Array(participantNames[0..<count])
            for name in names {
                lines.append("  \(name): ¥\(equalPerPerson)")
            }
            if headCount > participantNames.count {
                for i in (participantNames.count + 1)...headCount {
                    lines.append("  参加者\(i): ¥\(equalPerPerson)")
                }
            }
        } else {
            let organizerName = organizerIndex < participantNames.count ? participantNames[organizerIndex] : "幹事"
            lines.append("幹事(\(organizerName)): ¥\(organizerAmount)")
            lines.append("その他: ¥\(memberAmount)")
            lines.append("")
            let sliceCount = min(headCount, participantNames.count)
            for (i, name) in participantNames[0..<sliceCount].enumerated() {
                let amount = i == organizerIndex ? organizerAmount : memberAmount
                lines.append("  \(name): ¥\(amount)")
            }
            if headCount > participantNames.count {
                for i in (participantNames.count + 1)...headCount {
                    lines.append("  参加者\(i): ¥\(memberAmount)")
                }
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
                                let organizerName = organizerIndex < participantNames.count ? participantNames[organizerIndex] : "幹事"
                                VStack(spacing: 6) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.orange)
                                        Text("幹事(\(organizerName))")
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

                            // 参加者別一覧
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(displayNames.enumerated()), id: \.offset) { i, name in
                                    let amount = splitMode == .equal
                                        ? equalPerPerson
                                        : (i == organizerIndex && i < participantNames.count ? organizerAmount : memberAmount)
                                    let isOrganizer = splitMode == .organizerPaysMore && i == organizerIndex && i < participantNames.count
                                    HStack {
                                        if isOrganizer {
                                            Image(systemName: "star.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                        Text(name)
                                            .font(.caption)
                                        Spacer()
                                        Text("¥\(amount)")
                                            .font(.caption.bold())
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
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
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resultSummary, forType: .string)
                    } label: {
                        Label("結果をコピー", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 380, height: 520)
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

// MARK: - プレビュー

#Preview {
    ContentView()
}
