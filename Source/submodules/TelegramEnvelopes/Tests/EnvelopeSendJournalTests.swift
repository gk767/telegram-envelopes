import Foundation
import XCTest
@testable import TelegramEnvelopes

final class EnvelopeSendJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnvelopeJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: self.directory)
    }

    private func journal(account: Int64 = 11, recipient: Int64 = 22) throws -> EnvelopeSendJournal {
        return try EnvelopeSendJournal(accountId: account, recipientId: recipient, directory: self.directory)
    }

    private func begin(_ journal: EnvelopeSendJournal) throws -> EnvelopePendingSend {
        return try journal.begin(amount: EnvelopeAmount(text: "15.000000001", currency: .ton), message: "For you")
    }

    private func envelope(_ pending: EnvelopePendingSend, id: UUID = UUID(), state: TonEnvelopeState = .sent) -> TonEnvelope {
        return TonEnvelope(id: id, senderId: pending.accountId, recipientId: pending.recipientId, state: state, amountUnits: pending.amountUnits, message: pending.message, createdAt: 100, expiresAt: 86500, currency: pending.currency)
    }

    func testLostCreateResponseKeepsExactIntentThroughEditAndReopen() throws {
        let first = try self.begin(self.journal())
        let reopened = try self.journal()
        let retry = try reopened.begin(amount: EnvelopeAmount(text: "30", currency: .ton), message: "Edited after timeout")
        XCTAssertEqual(retry, first)
        XCTAssertEqual(retry.amountText, "15.000000001")
        XCTAssertEqual(retry.stage, .creating)
        XCTAssertNil(retry.reference)
    }

    func testCreatedReferenceSurvivesRestartUntilQueueAcknowledgement() throws {
        let journal = try self.journal()
        let pending = try self.begin(journal)
        let response = self.envelope(pending)
        guard case let .readyToQueue(ready) = try journal.acceptCreated(response, submissionId: pending.submissionId) else {
            return XCTFail("A sent envelope must be delivered")
        }
        XCTAssertEqual(ready.reference, response.reference)
        XCTAssertEqual(ready.stage, .readyToQueue)
        let reopened = try self.journal()
        XCTAssertEqual(try reopened.pendingOperation(), ready)
        try reopened.confirmQueued(submissionId: pending.submissionId)
        XCTAssertNil(try reopened.pendingOperation())
        XCTAssertNotEqual(try self.begin(reopened).submissionId, pending.submissionId)
    }

    func testFailedCancellationRetriesRefundInsteadOfAnotherCreate() throws {
        let journal = try self.journal()
        let pending = try self.begin(journal)
        let response = self.envelope(pending)
        try journal.acceptCreated(response, submissionId: pending.submissionId)
        let refunding = try journal.beginRefund(submissionId: pending.submissionId)
        // The cancel request fails or its reply is lost. No journal transition.
        let reopened = try self.journal()
        XCTAssertEqual(try self.begin(reopened), refunding)
        XCTAssertEqual(refunding.stage, .refunding)
        XCTAssertEqual(refunding.reference, response.reference)
        XCTAssertThrowsError(try reopened.confirmQueued(submissionId: pending.submissionId))
        XCTAssertThrowsError(try reopened.acceptRefund(response, submissionId: pending.submissionId))
        XCTAssertEqual(try reopened.pendingOperation(), refunding)
        XCTAssertEqual(try reopened.acceptRefund(self.envelope(pending, id: response.id, state: .cancelled), submissionId: pending.submissionId), .refunded)
        XCTAssertNil(try reopened.pendingOperation())
    }

    func testLateCallbackCannotClearOrModifyNewerIntent() throws {
        let journal = try self.journal()
        let old = try self.begin(journal)
        try journal.acceptCreated(self.envelope(old), submissionId: old.submissionId)
        try journal.confirmQueued(submissionId: old.submissionId)
        let current = try self.begin(journal)
        XCTAssertThrowsError(try journal.confirmQueued(submissionId: old.submissionId))
        XCTAssertThrowsError(try journal.acceptCreated(self.envelope(old, state: .expired), submissionId: old.submissionId))
        XCTAssertThrowsError(try journal.rejectCreate(submissionId: old.submissionId, code: "insufficient_balance"))
        XCTAssertEqual(try journal.pendingOperation(), current)
    }

    func testRetryReconcilesExpiredCancelledAndAlreadyOpenedCreate() throws {
        for state in [TonEnvelopeState.expired, .cancelled, .opened] {
            let journal = try self.journal()
            let pending = try self.begin(journal)
            let result = try journal.acceptCreated(self.envelope(pending, state: state), submissionId: pending.submissionId)
            XCTAssertEqual(result, state == .opened ? .delivered : .refunded)
            XCTAssertNil(try journal.pendingOperation())
        }
    }

    func testQueuedStageReplayKeepsReferenceBindingAndReconcilesExpiry() throws {
        let journal = try self.journal()
        let pending = try self.begin(journal)
        let sent = self.envelope(pending)
        try journal.acceptCreated(sent, submissionId: pending.submissionId)
        let reopened = try self.journal()
        let ready = try XCTUnwrap(reopened.pendingOperation())
        XCTAssertEqual(ready.stage, .readyToQueue)
        XCTAssertThrowsError(try reopened.acceptCreated(self.envelope(pending, state: .expired), submissionId: pending.submissionId))
        XCTAssertEqual(try reopened.pendingOperation(), ready)
        XCTAssertEqual(try reopened.acceptCreated(sent, submissionId: pending.submissionId), .readyToQueue(ready))
        XCTAssertEqual(try reopened.acceptCreated(self.envelope(pending, id: sent.id, state: .expired), submissionId: pending.submissionId), .refunded)
        XCTAssertNil(try reopened.pendingOperation())
    }

    func testClaimWinningCancellationRaceIsDeliveredNotRetried() throws {
        let journal = try self.journal()
        let pending = try self.begin(journal)
        let sent = self.envelope(pending)
        try journal.acceptCreated(sent, submissionId: pending.submissionId)
        try journal.beginRefund(submissionId: pending.submissionId)
        XCTAssertEqual(try journal.acceptRefund(self.envelope(pending, id: sent.id, state: .opened), submissionId: pending.submissionId), .delivered)
        XCTAssertNil(try journal.pendingOperation())
    }

    func testUnknownRejectionsKeepReservationButKnownRejectionAllowsEditing() throws {
        let journal = try self.journal()
        let pending = try self.begin(journal)
        for code in ["internal", "unauthorized", "submission_conflict", "unavailable", ""] {
            XCTAssertFalse(try journal.rejectCreate(submissionId: pending.submissionId, code: code))
            XCTAssertEqual(try journal.pendingOperation(), pending)
        }
        XCTAssertTrue(try journal.rejectCreate(submissionId: pending.submissionId, code: "insufficient_balance"))
        XCTAssertNil(try journal.pendingOperation())
        let changed = try journal.begin(amount: EnvelopeAmount(text: "1", currency: .ton), message: "Smaller amount")
        XCTAssertNotEqual(changed.submissionId, pending.submissionId)
        XCTAssertEqual(changed.amountUnits, 1_000_000_000)
    }

    func testMismatchedResponseCannotResolveReservation() throws {
        let journal = try self.journal()
        let pending = try self.begin(journal)
        let mismatch = TonEnvelope(id: UUID(), senderId: 11, recipientId: 33, state: .cancelled, amountUnits: pending.amountUnits, message: pending.message, createdAt: 100, expiresAt: 86500)
        XCTAssertThrowsError(try journal.acceptCreated(mismatch, submissionId: pending.submissionId))
        XCTAssertEqual(try journal.pendingOperation(), pending)
        let sent = self.envelope(pending)
        try journal.acceptCreated(sent, submissionId: pending.submissionId)
        let refunding = try journal.beginRefund(submissionId: pending.submissionId)
        XCTAssertThrowsError(try journal.acceptRefund(self.envelope(pending, state: .cancelled), submissionId: pending.submissionId))
        XCTAssertEqual(try journal.pendingOperation(), refunding)
    }

    func testCorruptJournalFailsClosedWithoutOverwritingIt() throws {
        let journal = try self.journal()
        _ = try self.begin(journal)
        let file = self.directory.appendingPathComponent("11-22.json")
        let corrupted = Data("{truncated".utf8)
        try corrupted.write(to: file)
        XCTAssertThrowsError(try journal.pendingOperation())
        XCTAssertThrowsError(try self.begin(journal))
        XCTAssertThrowsError(try self.journal())
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }

    func testPendingOperationsAreIsolatedAndStoredPrivately() throws {
        let originalJournal = try self.journal()
        let original = try self.begin(originalJournal)
        XCTAssertNil(try self.journal(account: 11, recipient: 33).pendingOperation())
        XCTAssertNil(try self.journal(account: 22, recipient: 11).pendingOperation())
        try originalJournal.acceptCreated(self.envelope(original), submissionId: original.submissionId)
        let file = self.directory.appendingPathComponent("11-22.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let data = try Data(contentsOf: file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["openingEmoji", "accountId", "recipientId", "submissionId", "amountUnits", "currency", "message", "stage", "reference"]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: self.directory.path).contains(where: { $0.hasPrefix(".pending-") }))
    }

    func testCurrencyChangeCannotBypassUncertainCreate() throws {
        let journal = try self.journal()
        let pending = try journal.begin(amount: EnvelopeAmount(text: "15.000001", currency: .usdt), message: "USDT")
        XCTAssertEqual(pending.amountUnits, 15_000_001)
        XCTAssertEqual(pending.amountText, "15.000001")
        let reopened = try self.journal()
        let retry = try reopened.begin(amount: EnvelopeAmount(text: "15", currency: .ton), message: "Changed currency after timeout")
        XCTAssertEqual(retry, pending)
        XCTAssertEqual(retry.currency, .usdt)
        let response = self.envelope(pending)
        try reopened.acceptCreated(response, submissionId: pending.submissionId)
        XCTAssertEqual(try reopened.pendingOperation()?.reference?.currency, .usdt)
    }

    func testMismatchedCurrencyResponseCannotResolveReservation() throws {
        let journal = try self.journal()
        let pending = try journal.begin(amount: EnvelopeAmount(text: "15", currency: .usdt), message: "USDT")
        let wrongCurrency = TonEnvelope(id: UUID(), senderId: 11, recipientId: 22, state: .cancelled, amountUnits: pending.amountUnits, message: pending.message, createdAt: 100, expiresAt: 86500, currency: .ton)
        XCTAssertThrowsError(try journal.acceptCreated(wrongCurrency, submissionId: pending.submissionId))
        XCTAssertEqual(try journal.pendingOperation(), pending)
    }

    func testLegacyPendingRecordWithoutCurrencyRestoresTon() throws {
        let journal = try self.journal()
        let pending = try self.begin(journal)
        try journal.acceptCreated(self.envelope(pending), submissionId: pending.submissionId)
        let before = try XCTUnwrap(journal.pendingOperation())
        let file = self.directory.appendingPathComponent("11-22.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json.removeValue(forKey: "currency")
        var reference = try XCTUnwrap(json["reference"] as? [String: Any])
        reference.removeValue(forKey: "currency")
        json["reference"] = reference
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertEqual(try self.journal().pendingOperation(), before)
        XCTAssertEqual(try self.journal().pendingOperation()?.currency, .ton)
    }

    func testCurrencyLimitsUseTheirOwnPrecisionAndRejectUnsupportedCurrency() throws {
        let journal = try self.journal()
        XCTAssertThrowsError(try journal.begin(amount: EnvelopeAmount(text: "1", currency: .gram), message: ""))
        XCTAssertThrowsError(try journal.begin(amount: EnvelopeAmount(text: "1000000.000001", currency: .usdt), message: ""))
        XCTAssertThrowsError(try journal.begin(amount: EnvelopeAmount(text: "1000000.000000001", currency: .ton), message: ""))
        XCTAssertNil(try journal.pendingOperation())
        let max = try journal.begin(amount: EnvelopeAmount(text: "1000000", currency: .usdt), message: "")
        XCTAssertEqual(max.amountUnits, 1_000_000_000_000)
        XCTAssertEqual(try self.journal().pendingOperation(), max)
    }

    func testUsdtReferenceCannotBePersistedAsLegacyTonProtocol() throws {
        let journal = try self.journal()
        let pending = try journal.begin(amount: EnvelopeAmount(text: "15", currency: .usdt), message: "")
        try journal.acceptCreated(self.envelope(pending), submissionId: pending.submissionId)
        let file = self.directory.appendingPathComponent("11-22.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var reference = try XCTUnwrap(json["reference"] as? [String: Any])
        XCTAssertEqual(reference["version"] as? Int, 2)
        reference["version"] = 1
        json["reference"] = reference
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertThrowsError(try journal.pendingOperation())
        XCTAssertThrowsError(try self.begin(journal))
    }
}
