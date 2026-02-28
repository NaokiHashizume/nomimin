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

// MARK: - 中間地点検索サービス

@MainActor
class MidpointSearchService: ObservableObject {
    @Published var isSearching = false
    @Published var nearbyStations: [StationResult] = []
    @Published var centerCoordinate: CLLocationCoordinate2D?
    @Published var errorMessage: String?

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
        let addr: String
        if let mkAddress = item.address {
            let parts = [mkAddress.locality, mkAddress.subLocality].compactMap { $0 }
            addr = parts.joined(separator: " ")
        } else {
            addr = ""
        }
        return StationResult(name: item.name ?? "不明な駅", address: addr, mapItem: item)
    }
}

// MARK: - メインビュー

struct ContentView: View {
    @State private var participants: [Participant] = []
    @State private var dateSlots: [DateSlot] = []
    @State private var showingAddDate = false
    @State private var showingAddParticipant = false
    @State private var showingMidpoint = false
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

    var body: some View {
        VStack(spacing: 16) {
            Text("日程追加")
                .font(.headline)
                .padding(.top)

            DatePicker("候補日", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)

            Button {
                let slot = DateSlot(date: Calendar.current.startOfDay(for: selectedDate))
                if !dateSlots.contains(slot) {
                    withAnimation {
                        dateSlots.append(slot)
                    }
                }
                dismiss()
            } label: {
                Text("この日を追加")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            // 追加済みの日程
            if !dateSlots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("追加済みの日程")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

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
                .padding(.horizontal)
            }

            Spacer()

            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 340, height: 480)
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

                            VStack(alignment: .leading, spacing: 6) {
                                Text("中間地点に近い駅")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)

                                ForEach(service.nearbyStations) { station in
                                    HStack(spacing: 12) {
                                        Image(systemName: "tram.fill")
                                            .font(.body)
                                            .foregroundStyle(.purple)
                                            .frame(width: 24)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(station.name)
                                                .font(.body.weight(.medium))
                                            if !station.address.isEmpty {
                                                Text(station.address)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        Button {
                                            station.openInMaps()
                                        } label: {
                                            Label("地図", systemImage: "map")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.purple.opacity(0.05))
                                    )
                                    .padding(.horizontal)
                                }
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
                    Task {
                        await service.search(stations: stations)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isSearching)
            }
            .padding()
        }
        .frame(width: 420, height: 500)
        .onAppear {
            Task {
                await service.search(stations: stations)
            }
        }
    }
}

// MARK: - プレビュー

#Preview {
    ContentView()
}
