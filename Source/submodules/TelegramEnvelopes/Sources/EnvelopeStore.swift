import Foundation

/// Demo-only display precision. These values describe no blockchain or token contract.
public enum EnvelopeCurrency: String, CaseIterable, Codable {
    case usdt = "USDT"
    case gram = "GRAM"
    case ton = "TON"

    public var displayName: String { self == .usdt ? "USDT" : "Gram" }

    public var demoFractionDigits: Int { return self == .ton ? 9 : self == .usdt ? 6 : 4 }
    public var demoScale: Int64 { return self == .ton ? 1_000_000_000 : self == .usdt ? 1_000_000 : 10_000 }
}

public enum EnvelopeStyle: Int, CaseIterable, Codable {
    case classic, midnight, gradient, celebration
}

public enum EnvelopeState: String, Codable {
    case draft, ready, sending, sent, unopened, opening, received, cancelled, expired, failed
}

public enum EnvelopeError: Error, Equatable {
    case invalidAmount, insufficientBalance, invalidTransition, missingEnvelope, messageTooLong, limitReached, simulatedFailure
}

public struct EnvelopeAmount: Equatable {
    public let units: Int64
    public let currency: EnvelopeCurrency

    /// Strict ASCII decimal syntax, accepting the decimal keyboard's dot or comma.
    /// No exponent, grouping, sign, rounding, non-finite value or binary floating point.
    public init(text: String, currency: EnvelopeCurrency) throws {
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty,
              whole.utf8.allSatisfy({ (48 ... 57).contains($0) }), whole.count <= 12 else {
            throw EnvelopeError.invalidAmount
        }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= currency.demoFractionDigits,
              fraction.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let integer = Int64(whole) else { throw EnvelopeError.invalidAmount }
        let scaled = integer.multipliedReportingOverflow(by: currency.demoScale)
        let padded = fraction + String(repeating: "0", count: currency.demoFractionDigits - fraction.count)
        let total = scaled.partialValue.addingReportingOverflow(Int64(padded) ?? 0)
        guard !scaled.overflow, !total.overflow, total.partialValue > 0 else { throw EnvelopeError.invalidAmount }
        self.units = total.partialValue
        self.currency = currency
    }

    /// Text fields may append whitespace through hardware-keyboard suggestions.
    public init(userInput: String, currency: EnvelopeCurrency) throws {
        try self.init(text: userInput.trimmingCharacters(in: .whitespacesAndNewlines), currency: currency)
    }

    public var text: String {
        let whole = self.units / self.currency.demoScale
        let remainder = self.units % self.currency.demoScale
        guard remainder != 0 else { return String(whole) }
        var fraction = String(remainder)
        fraction = String(repeating: "0", count: self.currency.demoFractionDigits - fraction.count) + fraction
        while fraction.last == "0" { fraction.removeLast() }
        return "\(whole).\(fraction)"
    }

    public var displayText: String { return "\(self.text) \(self.currency.displayName)" }
}

public struct DemoEnvelope: Equatable {
    public let id: Int32
    public let submissionId: UUID
    public let amount: EnvelopeAmount
    public let style: EnvelopeStyle
    public let message: String
    public let createdAt: Date
    public let expiresAt: Date
    public fileprivate(set) var state: EnvelopeState
    public fileprivate(set) var transitions: [EnvelopeState]
}

/// A bounded in-memory ledger. No network, wallet, keys, Postbox or payment APIs.
/// Each mutation is serialized; claim and refund are mutually exclusive and happen once.
public final class EnvelopeDemoStore {
    public static let capacity = 100
    private let lock = NSLock()
    private var records: [DemoEnvelope] = []
    private var sender: [EnvelopeCurrency: Int64] = [.usdt: 1_000_000_000, .gram: 25_000_000]
    private var recipient: [EnvelopeCurrency: Int64] = [.usdt: 0, .gram: 0]

    public init() {}

    public var envelopes: [DemoEnvelope] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.records
    }

    public func balance(_ currency: EnvelopeCurrency, recipient: Bool = false) -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        let units = (recipient ? self.recipient : self.sender)[currency, default: 0]
        // The parser deliberately excludes zero; format balances without creating an amount.
        if units == 0 { return "0" }
        let whole = units / currency.demoScale
        let fraction = units % currency.demoScale
        if fraction == 0 { return String(whole) }
        var suffix = String(fraction)
        suffix = String(repeating: "0", count: currency.demoFractionDigits - suffix.count) + suffix
        while suffix.last == "0" { suffix.removeLast() }
        return "\(whole).\(suffix)"
    }

    public func validate(amount: EnvelopeAmount, message: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        try self.validateLocked(amount: amount, message: message)
    }

    private func validateLocked(amount: EnvelopeAmount, message: String) throws {
        guard message.count <= 200 else { throw EnvelopeError.messageTooLong }
        guard self.records.count < Self.capacity else { throw EnvelopeError.limitReached }
        guard self.sender[amount.currency, default: 0] >= amount.units else { throw EnvelopeError.insufficientBalance }
    }

    @discardableResult
    public func beginSend(submissionId: UUID, amount: EnvelopeAmount, style: EnvelopeStyle, message: String, now: Date) throws -> DemoEnvelope {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let existing = self.records.first(where: { $0.submissionId == submissionId }) { return existing }
        try self.validateLocked(amount: amount, message: message)
        self.sender[amount.currency, default: 0] -= amount.units
        let record = DemoEnvelope(id: Int32(self.records.count + 1), submissionId: submissionId, amount: amount, style: style, message: message, createdAt: now, expiresAt: now.addingTimeInterval(24 * 60 * 60), state: .sending, transitions: [.draft, .ready, .sending])
        self.records.append(record)
        return record
    }

    @discardableResult
    public func completeSend(_ id: Int32, success: Bool) throws -> DemoEnvelope {
        return try self.mutate(id) { record in
            guard record.state == .sending else { throw EnvelopeError.invalidTransition }
            if success {
                record.transitions.append(.sent)
                record.state = .unopened
            } else {
                self.sender[record.amount.currency, default: 0] += record.amount.units
                record.state = .failed
            }
        }
    }

    @discardableResult
    public func beginOpening(_ id: Int32, now: Date) throws -> DemoEnvelope {
        let record = try self.expireIfNeeded(id, now: now)
        guard record.state == .unopened else { throw EnvelopeError.invalidTransition }
        return try self.mutate(id) { record in
            guard record.state == .unopened else { throw EnvelopeError.invalidTransition }
            record.state = .opening
        }
    }

    @discardableResult
    public func completeOpening(_ id: Int32) throws -> DemoEnvelope {
        return try self.mutate(id) { record in
            guard record.state == .opening else { throw EnvelopeError.invalidTransition }
            self.recipient[record.amount.currency, default: 0] += record.amount.units
            record.state = .received
        }
    }

    @discardableResult
    public func cancel(_ id: Int32) throws -> DemoEnvelope {
        return try self.mutate(id) { record in
            guard record.state == .unopened else { throw EnvelopeError.invalidTransition }
            self.sender[record.amount.currency, default: 0] += record.amount.units
            record.state = .cancelled
        }
    }

    @discardableResult
    public func expireIfNeeded(_ id: Int32, now: Date) throws -> DemoEnvelope {
        return try self.mutate(id) { record in
            if record.state == .unopened && now >= record.expiresAt {
                self.sender[record.amount.currency, default: 0] += record.amount.units
                record.state = .expired
            }
        }
    }

    private func mutate(_ id: Int32, _ update: (inout DemoEnvelope) throws -> Void) throws -> DemoEnvelope {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let index = self.records.firstIndex(where: { $0.id == id }) else { throw EnvelopeError.missingEnvelope }
        // A local copy avoids overlapping exclusive access while updating ledger balances.
        var record = self.records[index]
        let previousState = record.state
        try update(&record)
        if record.state != previousState { record.transitions.append(record.state) }
        self.records[index] = record
        return record
    }
}
