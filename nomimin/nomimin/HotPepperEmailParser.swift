//
//  HotPepperEmailParser.swift
//  nomimin
//
//  ホットペッパー予約確認メールのパーサー + 共有データモデル
//

import Foundation

// MARK: - パース結果モデル

struct ParsedReservation: Codable {
    var shopName: String
    var date: String       // "2026-03-15" ISO形式
    var time: String       // "19:00" HH:mm形式
    var numberOfPeople: Int?
    var courseName: String?
    var memo: String

    // MARK: - URL エンコード/デコード

    func toURL() -> URL? {
        var components = URLComponents()
        components.scheme = "nomimin"
        components.host = "confirm"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "shop", value: shopName),
            URLQueryItem(name: "date", value: date),
            URLQueryItem(name: "time", value: time),
        ]
        if let n = numberOfPeople {
            items.append(URLQueryItem(name: "people", value: "\(n)"))
        }
        if let course = courseName {
            items.append(URLQueryItem(name: "course", value: course))
        }
        if !memo.isEmpty {
            items.append(URLQueryItem(name: "memo", value: memo))
        }
        components.queryItems = items
        return components.url
    }

    static func fromURL(_ url: URL) -> ParsedReservation? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "nomimin",
              components.host == "confirm"
        else { return nil }

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                guard let value = $0.value else { return nil as (String, String)? }
                return ($0.name, value)
            }
        )

        guard let shop = params["shop"],
              let date = params["date"],
              let time = params["time"]
        else { return nil }

        return ParsedReservation(
            shopName: shop,
            date: date,
            time: time,
            numberOfPeople: params["people"].flatMap { Int($0) },
            courseName: params["course"],
            memo: params["memo"] ?? ""
        )
    }

    // MARK: - ConfirmedInfo 変換

    func toConfirmedInfo() -> ConfirmedInfo? {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "ja_JP")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard let parsedDate = dateFormatter.date(from: date) else { return nil }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "ja_JP")
        timeFormatter.dateFormat = "HH:mm"

        let parsedTime: Date
        if let t = timeFormatter.date(from: time) {
            let cal = Calendar.current
            let dateComps = cal.dateComponents([.year, .month, .day], from: parsedDate)
            let timeComps = cal.dateComponents([.hour, .minute], from: t)
            var combined = dateComps
            combined.hour = timeComps.hour
            combined.minute = timeComps.minute
            parsedTime = cal.date(from: combined) ?? parsedDate
        } else {
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month, .day], from: parsedDate)
            comps.hour = 19; comps.minute = 0
            parsedTime = cal.date(from: comps) ?? parsedDate
        }

        var memoLines: [String] = []
        if let n = numberOfPeople { memoLines.append("\(n)名") }
        if let c = courseName { memoLines.append(c) }
        if !memo.isEmpty { memoLines.append(memo) }

        return ConfirmedInfo(
            shopName: shopName,
            date: parsedDate,
            time: parsedTime,
            memo: memoLines.joined(separator: " / ")
        )
    }
}

// MARK: - メール本文パーサー

struct HotPepperEmailParser {

    static func parse(_ text: String) -> ParsedReservation? {
        // HTMLタグを除去
        let cleanText = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        var shopName: String?
        var date: String?
        var time: String?
        var numberOfPeople: Int?
        var courseName: String?

        // --- 店名 ---
        let shopPatterns = [
            #"(?:店名|店舗名|ご予約店舗|お店)[：:]\s*(.+)"#,
            #"【ご予約[^】]*】\s*(.+)"#,
        ]
        for pattern in shopPatterns {
            if let result = firstMatch(in: cleanText, pattern: pattern, group: 1) {
                shopName = result.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // --- 日付 ---
        // 「来店日：2026年3月15日（土）」等
        let labeledDatePattern = #"(?:来店日|予約日|ご利用日|日付)[：:]\s*(\d{4})[年/\-](\d{1,2})[月/\-](\d{1,2})"#
        if let match = firstGroupedMatch(in: cleanText, pattern: labeledDatePattern, groups: 3) {
            date = formatDate(year: match[0], month: match[1], day: match[2])
        }
        // ラベルなしのフォールバック
        if date == nil {
            let genericDatePattern = #"(\d{4})[年/\-](\d{1,2})[月/\-](\d{1,2})"#
            if let match = firstGroupedMatch(in: cleanText, pattern: genericDatePattern, groups: 3) {
                date = formatDate(year: match[0], month: match[1], day: match[2])
            }
        }

        // --- 時間 ---
        let timePatterns = [
            #"(?:来店時間|予約時間|ご利用時間|時間|開始時間)[：:]\s*(\d{1,2})[：:時](\d{2})"#,
            #"(\d{1,2})[：:](\d{2})\s*[〜~\-]"#,
        ]
        for pattern in timePatterns {
            if let match = firstGroupedMatch(in: cleanText, pattern: pattern, groups: 2) {
                let h = Int(match[0]) ?? 19
                let m = Int(match[1]) ?? 0
                time = String(format: "%02d:%02d", h, m)
                break
            }
        }

        // --- 人数 ---
        let peoplePatterns = [
            #"(?:予約人数|人数|ご利用人数)[：:]\s*(\d+)\s*名"#,
            #"(\d+)\s*名[様]?"#,
        ]
        for pattern in peoplePatterns {
            if let result = firstMatch(in: cleanText, pattern: pattern, group: 1) {
                numberOfPeople = Int(result)
                break
            }
        }

        // --- コース名 ---
        let coursePattern = #"(?:コース|プラン|コース名|プラン名)[：:]\s*(.+)"#
        if let result = firstMatch(in: cleanText, pattern: coursePattern, group: 1) {
            courseName = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 店名が取得できなければパース失敗
        guard let name = shopName, !name.isEmpty else { return nil }

        return ParsedReservation(
            shopName: name,
            date: date ?? "",
            time: time ?? "19:00",
            numberOfPeople: numberOfPeople,
            courseName: courseName,
            memo: ""
        )
    }

    // MARK: - ヘルパー

    private static func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func firstGroupedMatch(in text: String, pattern: String, groups count: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > count
        else { return nil }

        var results: [String] = []
        for i in 1...count {
            guard let range = Range(match.range(at: i), in: text) else { return nil }
            results.append(String(text[range]))
        }
        return results
    }

    private static func formatDate(year: String, month: String, day: String) -> String {
        String(format: "%@-%02d-%02d", year, Int(month) ?? 1, Int(day) ?? 1)
    }
}
