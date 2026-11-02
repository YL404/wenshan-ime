import UIKit
import WenshanEngine

/// 最小可用的文山 iOS 键盘：26 键 + 候选条。
///
/// 这里只验证 Go 引擎在键盘扩展里的完整链路：按键进入 MobileType，
/// 候选由 MobileSelect 上屏，组合中的字母通过 setMarkedText 回显。
/// 输入法真正的候选窗、符号页、九键布局都不在这个 PoC 范围内。
final class KeyboardViewController: UIInputViewController {
    private let candidateBar = UIStackView()
    private var candidates: [String] = []
    private var engineReady = false

    private let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        openEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        openEngine()
        apply(MobileCandidates())
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        MobileReset()
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
    }

    private func openEngine() {
        guard !engineReady else { return }
        guard let path = Bundle.main.path(forResource: "dict", ofType: "bin") else {
            NSLog("Wenshan: 扩展里找不到 dict.bin")
            return
        }
        engineReady = MobileOpen(path)
        if !engineReady {
            NSLog("Wenshan: 打开词表失败: %@", MobileLastError())
        }
    }

    private func buildUI() {
        view.backgroundColor = .systemGray5
        let height = view.heightAnchor.constraint(equalToConstant: 270)
        height.priority = .defaultHigh
        height.isActive = true

        candidateBar.axis = .horizontal
        candidateBar.spacing = 4
        candidateBar.distribution = .fillProportionally
        candidateBar.alignment = .fill
        candidateBar.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let keyboard = UIStackView()
        keyboard.axis = .vertical
        keyboard.spacing = 6
        keyboard.distribution = .fillEqually
        keyboard.alignment = .fill

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.distribution = .fillEqually
            rowStack.alignment = .fill
            for ch in row {
                rowStack.addArrangedSubview(keyButton(String(ch)) { [weak self] in
                    self?.type(String(ch))
                })
            }
            keyboard.addArrangedSubview(rowStack)
            rowStack.widthAnchor.constraint(equalTo: keyboard.widthAnchor).isActive = true
        }

        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 4
        bottom.distribution = .fillEqually
        bottom.alignment = .fill
        bottom.addArrangedSubview(keyButton("🌐", label: "切换键盘") { [weak self] in
            self?.advanceToNextInputMode()
        })
        bottom.addArrangedSubview(keyButton("空格", label: "空格") { [weak self] in
            self?.space()
        })
        bottom.addArrangedSubview(keyButton("⌫", label: "删除") { [weak self] in
            self?.backspace()
        })
        bottom.addArrangedSubview(keyButton("换行", label: "换行") { [weak self] in
            self?.returnKey()
        })
        keyboard.addArrangedSubview(bottom)
        bottom.widthAnchor.constraint(equalTo: keyboard.widthAnchor).isActive = true

        let root = UIStackView(arrangedSubviews: [candidateBar, keyboard])
        root.axis = .vertical
        root.spacing = 6
        root.alignment = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])

        refreshCandidates()
    }

    private func keyButton(_ title: String, label: String? = nil, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = .secondarySystemBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .small
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.accessibilityLabel = label ?? title
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func type(_ key: String) {
        guard engineReady else { return }
        apply(MobileType(key))
    }

    private func space() {
        if candidates.isEmpty {
            textDocumentProxy.insertText(" ")
        } else {
            select(0)
        }
    }

    private func backspace() {
        if MobileBuffer().isEmpty {
            textDocumentProxy.deleteBackward()
        } else {
            apply(MobileBackspace())
        }
    }

    private func returnKey() {
        if candidates.isEmpty {
            textDocumentProxy.insertText("\n")
        } else {
            select(0)
        }
    }

    private func select(_ index: Int) {
        let text = MobileSelect(index)
        if !text.isEmpty {
            textDocumentProxy.insertText(text)
        }
        apply(MobileCandidates())
    }

    private func apply(_ joined: String) {
        candidates = joined.isEmpty ? [] : joined.split(separator: "\n").map(String.init)
        let buffer = MobileBuffer()
        textDocumentProxy.setMarkedText(buffer, selectedRange: NSRange(location: buffer.utf16.count, length: 0))
        refreshCandidates()
    }

    private func refreshCandidates() {
        candidateBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if candidates.isEmpty {
            let label = UILabel()
            label.text = "文山"
            label.textColor = .secondaryLabel
            label.font = .systemFont(ofSize: 14)
            candidateBar.addArrangedSubview(label)
            return
        }
        for (index, text) in candidates.enumerated() {
            var config = UIButton.Configuration.plain()
            config.title = text
            config.baseForegroundColor = .label
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
            let button = UIButton(configuration: config)
            button.titleLabel?.font = .systemFont(ofSize: 20)
            button.accessibilityLabel = text
            button.addAction(UIAction { [weak self] _ in
                self?.select(index)
            }, for: .touchUpInside)
            candidateBar.addArrangedSubview(button)
        }
    }
}
