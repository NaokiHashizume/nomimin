import SwiftUI

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

// MARK: - メインビュー

struct ContentView: View {
    @State private var participants: [Participant] = []
    @State private var dateSlots: [DateSlot] = []
    @State private var showingAddDate = false
    @State private var showingAddParticipant = false
    @State private var selectedDate = Date()
    
    var body: some View {
        VStack(spacing: 0) {
            // ツールバー
            HStack {
                Text("飲み会日程調整")
                    .font(.title2.bold())
                
                Spacer()
                
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
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showingAddDate) {
            AddDateSheet(dateSlots: $dateSlots, selectedDate: $selectedDate)
        }
        .sheet(isPresented: $showingAddParticipant) {
            AddParticipantSheet(dateSlots: dateSlots) { newParticipant in
                participants.append(newParticipant)
            }
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
            Text("名前")
                .font(.caption.bold())
                .frame(width: 100, height: 40)
                .background(Color.gray.opacity(0.15))
            
            ForEach(dateSlots.sorted(), id: \.self) { slot in
                ZStack(alignment: .topTrailing) {
                    Text(slot.display)
                        .font(.caption.bold())
                        .frame(width: 80, height: 40)
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
        
        return HStack(spacing: 0) {
            HStack {
                Text(participant.name)
                    .font(.caption)
                    .lineLimit(1)
                
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
            .frame(width: 100, height: 44)
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
                        .frame(width: 80, height: 44)
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
    @State private var availabilities: [DateSlot: Availability] = [:]
    
    var body: some View {
        VStack(spacing: 16) {
            Text("参加者追加")
                .font(.headline)
                .padding(.top)
            
            // 名前入力
            HStack {
                Text("名前:")
                    .font(.body)
                TextField("名前を入力", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
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
        .frame(width: 360, height: 400)
        .onAppear {
            for slot in dateSlots {
                availabilities[slot] = .yes
            }
        }
    }
}

// MARK: - プレビュー

#Preview {
    ContentView()
}

