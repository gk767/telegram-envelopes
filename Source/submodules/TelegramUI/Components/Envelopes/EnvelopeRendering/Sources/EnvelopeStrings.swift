import Foundation

import AppBundle
import TelegramEnvelopes
import TelegramPresentationData

/// Uses the active Telegram language pack first. Bundled Russian covers prototype keys
/// that are not published in Telegram's localization service.
public struct EnvelopeStrings {
    public enum Key: String {
        case openingEmoji, noEmoji, tonTitle, sentHeader, receivedHeader, moneyEnvelope, waiting, opened, loading, tryAgain, unavailable, serviceNotConfigured, pendingSend, balanceCredited, sendTon, commentPlaceholder, invalidRecipient
        case attachment, title, demo, sender, recipient, compose, to, from, currency, amount, balance, message, appearance, classic, midnight, gradient, celebration, preview, send, back, close, cancel, expire, fail, reset, empty, open, unopened, opening, received, cancelled, expired, failed, sending, invalid, insufficient, longMessage, limit, invalidState, simulationNote, precision, qa, receipt, switchRecipient, failureEnabled, pickStyle
    }
    private let strings: PresentationStrings
    private static let russian: [String: String] = {
        guard let path = getAppBundle().path(forResource: "Envelope", ofType: "strings", inDirectory: nil, forLocalization: "ru"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else { return [:] }
        return value
    }()
    public init(_ strings: PresentationStrings) { self.strings = strings }
    public subscript(_ key: Key) -> String {
        let raw = key.rawValue
        let identifier = "EnvelopeDemo." + raw.prefix(1).uppercased() + raw.dropFirst()
        if let value = self.strings.primaryComponent.dict[identifier] { return value }
        if self.strings.primaryComponent.languageCode.hasPrefix("ru"), let value = Self.russian[identifier] { return value }
        return defaultPresentationStrings.primaryComponent.dict[identifier] ?? identifier
    }
    public func style(_ style: EnvelopeStyle) -> String {
        switch style {
        case .classic: return self[.classic]
        case .midnight: return self[.midnight]
        case .gradient: return self[.gradient]
        case .celebration: return self[.celebration]
        }
    }
    public func state(_ state: EnvelopeState) -> String {
        switch state {
        case .draft, .ready, .sending, .sent: return self[.sending]
        case .unopened: return self[.unopened]
        case .opening: return self[.opening]
        case .received: return self[.received]
        case .cancelled: return self[.cancelled]
        case .expired: return self[.expired]
        case .failed: return self[.failed]
        }
    }
    public func error(_ error: Error) -> String {
        if error is URLError { return self[.unavailable] }
        if let serviceError = error as? EnvelopeServiceError {
            switch serviceError {
            case .configuration: return self[.serviceNotConfigured]
            case .rejected("insufficient_balance"): return self[.insufficient]
            case .rejected("invalid_recipient"): return self[.invalidRecipient]
            case .rejected("invalid_amount"): return self[.invalid]
            case .rejected("message_too_long"): return self[.longMessage]
            default: return self[.unavailable]
            }
        }
        switch error as? EnvelopeError {
        case .insufficientBalance: return self[.insufficient]
        case .messageTooLong: return self[.longMessage]
        case .limitReached: return self[.limit]
        case .simulatedFailure: return self[.failed]
        case .invalidTransition, .missingEnvelope: return self[.invalidState]
        default: return self[.invalid]
        }
    }
}
