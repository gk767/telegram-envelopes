import Foundation

public enum EnvelopePendingSendStage: String, Codable {
    case creating, readyToQueue, refunding
}

/// A durable create intent, not a wallet credential. The payload and idempotency
/// key stay together until Telegram accepts the message or the service resolves it.
public struct EnvelopePendingSend: Codable, Equatable {
    public let accountId: Int64
    public let recipientId: Int64
    public let submissionId: UUID
    public let amountUnits: Int64
    public let currency: EnvelopeCurrency
    public let message: String
    public let openingEmoji: [String]
    public fileprivate(set) var stage: EnvelopePendingSendStage
    public fileprivate(set) var reference: EnvelopeMessageReference?

    public var amountText: String { TonEnvelope.format(self.amountUnits, currency: self.currency) }

    private enum CodingKeys: String, CodingKey {
        case accountId, recipientId, submissionId, amountUnits, currency, message, openingEmoji, stage, reference
    }
}

extension EnvelopePendingSend {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountId = try container.decode(Int64.self, forKey: .accountId)
        self.recipientId = try container.decode(Int64.self, forKey: .recipientId)
        self.submissionId = try container.decode(UUID.self, forKey: .submissionId)
        self.amountUnits = try container.decode(Int64.self, forKey: .amountUnits)
        // Pending operations written before the currency selector always used TON.
        self.currency = try container.decodeIfPresent(EnvelopeCurrency.self, forKey: .currency) ?? .ton
        self.openingEmoji = EnvelopeMessageReference.selection(try container.decodeIfPresent([String].self, forKey: .openingEmoji) ?? [])
        self.message = try container.decode(String.self, forKey: .message)
        self.stage = try container.decode(EnvelopePendingSendStage.self, forKey: .stage)
        self.reference = try container.decodeIfPresent(EnvelopeMessageReference.self, forKey: .reference)
    }
}

public enum EnvelopeSendResolution: Equatable {
    case readyToQueue(EnvelopePendingSend)
    case refunded
    case delivered
}

public enum EnvelopeSendJournalError: Error {
    case invalidIntent, invalidRecord, missingOperation, staleSubmission, wrongStage, mismatchedResponse
}

/// Call from one serialized queue (the composer uses the main queue). Each change
/// reloads the file, so an old callback cannot erase a newer submission. Writes
/// happen before side effects; an I/O error must prevent creating/queuing/cancelling.
public final class EnvelopeSendJournal {
    private let accountId: Int64
    private let recipientId: Int64
    private let fileURL: URL

    public init(accountId: Int64, recipientId: Int64, directory: URL? = nil) throws {
        guard accountId > 0, recipientId > 0, accountId != recipientId else {
            throw EnvelopeSendJournalError.invalidIntent
        }
        let root: URL
        if let directory {
            root = directory
        } else {
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("TelegramEnvelopePending", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.accountId = accountId
        self.recipientId = recipientId
        self.fileURL = root.appendingPathComponent("\(accountId)-\(recipientId).json")
        _ = try self.pendingOperation()
    }

    /// Missing means no operation; unreadable or malformed is an error, never an
    /// empty journal. Otherwise a damaged record could cause a second reservation.
    public func pendingOperation() throws -> EnvelopePendingSend? {
        let data: Data
        do {
            data = try Data(contentsOf: self.fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        guard data.count <= 8192,
              let pending = try? JSONDecoder().decode(EnvelopePendingSend.self, from: data),
              pending.accountId == self.accountId, pending.recipientId == self.recipientId,
              pending.currency == .ton || pending.currency == .usdt,
              pending.amountUnits > 0, pending.amountUnits <= 1_000_000 * pending.currency.demoScale,
              pending.message.unicodeScalars.count <= 200 else {
            throw EnvelopeSendJournalError.invalidRecord
        }
        switch pending.stage {
        case .creating:
            guard pending.reference == nil else { throw EnvelopeSendJournalError.invalidRecord }
        case .readyToQueue, .refunding:
            guard let reference = pending.reference,
                  (reference.version == 1 && reference.currency == .ton) || reference.version == 2,
                  reference.senderId == self.accountId, reference.recipientId == self.recipientId,
                  reference.currency == pending.currency else {
                throw EnvelopeSendJournalError.invalidRecord
            }
        }
        return pending
    }

    /// If a previous result is uncertain, return its original payload even if the
    /// form was edited or reopened. The caller restores the fields and retries it.
    @discardableResult
    public func begin(amount: EnvelopeAmount, message: String, openingEmoji: [String] = []) throws -> EnvelopePendingSend {
        if let pending = try self.pendingOperation() { return pending }
        guard amount.currency == .ton || amount.currency == .usdt,
              amount.units > 0, amount.units <= 1_000_000 * amount.currency.demoScale,
              message.unicodeScalars.count <= 200 else {
            throw EnvelopeSendJournalError.invalidIntent
        }
        let pending = EnvelopePendingSend(accountId: self.accountId, recipientId: self.recipientId, submissionId: UUID(), amountUnits: amount.units, currency: amount.currency, message: message, openingEmoji: EnvelopeMessageReference.selection(openingEmoji), stage: .creating, reference: nil)
        try self.write(pending)
        return pending
    }

    /// A retry can resolve to an expired/refunded or already-opened envelope. Those
    /// terminal responses resolve the journal; they must not enqueue another card.
    @discardableResult
    public func acceptCreated(_ envelope: TonEnvelope, submissionId: UUID) throws -> EnvelopeSendResolution {
        var pending = try self.operation(submissionId)
        guard pending.stage == .creating || pending.stage == .readyToQueue else { throw EnvelopeSendJournalError.wrongStage }
        try self.validate(envelope, against: pending)
        switch envelope.state {
        case .cancelled, .expired:
            try self.clear()
            return .refunded
        case .opened:
            try self.clear()
            return .delivered
        case .sent:
            pending.reference = envelope.reference
            pending.stage = .readyToQueue
            try self.write(pending)
            return .readyToQueue(pending)
        }
    }

    /// Only these ledger responses guarantee that this key has no reservation.
    /// Transport, auth, malformed-response and submission-conflict errors remain
    /// uncertain and must keep the original key. The bool says whether it cleared.
    @discardableResult
    public func rejectCreate(submissionId: UUID, code: String) throws -> Bool {
        let pending = try self.operation(submissionId)
        guard pending.stage == .creating else { throw EnvelopeSendJournalError.wrongStage }
        guard ["invalid_recipient", "invalid_amount", "invalid_currency", "message_too_long", "invalid_submission", "insufficient_balance"].contains(code) else { return false }
        try self.clear()
        return true
    }

    /// Call only after a successful enqueueMessages result, never just after HTTP
    /// create. A crash before this acknowledgement can leave a retryable reference.
    public func confirmQueued(submissionId: UUID) throws {
        let pending = try self.operation(submissionId)
        guard pending.stage == .readyToQueue else { throw EnvelopeSendJournalError.wrongStage }
        try self.clear()
    }

    /// Persist the refund decision before sending cancel. Reopening then retries
    /// cancellation, not create or delivery of an envelope that may be cancelled.
    @discardableResult
    public func beginRefund(submissionId: UUID) throws -> EnvelopePendingSend {
        var pending = try self.operation(submissionId)
        guard pending.stage == .readyToQueue || pending.stage == .refunding else { throw EnvelopeSendJournalError.wrongStage }
        pending.stage = .refunding
        try self.write(pending)
        return pending
    }

    /// If claim won the race, the server's opened receipt also resolves the intent.
    /// A sent response or any failure leaves the refund pending and retryable.
    @discardableResult
    public func acceptRefund(_ envelope: TonEnvelope, submissionId: UUID) throws -> EnvelopeSendResolution {
        let pending = try self.operation(submissionId)
        guard pending.stage == .refunding else { throw EnvelopeSendJournalError.wrongStage }
        try self.validate(envelope, against: pending)
        switch envelope.state {
        case .cancelled, .expired:
            try self.clear()
            return .refunded
        case .opened:
            try self.clear()
            return .delivered
        case .sent:
            throw EnvelopeSendJournalError.mismatchedResponse
        }
    }

    private func operation(_ submissionId: UUID) throws -> EnvelopePendingSend {
        guard let pending = try self.pendingOperation() else { throw EnvelopeSendJournalError.missingOperation }
        guard pending.submissionId == submissionId else { throw EnvelopeSendJournalError.staleSubmission }
        return pending
    }

    private func validate(_ envelope: TonEnvelope, against pending: EnvelopePendingSend) throws {
        guard envelope.senderId == pending.accountId, envelope.recipientId == pending.recipientId,
              envelope.amountUnits == pending.amountUnits, envelope.currency == pending.currency,
              envelope.message == pending.message,
              pending.reference == nil || pending.reference == envelope.reference else {
            throw EnvelopeSendJournalError.mismatchedResponse
        }
    }

    private func write(_ pending: EnvelopePendingSend) throws {
        let data = try JSONEncoder().encode(pending)
        // Set private permissions before writing, including the atomic temporary
        // file, instead of briefly publishing a default-permission JSON file.
        let temporary = self.fileURL.deletingLastPathComponent().appendingPathComponent(".pending-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            _ = try FileManager.default.replaceItemAt(self.fileURL, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporary, to: self.fileURL)
        }
    }

    private func clear() throws {
        try FileManager.default.removeItem(at: self.fileURL)
    }
}
