import Foundation
import UIKit
import AsyncDisplayKit
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import Display
import EnvelopeRendering
import LottieSettings
import TelegramCore
import TelegramEnvelopes
import TelegramPresentationData
import WallpaperBackgroundNode

/// A persisted Telegram history message carries a reference, never a claim capability.
public final class ChatMessageEnvelopeBubbleContentNode: ChatMessageBubbleContentNode {
    private struct CardContent: Equatable {
        let title: String
        let message: String
        let status: String
        let actionTitle: String
        let showsAction: Bool
        let showsCancel: Bool
    }

    private let card = UIControl()
    private var backgroundNode: WallpaperBubbleBackgroundNode?
    private var headerBackgroundNode: WallpaperBubbleBackgroundNode?
    private let artwork = EnvelopeArtworkView()
    private let header = UILabel()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let stateLabel = UILabel()
    private let timeLabel = UILabel()
    private let button = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var reference: EnvelopeMessageReference?
    private var envelope: TonEnvelope?
    private var service: EnvelopeService?
    private var strings: EnvelopeStrings?
    private var isRecipient = false
    private var busy = false
    private var fetchId: UUID?
    private var stateGeneration = 0
    private var needsRefresh = false
    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?
    private var isAnimatingOpen = false
    private weak var openingBurst: EnvelopeOpeningBurstView?
    private var walletBalance: String?
    private var errorText: String?
    private var cardContent: CardContent?
    private var layoutUpdateScheduled = false

    public static func reference(message: EngineRawMessage, accountPeerId: EnginePeer.Id) -> EnvelopeMessageReference? {
        guard message.id.peerId.namespace == Namespaces.Peer.CloudUser, message.media.isEmpty else { return nil }
        return EnvelopeMessageReference.parse(message.text, authorId: message.author?.id.toInt64(), accountId: accountPeerId.toInt64(), chatPeerId: message.id.peerId.toInt64(), isForwarded: message.forwardInfo != nil)
    }

    public required init(lottieSettings: LottieRenderingSettings) {
        super.init(lottieSettings: lottieSettings)
        self.card.backgroundColor = .clear
        self.card.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        for label in [self.header, self.titleLabel, self.messageLabel, self.stateLabel, self.timeLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
        }
        for child in [self.header, self.artwork, self.titleLabel, self.messageLabel, self.stateLabel, self.button, self.cancelButton, self.timeLabel] { self.card.addSubview(child) }
        self.button.layer.cornerRadius = 17
        self.button.titleLabel?.adjustsFontSizeToFitWidth = true
        self.button.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        self.cancelButton.layer.cornerRadius = 17
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        self.pollTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
    public override func didLoad() { super.didLoad(); self.view.addSubview(self.card) }
    public override var visibility: ListViewItemNodeVisibility {
        didSet {
            if case .none = self.visibility {
                self.openingBurst?.removeFromSuperview()
            }
            self.updatePolling()
        }
    }

    private func updatePolling() {
        guard case .visible = self.visibility, self.envelope == nil || self.envelope?.state == .sent else {
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            return
        }
        guard self.pollTimer == nil else { return }
        self.refresh()
        self.pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard UIApplication.shared.applicationState == .active else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        if self.service == nil, let item = self.item {
            self.service = try? EnvelopeService(accountId: item.context.account.peerId.toInt64())
        }
        guard self.fetchId == nil, !self.busy, let reference = self.reference, let service = self.service else { return }
        let fetchId = UUID()
        let generation = self.stateGeneration
        self.fetchId = fetchId
        service.fetch(reference) { [weak self] result in
            guard let self, self.reference == reference, self.fetchId == fetchId else { return }
            self.fetchId = nil
            guard self.stateGeneration == generation else { return }
            switch result {
            case let .success(envelope):
                // A reply may arrive after the app was backgrounded or the cell
                // scrolled away. Let the next visible poll present the opening.
                if !self.isRecipient && envelope.state == .opened && !self.canPresentOpening { return }
                self.errorText = nil
                self.needsRefresh = false
                self.presentReceipt(envelope)
                self.refreshWallet()
                if envelope.state != .sent { self.pollTimer?.invalidate(); self.pollTimer = nil }
            case let .failure(error):
                self.needsRefresh = true
                self.errorText = self.strings?.error(error)
                self.stateLabel.text = self.errorText
                self.button.setTitle(self.strings?[.tryAgain], for: .normal)
                self.button.isEnabled = true
                self.updateCardContent()
            }
        }
    }

    private var canPresentOpening: Bool {
        guard case .visible = self.visibility else { return false }
        return self.card.window != nil && UIApplication.shared.applicationState == .active
    }

    private func presentReceipt(_ envelope: TonEnvelope, newlyClaimed: Bool = false) {
        let visible = self.canPresentOpening
        if visible, !self.isRecipient, self.envelope == nil, envelope.state == .sent, let item = self.item,
           abs(Date().timeIntervalSince1970 - Double(item.message.timestamp)) < 10,
           !item.context.sharedContext.currentPresentationData.with({ $0.reduceMotion }) {
            self.artwork.settle(opening: false)
        }
        let celebrate = self.isRecipient ? newlyClaimed : EnvelopeSenderOpenings.shared.observe(envelope.reference, state: envelope.state, visible: visible)
        self.envelope = envelope
        let animate = celebrate && visible
        if animate && !self.isRecipient && !self.isAnimatingOpen {
            // A cached node can have applied an opened receipt while offscreen.
            self.artwork.setOpen(false, animated: false)
        }
        self.updateState(animated: animate)
        if animate, let item = self.item, !item.context.sharedContext.currentPresentationData.with({ $0.reduceMotion }) {
            self.openingBurst = EnvelopeOpeningBurstView.play(in: self.card, artwork: self.artwork.frame, glyphs: self.reference?.openingEmoji ?? [])
        }
    }

    @objc private func pressed() {
        guard !self.busy else { return }
        guard let reference = self.reference, let service = self.service else {
            self.errorText = self.strings?[.unavailable]
            self.stateLabel.text = self.errorText
            self.updateCardContent()
            self.refresh()
            return
        }
        guard self.envelope != nil, !self.needsRefresh else { self.refresh(); return }
        guard self.isRecipient, self.envelope?.state == .sent else { return }
        self.busy = true
        self.errorText = nil
        self.stateGeneration += 1
        self.button.isEnabled = false
        self.button.setTitle(self.strings?[.opening], for: .normal)
        self.updateCardContent()
        // Credit precedes the animation. Retries return the same receipt.
        service.claim(reference) { [weak self] result in
            guard let self, self.reference == reference else { return }
            self.busy = false
            switch result {
            case let .success(envelope):
                let openedNow = envelope.state == .opened && envelope.openedNow == true
                self.presentReceipt(envelope, newlyClaimed: openedNow)
                self.refreshWallet()
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                if openedNow { HapticFeedback().success() }
            case let .failure(error):
                self.errorText = self.strings?.error(error)
                self.updateState(animated: false)
            }
        }
    }

    private func refreshWallet() {
        guard self.isRecipient, self.envelope?.state == .opened, self.walletBalance == nil,
              let reference = self.reference else { return }
        self.service?.wallet(currency: reference.currency) { [weak self] result in
            guard let self, self.reference == reference, case let .success(wallet) = result else { return }
            self.walletBalance = wallet.displayText
            self.updateState(animated: false)
        }
    }

    @objc private func cancelPressed() {
        guard !self.busy, !self.isRecipient, self.envelope?.state == .sent,
              let reference = self.reference, let service = self.service else { return }
        self.busy = true
        self.errorText = nil
        self.stateGeneration += 1
        self.cancelButton.isEnabled = false
        service.cancel(reference) { [weak self] result in
            guard let self, self.reference == reference else { return }
            self.busy = false
            switch result {
            case let .success(envelope): self.presentReceipt(envelope)
            case let .failure(error):
                self.errorText = self.strings?.error(error)
                self.stateLabel.text = self.errorText
                self.cancelButton.isEnabled = true
                self.updateCardContent()
            }
        }
    }

    private func updateState(animated: Bool) {
        guard let strings, let item = self.item else { return }
        let opened = self.envelope?.state == .opened
        let amount = self.envelope?.amountText ?? ""
        self.titleLabel.text = opened ? amount : strings[.moneyEnvelope]
        self.messageLabel.text = self.envelope?.message
        self.cancelButton.isHidden = self.isRecipient || self.envelope?.state != .sent
        self.cancelButton.isEnabled = !self.busy
        self.button.isEnabled = self.service == nil || self.needsRefresh || (self.isRecipient && self.envelope?.state == .sent && !self.busy)
        let status: String
        switch self.envelope?.state {
        case .sent: status = self.isRecipient ? strings[.unopened] : amount + " · " + strings[.waiting]
        case .opened: status = self.isRecipient ? strings[.balanceCredited].replacingOccurrences(of: "%@", with: amount) : strings[.opened]
        case .cancelled: status = strings[.cancelled]
        case .expired: status = strings[.expired]
        case nil: status = self.service == nil ? strings[.unavailable] : strings[.loading]
        }
        self.stateLabel.text = self.errorText ?? (status + (self.walletBalance.map { "\n" + strings[.balance] + ": " + $0 } ?? ""))
        let actionTitle: String
        switch self.envelope?.state {
        case nil: actionTitle = self.service == nil || self.needsRefresh ? strings[.tryAgain] : strings[.loading]
        case .opened: actionTitle = strings[.opened]
        case .cancelled: actionTitle = strings[.cancelled]
        case .expired: actionTitle = strings[.expired]
        default: actionTitle = self.isRecipient ? strings[.open] : strings[.waiting]
        }
        self.button.setTitle(actionTitle, for: .normal)
        self.button.alpha = self.button.isEnabled ? 1 : 0.6
        self.updateCardContent()
        self.artwork.update(style: .classic, accent: item.presentationData.theme.theme.list.itemAccentColor, amount: opened ? amount : "")
        if !self.isAnimatingOpen {
            self.isAnimatingOpen = animated
            let reference = self.reference
            self.artwork.setOpen(opened, animated: animated && !item.context.sharedContext.currentPresentationData.with { $0 }.reduceMotion) { [weak self] in
                guard let self, self.reference == reference else { return }
                self.isAnimatingOpen = false
                if animated { UIAccessibility.post(notification: .announcement, argument: status) }
            }
        }
    }

    private func updateCardContent() {
        // A sender's waiting status is text, not a second, disabled action button.
        let showsAction = self.envelope == nil || self.service == nil || self.needsRefresh || (self.isRecipient && self.envelope?.state == .sent)
        self.button.isHidden = !showsAction
        let content = CardContent(
            title: self.titleLabel.text ?? "",
            message: self.messageLabel.text ?? "",
            status: self.stateLabel.text ?? "",
            actionTitle: self.button.title(for: .normal) ?? "",
            showsAction: showsAction,
            showsCancel: !self.cancelButton.isHidden
        )
        guard self.cardContent != content else { return }
        self.cardContent = content
        // Fetches update the measured text only when it changes. Polling the same
        // receipt must not start a layout -> fetch -> layout loop.
        guard !self.layoutUpdateScheduled else { return }
        self.layoutUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutUpdateScheduled = false
            guard let item = self.item else { return }
            let _ = item.controllerInteraction.requestMessageUpdate(item.message.id, false, nil)
        }
    }

    public override func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let currentReference = self.reference
        let currentContent = self.cardContent
        return { [weak self] item, _, _, _, _, _ in
            let reference = Self.reference(message: item.message, accountPeerId: item.context.account.peerId)
            let strings = EnvelopeStrings(item.presentationData.strings)
            let recipient = reference?.recipientId == item.context.account.peerId.toInt64()
            let name = item.message.peers[item.message.id.peerId].map { EnginePeer($0).compactDisplayTitle } ?? ""
            let headerText = strings[recipient ? .receivedHeader : .sentHeader].replacingOccurrences(of: "%@", with: name)
            let content = currentReference == reference ? currentContent : nil
            let titleText = content?.title ?? strings[.moneyEnvelope]
            let messageText = content?.message ?? ""
            let statusText = content?.status ?? strings[.loading]
            let showsAction = content?.showsAction ?? true
            let showsCancel = content?.showsCancel ?? false
            let actionTitle = content?.actionTitle ?? strings[.loading]
            let properties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 0, hidesBackground: .always, forceFullCorners: true, forceAlignment: .center, hidesHeaders: true)
            // Match ChatMessageGiftBubbleContentNode's 220 pt gift, 15/13 pt
            // typography and 34 pt pill, including the same wallpaper material.
            return (properties, nil, 220, { constrained, _ in
                let width = min(220, constrained.width)
                let inner = max(1, width - 32)
                let headerFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: Font.regular(13))
                let titleFont = UIFontMetrics(forTextStyle: .headline).scaledFont(for: Font.semibold(15))
                let bodyFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: Font.regular(13))
                let buttonFont = UIFontMetrics(forTextStyle: .headline).scaledFont(for: Font.semibold(15))
                let footerFont = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: Font.regular(10))
                func measure(_ text: String, font: UIFont, width: CGFloat, lines: Int) -> CGSize {
                    guard !text.isEmpty else { return .zero }
                    let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
                    return CGSize(width: min(width, ceil(rect.width)), height: min(ceil(font.lineHeight * CGFloat(lines)), ceil(rect.height)))
                }
                let headerSize = measure(headerText, font: headerFont, width: width - 16, lines: 2)
                // Include the gap in the measured item, so history scrolling and
                // insertion preserve space above the entire gift-style card.
                let headerFrame = CGRect(x: floor((width - headerSize.width - 16) / 2), y: 26, width: headerSize.width + 16, height: headerSize.height + 8)
                let cardTop = headerFrame.maxY + 8
                let artWidth = min(120, inner)
                let artHeight = artWidth * 0.75
                // Both the closed illustration and the raised paper fit in the
                // gift's media area; opening does not change its frame or scale.
                let artTop = cardTop + 6 + artHeight * 0.48
                let titleTop = cardTop + 151
                let titleHeight = measure(titleText, font: titleFont, width: inner, lines: 2).height
                let messageHeight = measure(messageText, font: bodyFont, width: inner, lines: 3).height
                let messageTop = titleTop + titleHeight + (messageHeight > 0 ? 5 : 0)
                let statusTop = messageTop + messageHeight + 5
                let statusHeight = measure(statusText, font: bodyFont, width: inner, lines: 3).height
                let buttonTop = statusTop + statusHeight + 10
                let buttonHeight = max(34, ceil(buttonFont.lineHeight) + 16)
                let buttonWidth = min(inner, max(64, measure(actionTitle, font: buttonFont, width: inner - 38, lines: 1).width + 38))
                let cancelWidth = min(inner, max(64, measure(strings[.cancel], font: buttonFont, width: inner - 38, lines: 1).width + 38))
                let cancelTop = buttonTop + (showsAction ? buttonHeight + 6 : 0)
                let actionsBottom = showsCancel ? cancelTop + buttonHeight : (showsAction ? buttonTop + buttonHeight : statusTop + statusHeight)
                let footerTop = actionsBottom + 10
                let footerHeight = ceil(footerFont.lineHeight)
                let size = CGSize(width: width, height: footerTop + footerHeight + 12)
                let mediaFrame = CGRect(x: 0, y: cardTop, width: width, height: size.height - cardTop)
                return (width, { _ in
                    return (size, { [weak self] animation, _, _ in
                        guard let self, let reference else { return }
                        let changed = self.reference != reference
                        self.item = item
                        self.strings = strings
                        self.isRecipient = recipient
                        self.header.text = headerText
                        self.header.font = headerFont
                        self.header.numberOfLines = 2
                        self.titleLabel.font = titleFont
                        self.titleLabel.numberOfLines = 2
                        self.messageLabel.font = bodyFont
                        self.messageLabel.numberOfLines = 3
                        self.stateLabel.font = bodyFont
                        self.stateLabel.numberOfLines = 3
                        self.timeLabel.font = footerFont
                        self.timeLabel.numberOfLines = 1
                        self.timeLabel.adjustsFontSizeToFitWidth = true
                        self.button.titleLabel?.font = buttonFont
                        self.cancelButton.titleLabel?.font = buttonFont
                        self.cancelButton.titleLabel?.adjustsFontSizeToFitWidth = true
                        let theme = item.presentationData.theme.theme
                        let colors = serviceMessageColorComponents(theme: theme, wallpaper: item.presentationData.theme.wallpaper)
                        self.card.frame = CGRect(origin: .zero, size: size)
                        if self.backgroundNode == nil, let background = item.controllerInteraction.presentationContext.backgroundNode?.makeBubbleBackground(for: .free) {
                            background.isUserInteractionEnabled = false
                            background.clipsToBounds = true
                            background.cornerRadius = 24
                            self.backgroundNode = background
                            self.insertSubnode(background, at: 0)
                        }
                        if self.headerBackgroundNode == nil, let background = item.controllerInteraction.presentationContext.backgroundNode?.makeBubbleBackground(for: .free) {
                            background.isUserInteractionEnabled = false
                            background.clipsToBounds = true
                            self.headerBackgroundNode = background
                            self.insertSubnode(background, at: 0)
                        }
                        if let background = self.backgroundNode {
                            animation.animator.updateFrame(layer: background.layer, frame: mediaFrame, completion: nil)
                        }
                        if let background = self.headerBackgroundNode {
                            background.cornerRadius = min(20, headerFrame.height / 2)
                            animation.animator.updateFrame(layer: background.layer, frame: headerFrame, completion: nil)
                        }
                        self.header.textColor = colors.primaryText
                        self.titleLabel.textColor = colors.primaryText
                        self.messageLabel.textColor = colors.primaryText
                        self.stateLabel.textColor = colors.primaryText
                        self.timeLabel.textColor = colors.primaryText.withAlphaComponent(0.7)
                        let overlayColor = theme.overallDarkAppearance ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.12)
                        self.button.backgroundColor = overlayColor
                        self.cancelButton.backgroundColor = overlayColor
                        self.button.layer.cornerRadius = buttonHeight / 2
                        self.cancelButton.layer.cornerRadius = buttonHeight / 2
                        self.button.setTitleColor(colors.primaryText, for: .normal)
                        self.cancelButton.setTitleColor(colors.primaryText, for: .normal)
                        self.cancelButton.setTitle(strings[.cancel], for: .normal)
                        self.header.frame = headerFrame.insetBy(dx: 8, dy: 4)
                        self.artwork.frame = CGRect(x: (width - artWidth) / 2, y: artTop, width: artWidth, height: artHeight)
                        self.titleLabel.frame = CGRect(x: 16, y: titleTop, width: inner, height: titleHeight)
                        self.messageLabel.frame = CGRect(x: 16, y: messageTop, width: inner, height: messageHeight)
                        self.messageLabel.isHidden = messageText.isEmpty
                        self.stateLabel.frame = CGRect(x: 16, y: statusTop, width: inner, height: statusHeight)
                        self.button.frame = CGRect(x: floor((width - buttonWidth) / 2), y: buttonTop, width: buttonWidth, height: buttonHeight)
                        self.cancelButton.frame = CGRect(x: floor((width - cancelWidth) / 2), y: cancelTop, width: cancelWidth, height: buttonHeight)
                        self.timeLabel.frame = CGRect(x: 16, y: footerTop, width: inner, height: footerHeight)
                        let date = Date(timeIntervalSince1970: TimeInterval(item.message.timestamp))
                        self.timeLabel.text = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
                        if changed {
                            self.openingBurst?.removeFromSuperview()
                            self.reference = reference
                            self.cardContent = nil
                            self.envelope = nil
                            self.walletBalance = nil
                            self.errorText = nil
                            self.pollTimer?.invalidate()
                            self.pollTimer = nil
                            self.busy = false
                            self.fetchId = nil
                            self.needsRefresh = false
                            self.stateGeneration += 1
                            self.isAnimatingOpen = false
                            self.service = try? EnvelopeService(accountId: item.context.account.peerId.toInt64())
                            self.artwork.setOpen(false, animated: false)
                            if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
                            self.observer = NotificationCenter.default.addObserver(forName: EnvelopeService.changed, object: nil, queue: .main) { [weak self] notification in
                                guard notification.object as? UUID == self?.reference?.id else { return }
                                self?.refresh()
                            }
                        }
                        self.updateState(animated: false)
                        self.updatePolling()
                    })
                })
            })
        }
    }

    public override func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        return ChatMessageBubbleContentTapAction(content: .ignore)
    }
}
