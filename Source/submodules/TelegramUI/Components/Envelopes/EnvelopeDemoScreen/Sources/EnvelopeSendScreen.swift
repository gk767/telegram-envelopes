import Foundation
import UIKit
import AccountContext
import Display
import EnvelopeRendering
import TelegramCore
import TelegramEnvelopes
import TelegramPresentationData

private final class EnvelopeFormScrollView: UIScrollView {
    weak var focusedField: UIView?
    private var lastViewport = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard self.bounds.size != self.lastViewport else { return }
        self.lastViewport = self.bounds.size
        self.revealFocusedField()
    }

    func revealFocusedField() {
        guard let field = self.focusedField, field.isFirstResponder, !self.isDragging, !self.isDecelerating else { return }
        let rect = field.convert(field.bounds, to: self).insetBy(dx: 0, dy: -10)
        if !self.bounds.contains(rect) {
            self.scrollRectToVisible(rect, animated: false)
        }
    }
}

/// Sender-only sheet presented by a real private chat. The recipient is that chat's
/// peer; ownership is determined by account identity, never by a demo role switch.
public final class EnvelopeSendScreen: ViewController, UITextFieldDelegate, UITextViewDelegate {
    private let context: AccountContext
    private let peer: EnginePeer
    private let data: PresentationData
    private let strings: EnvelopeStrings
    private let sendMessage: (String, @escaping (Bool) -> Void) -> Void
    private let dimming = UIView()
    private let panel = UIView()
    private let grabber = UIView()
    private let header = UILabel()
    private let close = UIButton(type: .system)
    private let scroll = EnvelopeFormScrollView()
    private let stack = UIStackView()
    private let artwork = EnvelopeArtworkView()
    private let recipient = UILabel()
    private let currencyPicker = UISegmentedControl(items: [EnvelopeCurrency.ton.displayName, EnvelopeCurrency.usdt.displayName])
    private var currency: EnvelopeCurrency = .ton
    private let amount = UITextField()
    private let amountCurrency = UILabel()
    private var amountWidth: NSLayoutConstraint?
    private func updateAmountLayout() {
        self.amountCurrency.text = self.currency.displayName
        let text = (self.amount.text ?? "").isEmpty ? "0" : (self.amount.text ?? "")
        let measured = (text as NSString).size(withAttributes: [.font: self.amount.font ?? UIFont.systemFont(ofSize: 44)]).width
        self.amountWidth?.constant = min(220, max(32, ceil(measured) + 8))
    }
    private let comment = UITextView()
    private let balance = UILabel()
    private let effectPicker = UIView()
    private var effectButtons: [UIButton] = []
    private let effectCount = UILabel()
    private var openingEmoji: [String] = []

    private func setupEffectPicker() {
        let theme = self.data.theme
        self.effectPicker.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.effectPicker.layer.cornerRadius = 14
        self.effectPicker.layer.cornerCurve = .continuous
        let title = UILabel()
        title.text = self.strings[.openingEmoji]
        title.font = UIFont.preferredFont(forTextStyle: .footnote)
        title.textColor = theme.list.itemSecondaryTextColor
        self.effectCount.font = UIFont.preferredFont(forTextStyle: .caption1)
        self.effectCount.textColor = theme.list.itemSecondaryTextColor
        let strip = UIScrollView()
        strip.showsHorizontalScrollIndicator = false
        strip.contentInsetAdjustmentBehavior = .never
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        for (index, text) in ([self.strings[.noEmoji]] + EnvelopeMessageReference.emojiChoices).enumerated() {
            let chip = UIButton(type: .custom)
            chip.tag = index - 1
            chip.setTitle(text, for: .normal)
            chip.titleLabel?.font = index == 0 ? UIFont.preferredFont(forTextStyle: .footnote) : UIFont.systemFont(ofSize: 23)
            chip.layer.cornerRadius = 22
            chip.layer.cornerCurve = .continuous
            chip.addTarget(self, action: #selector(self.effectPressed(_:)), for: .touchUpInside)
            chip.widthAnchor.constraint(equalToConstant: index == 0 ? max(66, ceil(chip.titleLabel?.intrinsicContentSize.width ?? 42) + 24) : 44).isActive = true
            row.addArrangedSubview(chip)
            self.effectButtons.append(chip)
        }
        for view in [title, self.effectCount, strip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.effectPicker.addSubview(view)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: self.effectPicker.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: self.effectPicker.topAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: self.effectCount.leadingAnchor, constant: -8),
            self.effectCount.trailingAnchor.constraint(equalTo: self.effectPicker.trailingAnchor, constant: -12),
            self.effectCount.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            strip.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            strip.leadingAnchor.constraint(equalTo: self.effectPicker.leadingAnchor, constant: 12),
            strip.trailingAnchor.constraint(equalTo: self.effectPicker.trailingAnchor, constant: -12),
            strip.heightAnchor.constraint(equalToConstant: 44),
            strip.bottomAnchor.constraint(equalTo: self.effectPicker.bottomAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor)
        ])
        self.updateEffectPicker()
    }

    @objc private func effectPressed(_ sender: UIButton) {
        guard !self.busy, self.pendingSend == nil else { return }
        if sender.tag < 0 {
            self.openingEmoji = []
        } else {
            let glyph = EnvelopeMessageReference.emojiChoices[sender.tag]
            if self.openingEmoji.contains(glyph) {
                self.openingEmoji.removeAll { $0 == glyph }
            } else if self.openingEmoji.count < 3 {
                self.openingEmoji.append(glyph)
            }
        }
        self.updateEffectPicker()
    }

    private func updateEffectPicker() {
        self.effectCount.text = "\(self.openingEmoji.count)/3"
        for chip in self.effectButtons {
            let selected = chip.tag < 0 ? self.openingEmoji.isEmpty : self.openingEmoji.contains(EnvelopeMessageReference.emojiChoices[chip.tag])
            chip.layer.borderWidth = selected ? 1 : 0
            chip.layer.borderColor = UIColor(red: 0.30, green: 0.65, blue: 1, alpha: 0.38).cgColor
            chip.isEnabled = chip.tag < 0 || selected || self.openingEmoji.count < 3
            chip.alpha = chip.isEnabled ? 1 : 0.4
            chip.backgroundColor = .clear
            chip.setTitleColor(self.data.theme.list.itemPrimaryTextColor, for: .normal)
            chip.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }
    private let errorLabel = UILabel()
    private let send = UIButton(type: .system)
    private var service: EnvelopeService?
    private var availableBalance: Int64?
    private var journal: EnvelopeSendJournal?
    private var pendingSend: EnvelopePendingSend?
    private var walletRequestId: UUID?
    private var busy = false
    private var layoutSize = CGSize.zero
    private var layoutInsets = UIEdgeInsets.zero
    private var appeared = false
    private var presentedSheet = false
    private var dismissingSheet = false

    private var reduceMotion: Bool {
        return UIAccessibility.isReduceMotionEnabled || self.context.sharedContext.currentPresentationData.with { $0.reduceMotion }
    }

    public init(context: AccountContext, peer: EnginePeer, sendMessage: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        self.context = context
        self.peer = peer
        self.data = context.sharedContext.currentPresentationData.with { $0 }
        self.strings = EnvelopeStrings(self.data.strings)
        self.sendMessage = sendMessage
        super.init(navigationBarPresentationData: nil)
    }

    public required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadDisplayNode() {
        // Root overlays load displayNode before UIKit loads the controller's view.
        // Build here: their manual loadView path does not invoke viewDidLoad.
        super.loadDisplayNode()
        let theme = self.data.theme
        self.displayNode.backgroundColor = .clear
        self.dimming.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        self.displayNode.view.addSubview(self.dimming)
        self.displayNode.view.addSubview(self.panel)
        self.panel.backgroundColor = theme.list.blocksBackgroundColor
        self.panel.layer.cornerRadius = 28
        self.panel.layer.cornerCurve = .continuous
        self.panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.grabber.layer.cornerRadius = 2
        self.grabber.backgroundColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.32)
        for child in [self.grabber, self.header, self.close, self.scroll, self.send] { self.panel.addSubview(child) }
        self.header.text = self.strings[.tonTitle]
        self.header.font = UIFont.preferredFont(forTextStyle: .headline)
        self.header.textColor = theme.list.itemPrimaryTextColor
        self.header.textAlignment = .center
        self.close.setTitle(self.strings[.close], for: .normal)
        self.close.tintColor = theme.list.itemAccentColor
        self.close.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        self.scroll.keyboardDismissMode = .interactive
        self.scroll.alwaysBounceVertical = true
        self.scroll.contentInsetAdjustmentBehavior = .never
        self.scroll.translatesAutoresizingMaskIntoConstraints = false
        self.send.translatesAutoresizingMaskIntoConstraints = false
        // UIKit owns this anchor, including interactive dismissal and switches
        // between numeric, alphabetic and emoji keyboards.
        let aboveKeyboard = self.send.bottomAnchor.constraint(equalTo: self.displayNode.view.keyboardLayoutGuide.topAnchor, constant: -8)
        aboveKeyboard.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            aboveKeyboard,
            self.send.bottomAnchor.constraint(lessThanOrEqualTo: self.panel.bottomAnchor, constant: -16),
            self.send.leadingAnchor.constraint(equalTo: self.panel.leadingAnchor, constant: 20),
            self.send.trailingAnchor.constraint(equalTo: self.panel.trailingAnchor, constant: -20),
            self.send.heightAnchor.constraint(equalToConstant: 52),
            self.scroll.topAnchor.constraint(equalTo: self.panel.topAnchor, constant: 60),
            self.scroll.leadingAnchor.constraint(equalTo: self.panel.leadingAnchor),
            self.scroll.trailingAnchor.constraint(equalTo: self.panel.trailingAnchor),
            self.scroll.bottomAnchor.constraint(equalTo: self.send.topAnchor, constant: -12)
        ])
        self.stack.axis = .vertical
        self.stack.spacing = 16
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.scroll.addSubview(self.stack)
        NSLayoutConstraint.activate([
            self.stack.topAnchor.constraint(equalTo: self.scroll.contentLayoutGuide.topAnchor, constant: 20),
            self.stack.leadingAnchor.constraint(equalTo: self.scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            self.stack.trailingAnchor.constraint(equalTo: self.scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            self.stack.bottomAnchor.constraint(equalTo: self.scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            self.stack.widthAnchor.constraint(equalTo: self.scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        let holder = UIView()
        holder.heightAnchor.constraint(equalToConstant: 184).isActive = true
        self.artwork.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(self.artwork)
        let artworkWidth = self.artwork.widthAnchor.constraint(equalToConstant: 220)
        artworkWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            self.artwork.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            self.artwork.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            artworkWidth,
            self.artwork.widthAnchor.constraint(lessThanOrEqualTo: holder.widthAnchor, multiplier: 0.8),
            self.artwork.heightAnchor.constraint(equalTo: self.artwork.widthAnchor, multiplier: 0.75)
        ])
        self.artwork.update(style: .classic, accent: theme.list.itemAccentColor)
        self.artwork.setOpen(false, animated: false)
        self.recipient.text = self.strings[.to] + " " + self.peer.compactDisplayTitle
        self.currencyPicker.selectedSegmentIndex = 0
        self.currencyPicker.selectedSegmentTintColor = theme.list.itemAccentColor
        self.currencyPicker.setTitleTextAttributes([.foregroundColor: theme.list.itemPrimaryTextColor], for: .normal)
        self.currencyPicker.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        self.currencyPicker.accessibilityLabel = self.strings[.currency]
        self.currencyPicker.addTarget(self, action: #selector(self.currencyChanged), for: .valueChanged)
        self.currencyPicker.heightAnchor.constraint(equalToConstant: 40).isActive = true
        self.amount.placeholder = "0"
        self.amount.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: UIFont.systemFont(ofSize: 44, weight: .semibold), maximumPointSize: 64)
        self.amount.textAlignment = .center
        self.amount.keyboardType = .decimalPad
        self.amount.autocorrectionType = .no
        self.amount.spellCheckingType = .no
        self.amount.textColor = theme.list.itemPrimaryTextColor
        self.amount.accessibilityLabel = self.strings[.amount] + " " + self.currency.displayName
        self.amount.delegate = self
        self.amount.addTarget(self, action: #selector(self.inputChanged), for: .editingChanged)
        self.amount.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        self.comment.font = UIFont.preferredFont(forTextStyle: .body)
        self.comment.textColor = theme.list.itemPrimaryTextColor
        self.comment.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.comment.layer.cornerRadius = 14
        self.comment.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        self.comment.accessibilityLabel = self.strings[.commentPlaceholder]
        self.comment.delegate = self
        self.comment.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let amountRow = UIView()
        amountRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let amountGroup = UIStackView(arrangedSubviews: [self.amount, self.amountCurrency])
        amountGroup.axis = .horizontal
        amountGroup.alignment = .firstBaseline
        amountGroup.spacing = 8
        amountGroup.translatesAutoresizingMaskIntoConstraints = false
        amountRow.addSubview(amountGroup)
        self.amountCurrency.font = UIFont.preferredFont(forTextStyle: .title2)
        self.amountCurrency.textColor = theme.list.itemSecondaryTextColor
        self.amount.adjustsFontSizeToFitWidth = true
        self.amount.minimumFontSize = 16
        self.amountWidth = self.amount.widthAnchor.constraint(equalToConstant: 40)
        self.amountWidth?.priority = .defaultHigh
        self.amountWidth?.isActive = true
        NSLayoutConstraint.activate([
            amountGroup.centerXAnchor.constraint(equalTo: amountRow.centerXAnchor),
            amountGroup.centerYAnchor.constraint(equalTo: amountRow.centerYAnchor),
            amountGroup.leadingAnchor.constraint(greaterThanOrEqualTo: amountRow.leadingAnchor),
            amountGroup.trailingAnchor.constraint(lessThanOrEqualTo: amountRow.trailingAnchor)
        ])
        let commentTitle = UILabel()
        commentTitle.text = self.strings[.commentPlaceholder]
        commentTitle.font = UIFont.preferredFont(forTextStyle: .subheadline)
        commentTitle.textColor = theme.list.itemSecondaryTextColor
        for label in [self.recipient, self.balance, self.errorLabel] {
            label.font = UIFont.preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = theme.list.itemSecondaryTextColor
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        self.errorLabel.textColor = theme.list.itemDestructiveColor
        self.setupEffectPicker()
        for child in [holder, self.recipient, self.currencyPicker, amountRow, self.balance, self.effectPicker, commentTitle, self.comment, self.errorLabel] { self.stack.addArrangedSubview(child) }
        self.send.backgroundColor = theme.list.itemCheckColors.fillColor
        self.send.setTitleColor(theme.list.itemCheckColors.foregroundColor, for: .normal)
        self.send.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        self.send.layer.cornerRadius = 16
        self.send.addTarget(self, action: #selector(self.sendPressed), for: .touchUpInside)
        do {
            self.journal = try EnvelopeSendJournal(accountId: self.context.account.peerId.toInt64(), recipientId: self.peer.id.toInt64())
            try self.restorePendingSend()
        } catch {
            self.journal = nil
            self.errorLabel.text = self.strings[.unavailable]
        }
        self.updateButton()
        self.saveSetupContext()
        self.loadWallet()
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.layoutSize = layout.size
        self.layoutInsets = layout.safeInsets
        self.layoutInsets.top = max(self.layoutInsets.top, layout.statusBarHeight ?? 0)
        self.layoutSheet()
        self.animateInIfReady()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.appeared = true
        self.animateInIfReady()
    }

    private func animateInIfReady() {
        guard self.appeared, !self.presentedSheet, !self.dismissingSheet, self.panel.bounds.height > 0 else { return }
        self.presentedSheet = true
        self.dimming.layer.animateAlpha(from: 0, to: 1, duration: self.reduceMotion ? 0.14 : 0.28)
        if self.reduceMotion {
            self.panel.layer.animateAlpha(from: 0, to: 1, duration: 0.14)
        } else {
            self.panel.layer.animatePosition(from: CGPoint(x: 0, y: self.panel.bounds.height), to: .zero, duration: 0.34, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, additive: true)
        }
    }

    private func dismissSheet() {
        guard !self.dismissingSheet else { return }
        self.dismissingSheet = true
        self.panel.isUserInteractionEnabled = false
        let duration = self.reduceMotion ? 0.14 : 0.22
        let dimAlpha = CGFloat(self.dimming.layer.presentation()?.opacity ?? 1)
        self.dimming.alpha = 0
        self.dimming.layer.animateAlpha(from: dimAlpha, to: 0, duration: duration)
        let finish: (Bool) -> Void = { [weak self] _ in self?.dismiss() }
        if self.reduceMotion || self.panel.bounds.height == 0 {
            let opacity = CGFloat(self.panel.layer.presentation()?.opacity ?? 1)
            self.panel.alpha = 0
            self.panel.layer.animateAlpha(from: opacity, to: 0, duration: duration, completion: finish)
        } else {
            let offset = (self.panel.layer.presentation()?.position.y ?? self.panel.layer.position.y) - self.panel.layer.position.y
            let distance = self.view.bounds.maxY - self.panel.frame.minY
            self.panel.layer.animatePosition(from: CGPoint(x: 0, y: offset), to: CGPoint(x: 0, y: distance), duration: duration, timingFunction: CAMediaTimingFunctionName.easeIn.rawValue, removeOnCompletion: false, additive: true, completion: finish)
        }
    }

    private func layoutSheet() {
        guard self.isNodeLoaded else { return }
        let size = self.layoutSize == .zero ? self.view.bounds.size : self.layoutSize
        let insets = self.layoutInsets
        let width = min(560, size.width - insets.left - insets.right)
        let height = max(0, min(760, size.height - insets.top - 12))
        self.dimming.frame = CGRect(origin: .zero, size: size)
        // The surface stays behind the keyboard's rounded corners. Only the
        // footer and the scroll viewport follow the system keyboard.
        self.panel.frame = CGRect(x: (size.width - width) / 2, y: size.height - height, width: width, height: height)
        self.grabber.frame = CGRect(x: floor((width - 32) / 2), y: 7, width: 32, height: 4)
        self.header.frame = CGRect(x: 80, y: 0, width: max(0, width - 160), height: 60)
        self.close.frame = CGRect(x: width - 82, y: 6, width: 78, height: 48)
        self.displayNode.view.layoutIfNeeded()
    }

    private func saveSetupContext() {
        // Local operator tools bind a single-account configuration to the chat
        // currently open on this simulator. No credentials are written here.
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = directory.appendingPathComponent("telegram-envelopes-setup.json")
        if let data = try? JSONSerialization.data(withJSONObject: ["accountId": self.context.account.peerId.toInt64(), "recipientId": self.peer.id.toInt64()]) {
            try? data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }

    private func loadWallet() {
        if self.service == nil {
            do { self.service = try EnvelopeService(accountId: self.context.account.peerId.toInt64()) }
            catch {
                self.errorLabel.text = self.strings.error(error)
                self.updateButton()
                return
            }
        }
        self.availableBalance = nil
        self.balance.text = self.strings[.balance] + ": — " + self.currency.displayName
        let requestId = UUID()
        self.walletRequestId = requestId
        self.updateButton()
        self.service?.wallet(currency: self.currency) { [weak self] result in
            guard let self, self.walletRequestId == requestId else { return }
            self.walletRequestId = nil
            switch result {
            case let .success(wallet):
                self.availableBalance = wallet.balanceUnits
                let balanceText = self.strings[.balance] + ": " + wallet.displayText
                if self.presentedSheet && !self.reduceMotion {
                    UIView.transition(with: self.balance, duration: 0.16, options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]) {
                        self.balance.text = balanceText
                    }
                } else {
                    self.balance.text = balanceText
                }
            case let .failure(error): self.errorLabel.text = self.strings.error(error)
            }
            self.updateButton()
        }
    }

    @objc private func inputChanged() {
        self.errorLabel.text = nil
        self.updateButton()
    }
    @objc private func currencyChanged() {
        guard !self.busy, self.pendingSend == nil else { return }
        self.currency = self.currencyPicker.selectedSegmentIndex == 0 ? .ton : .usdt
        self.amount.placeholder = "0"
        self.amount.accessibilityLabel = self.strings[.amount] + " " + self.currency.displayName
        self.errorLabel.text = nil
        self.updateButton()
        self.loadWallet()
    }
    public func textFieldDidBeginEditing(_ textField: UITextField) {
        self.scroll.focusedField = textField
        self.scroll.revealFocusedField()
        self.updateButton()
    }
    public func textFieldDidEndEditing(_ textField: UITextField) { self.updateButton() }
    public func textViewDidBeginEditing(_ textView: UITextView) {
        self.scroll.focusedField = textView
        self.scroll.revealFocusedField()
        self.updateButton()
    }
    public func textViewDidEndEditing(_ textView: UITextView) { self.updateButton() }
    public func textViewDidChange(_ textView: UITextView) { self.inputChanged() }
    public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        return (textField.text?.utf16.count ?? 0) - range.length + string.utf16.count <= 22
    }
    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let value = textView.text, let swiftRange = Range(range, in: value) else { return false }
        return value.replacingCharacters(in: swiftRange, with: text).unicodeScalars.count <= 200
    }

    private func updateButton() {
        self.updateAmountLayout()
        let value = try? EnvelopeAmount(userInput: self.amount.text ?? "", currency: self.currency)
        let enough = value.map { $0.units <= (self.availableBalance ?? 0) } ?? false
        let walletRetry = self.service != nil && self.availableBalance == nil && self.walletRequestId == nil
        let title = self.pendingSend == nil && !walletRetry ? self.strings[.sendTon].replacingOccurrences(of: "%@", with: value?.displayText ?? self.currency.displayName) : self.strings[.tryAgain]
        self.send.setTitle(self.busy ? self.strings[.sending] : title, for: .normal)
        self.send.isEnabled = !self.busy && self.journal != nil && self.service != nil && (self.pendingSend != nil || enough || walletRetry)
        let alpha: CGFloat = self.send.isEnabled ? 1 : 0.5
        if self.send.alpha != alpha {
            if self.presentedSheet && !self.reduceMotion {
                UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.send.alpha = alpha }
            } else {
                self.send.alpha = alpha
            }
        }
        self.close.setTitle(self.amount.isFirstResponder || self.comment.isFirstResponder ? self.data.strings.Common_Done : self.strings[.close], for: .normal)
        self.close.isEnabled = !self.busy
        self.amount.isEnabled = !self.busy && self.pendingSend == nil
        self.comment.isEditable = !self.busy && self.pendingSend == nil
        self.effectPicker.isUserInteractionEnabled = !self.busy && self.pendingSend == nil
        self.effectPicker.alpha = self.effectPicker.isUserInteractionEnabled ? 1 : 0.6
        self.currencyPicker.isEnabled = !self.busy && self.pendingSend == nil
        if self.pendingSend == nil, value != nil, self.availableBalance != nil, !enough { self.errorLabel.text = self.strings[.insufficient] }
        self.errorLabel.isHidden = self.errorLabel.text?.isEmpty != false
    }

    @objc private func sendPressed() {
        guard !self.busy, let service = self.service, let journal = self.journal else { return }
        if self.pendingSend == nil && self.availableBalance == nil { self.loadWallet(); return }
        do {
            let value = try EnvelopeAmount(userInput: self.amount.text ?? "", currency: self.currency)
            // Persist before HTTP. A reopened form or an uncertain response must
            // retry the same payload/key, even when its funds are already reserved.
            let pending = try journal.begin(amount: value, message: self.comment.text ?? "", openingEmoji: self.openingEmoji)
            try self.restorePendingSend()
            self.busy = true
            self.view.endEditing(true)
            self.errorLabel.text = nil
            self.updateButton()
            if pending.stage == .refunding {
                self.refund(pending, service: service)
                return
            }
            let originalAmount = try EnvelopeAmount(text: pending.amountText, currency: pending.currency)
            service.create(recipientId: pending.recipientId, amount: originalAmount, message: pending.message, submissionId: pending.submissionId) { [weak self] result in
                guard let self else { return }
                do {
                    switch result {
                    case let .success(envelope):
                        switch try journal.acceptCreated(envelope, submissionId: pending.submissionId) {
                        case let .readyToQueue(ready): self.queue(ready, service: service)
                        case .refunded: self.finishRefund()
                        case .delivered: self.dismissSheet()
                        }
                    case let .failure(error):
                        if pending.stage == .creating, case let EnvelopeServiceError.rejected(code) = error {
                            try journal.rejectCreate(submissionId: pending.submissionId, code: code)
                        }
                        self.finishWithError(error)
                    }
                } catch { self.finishWithError(error) }
            }
        } catch { self.finishWithError(error) }
    }

    private func restorePendingSend() throws {
        self.pendingSend = try self.journal?.pendingOperation()
        if let pending = self.pendingSend {
            self.openingEmoji = pending.openingEmoji
            self.updateEffectPicker()
            self.currency = pending.currency
            self.currencyPicker.selectedSegmentIndex = pending.currency == .ton ? 0 : 1
            self.amount.text = pending.amountText
            self.comment.text = pending.message
            self.errorLabel.text = self.strings[.pendingSend]
        }
        self.amount.placeholder = "0"
        self.amount.accessibilityLabel = self.strings[.amount] + " " + self.currency.displayName
    }

    private func queue(_ pending: EnvelopePendingSend, service: EnvelopeService) {
        guard let reference = pending.reference, let journal = self.journal else { return }
        self.pendingSend = pending
        var transport = reference
        transport.openingEmoji = pending.openingEmoji
        self.sendMessage(transport.messageText) { [weak self] queued in
            guard let self else { return }
            do {
                if queued {
                    EnvelopeSenderOpenings.shared.observe(reference, state: .sent, visible: false)
                    // A cleanup failure must never cancel a delivered envelope.
                    try journal.confirmQueued(submissionId: pending.submissionId)
                    self.dismissSheet()
                } else {
                    let refund = try journal.beginRefund(submissionId: pending.submissionId)
                    self.pendingSend = refund
                    self.refund(refund, service: service)
                }
            } catch { self.finishWithError(error) }
        }
    }

    private func refund(_ pending: EnvelopePendingSend, service: EnvelopeService) {
        guard let reference = pending.reference, let journal = self.journal else { return }
        service.cancel(reference) { [weak self] result in
            guard let self else { return }
            do {
                switch result {
                case let .success(envelope):
                    switch try journal.acceptRefund(envelope, submissionId: pending.submissionId) {
                    case .refunded: self.finishRefund()
                    case .delivered: self.dismissSheet()
                    case .readyToQueue: self.finishWithError(EnvelopeServiceError.invalidResponse)
                    }
                case let .failure(error): self.finishWithError(error)
                }
            } catch { self.finishWithError(error) }
        }
    }

    private func finishRefund() {
        self.busy = false
        self.pendingSend = nil
        self.errorLabel.text = self.strings[.cancelled]
        self.loadWallet()
        self.updateButton()
    }

    private func finishWithError(_ error: Error) {
        self.busy = false
        do { try self.restorePendingSend() }
        catch { self.journal = nil }
        self.errorLabel.text = self.pendingSend == nil ? self.strings.error(error) : self.strings[.pendingSend]
        self.updateButton()
    }

    @objc private func closePressed() {
        guard !self.busy else { return }
        if self.amount.isFirstResponder || self.comment.isFirstResponder {
            self.view.endEditing(true)
            self.updateButton()
        } else {
            self.dismissSheet()
        }
    }
}
