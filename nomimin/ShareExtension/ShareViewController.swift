//
//  ShareViewController.swift
//  ShareExtension
//
//  ホットペッパー予約確認メールを受け取り、のみみんアプリに取り込む
//

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    // MARK: - パース結果

    private var shopName: String?
    private var dateString: String?
    private var timeString: String?
    private var numberOfPeople: Int?
    private var courseName: String?

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .large)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        loadSharedContent()
    }

    // MARK: - UI Setup

    private func setupUI() {
        // ── ヘッダーバー ──
        let headerBar = UIView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        let titleLabel = UILabel()
        titleLabel.text = "🍻 予約情報の取り込み"
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(titleLabel)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("閉じる", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 16)
        closeButton.addTarget(self, action: #selector(dismissExtension), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(closeButton)

        // ── スクロールビュー ──
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        // ── スピナー ──
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        view.addSubview(spinner)

        // ── レイアウト ──
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 52),

            titleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 20),

            closeButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -20),

            separator.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - 共有テキストの読み取り

    private func loadSharedContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError()
            return
        }

        for item in items {
            for provider in item.attachments ?? [] {
                // プレーンテキストを優先
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, _ in
                        DispatchQueue.main.async {
                            if let text = data as? String {
                                self?.processText(text)
                            } else {
                                self?.showError()
                            }
                        }
                    }
                    return
                }
                // HTMLの場合
                if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.html.identifier, options: nil) { [weak self] data, _ in
                        DispatchQueue.main.async {
                            if let text = data as? String {
                                self?.processText(text)
                            } else {
                                self?.showError()
                            }
                        }
                    }
                    return
                }
            }
        }

        showError()
    }

    // MARK: - メール本文パース

    private func processText(_ text: String) {
        // HTMLタグを除去
        let cleanText = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // --- 店名 ---
        for pattern in [
            "(?:店名|店舗名|ご予約店舗|お店)[：:]\\s*(.+)",
            "【ご予約[^】]*】\\s*(.+)"
        ] {
            if let match = firstMatch(in: cleanText, pattern: pattern, group: 1) {
                shopName = match.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // --- 日付 ---
        let labeledDate = "(?:来店日|予約日|ご利用日|日付)[：:]\\s*(\\d{4})[年/\\-](\\d{1,2})[月/\\-](\\d{1,2})"
        if let m = groupedMatch(in: cleanText, pattern: labeledDate, count: 3) {
            dateString = formatDate(y: m[0], m: m[1], d: m[2])
        }
        if dateString == nil {
            let generic = "(\\d{4})[年/\\-](\\d{1,2})[月/\\-](\\d{1,2})"
            if let m = groupedMatch(in: cleanText, pattern: generic, count: 3) {
                dateString = formatDate(y: m[0], m: m[1], d: m[2])
            }
        }

        // --- 時間 ---
        for pattern in [
            "(?:来店時間|予約時間|ご利用時間|時間|開始時間)[：:]\\s*(\\d{1,2})[：:時](\\d{2})",
            "(\\d{1,2})[：:](\\d{2})\\s*[〜~\\-]"
        ] {
            if let m = groupedMatch(in: cleanText, pattern: pattern, count: 2) {
                let h = Int(m[0]) ?? 19
                let min = Int(m[1]) ?? 0
                timeString = String(format: "%02d:%02d", h, min)
                break
            }
        }

        // --- 人数 ---
        for pattern in [
            "(?:予約人数|人数|ご利用人数)[：:]\\s*(\\d+)\\s*名",
            "(\\d+)\\s*名[様]?"
        ] {
            if let match = firstMatch(in: cleanText, pattern: pattern, group: 1) {
                numberOfPeople = Int(match)
                break
            }
        }

        // --- コース名 ---
        if let match = firstMatch(in: cleanText, pattern: "(?:コース|プラン|コース名|プラン名)[：:]\\s*(.+)", group: 1) {
            courseName = match.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        spinner.stopAnimating()

        guard let name = shopName, !name.isEmpty else {
            showError()
            return
        }

        showResults()
    }

    // MARK: - 結果表示

    private func showResults() {
        // 情報カード
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12

        let infoStack = UIStackView()
        infoStack.axis = .vertical
        infoStack.spacing = 12
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(infoStack)

        NSLayoutConstraint.activate([
            infoStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            infoStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            infoStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            infoStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        if let shop = shopName {
            infoStack.addArrangedSubview(makeRow(icon: "🏠", label: "店名", value: shop))
        }
        if let date = dateString {
            infoStack.addArrangedSubview(makeRow(icon: "📅", label: "日付", value: date))
        }
        if let time = timeString {
            infoStack.addArrangedSubview(makeRow(icon: "🕐", label: "時間", value: time))
        }
        if let n = numberOfPeople {
            infoStack.addArrangedSubview(makeRow(icon: "👥", label: "人数", value: "\(n)名"))
        }
        if let course = courseName {
            infoStack.addArrangedSubview(makeRow(icon: "🍽", label: "コース", value: course))
        }

        contentStack.addArrangedSubview(card)

        // 「のみみんで開く」ボタン
        let openButton = UIButton(type: .system)
        openButton.setTitle("のみみんで開く", for: .normal)
        openButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        openButton.backgroundColor = .systemOrange
        openButton.setTitleColor(.white, for: .normal)
        openButton.layer.cornerRadius = 14
        openButton.addTarget(self, action: #selector(openInApp), for: .touchUpInside)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.heightAnchor.constraint(equalToConstant: 52).isActive = true

        contentStack.addArrangedSubview(openButton)

        // 補足テキスト
        let noteLabel = UILabel()
        noteLabel.text = "のみみんアプリで予約情報をイベントに紐づけます"
        noteLabel.font = .systemFont(ofSize: 13)
        noteLabel.textColor = .tertiaryLabel
        noteLabel.textAlignment = .center
        noteLabel.numberOfLines = 0

        contentStack.addArrangedSubview(noteLabel)
    }

    private func makeRow(icon: String, label: String, value: String) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline

        let iconLabel = UILabel()
        iconLabel.text = icon
        iconLabel.font = .systemFont(ofSize: 16)
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let nameLabel = UILabel()
        nameLabel.text = label
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .secondaryLabel
        nameLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = .systemFont(ofSize: 16)
        valueLabel.numberOfLines = 0

        stack.addArrangedSubview(iconLabel)
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(valueLabel)

        return stack
    }

    private func showError() {
        spinner.stopAnimating()

        let errorView = UILabel()
        errorView.text = "予約情報を読み取れませんでした\n\nホットペッパーの予約確認メールの\n本文を選択して共有してください"
        errorView.font = .systemFont(ofSize: 15)
        errorView.textColor = .secondaryLabel
        errorView.textAlignment = .center
        errorView.numberOfLines = 0

        contentStack.addArrangedSubview(errorView)
    }

    // MARK: - アクション

    @objc private func openInApp() {
        guard let url = buildConfirmURL() else {
            dismissExtension()
            return
        }

        // extensionContext?.open() でメインアプリを起動
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                } else {
                    // フォールバック: クリップボードにコピー
                    UIPasteboard.general.url = url
                    self?.showFallbackAlert()
                }
            }
        }
    }

    private func showFallbackAlert() {
        let alert = UIAlertController(
            title: "のみみんアプリを開いてください",
            message: "予約データをクリップボードにコピーしました。のみみんアプリを開くと自動的に取り込まれます。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        })
        present(alert, animated: true)
    }

    private func buildConfirmURL() -> URL? {
        var components = URLComponents()
        components.scheme = "nomimin"
        components.host = "confirm"

        var items: [URLQueryItem] = []

        if let shop = shopName {
            items.append(URLQueryItem(name: "shop", value: shop))
        }
        if let date = dateString {
            items.append(URLQueryItem(name: "date", value: date))
        }
        items.append(URLQueryItem(name: "time", value: timeString ?? "19:00"))
        if let n = numberOfPeople {
            items.append(URLQueryItem(name: "people", value: "\(n)"))
        }
        if let course = courseName {
            items.append(URLQueryItem(name: "course", value: course))
        }

        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    @objc private func dismissExtension() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "com.naokihashizume.nomimin.ShareExtension",
            code: 0
        ))
    }

    // MARK: - 正規表現ヘルパー

    private func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    private func groupedMatch(in text: String, pattern: String, count: Int) -> [String]? {
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

    private func formatDate(y: String, m: String, d: String) -> String {
        String(format: "%@-%02d-%02d", y, Int(m) ?? 1, Int(d) ?? 1)
    }
}
