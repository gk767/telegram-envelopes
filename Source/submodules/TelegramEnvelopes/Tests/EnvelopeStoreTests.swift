import Foundation
import XCTest
@testable import TelegramEnvelopes

final class EnvelopeStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @discardableResult
    private func sent(_ store: EnvelopeDemoStore, _ text: String = "12.50", currency: EnvelopeCurrency = .usdt) throws -> DemoEnvelope {
        let record = try store.beginSend(submissionId: UUID(), amount: EnvelopeAmount(text: text, currency: currency), style: .classic, message: "Hello", now: self.now)
        return try store.completeSend(record.id, success: true)
    }

    func testDecimalAmountsAreExactAndCanonical() throws {
        let value = try EnvelopeAmount(text: "0001,230001", currency: .usdt)
        XCTAssertEqual(value.units, 1_230_001)
        XCTAssertEqual(value.text, "1.230001")
        XCTAssertEqual(try EnvelopeAmount(text: "0.000001", currency: .usdt).units, 1)
        XCTAssertEqual(try EnvelopeAmount(text: "0.0001", currency: .gram).units, 1)
        XCTAssertEqual(try EnvelopeAmount(text: "2.", currency: .usdt).displayText, "2 USDT")
    }

    func testRejectsInvalidSyntaxPrecisionAndOverflow() {
        for text in ["", "0", "0.000000", "-1", "+1", " 1", "1 ", "1e2", "NaN", "inf", ".5", "1..2", "1,2.3", "1_000", "1 000", "١٢", "１", "0.0000001", "99999999999999999999999"] {
            XCTAssertThrowsError(try EnvelopeAmount(text: text, currency: .usdt), text)
        }
        XCTAssertThrowsError(try EnvelopeAmount(text: "1.00001", currency: .gram))
    }

    func testLargeAmountsDoNotWrap() throws {
        let amount = try EnvelopeAmount(text: "999999999999.999999", currency: .usdt)
        XCTAssertEqual(amount.units, 999_999_999_999_999_999)
        XCTAssertEqual(amount.text, "999999999999.999999")
    }

    func testInsufficientBalanceDoesNotMutateLedger() throws {
        let store = EnvelopeDemoStore()
        XCTAssertThrowsError(try self.sent(store, "1000.000001")) { XCTAssertEqual($0 as? EnvelopeError, .insufficientBalance) }
        XCTAssertEqual(store.balance(.usdt), "1000")
        XCTAssertTrue(store.envelopes.isEmpty)
    }

    func testSendReservesOnceAndRecordsTransitions() throws {
        let store = EnvelopeDemoStore()
        let id = UUID()
        let amount = try EnvelopeAmount(text: "1.23", currency: .usdt)
        let first = try store.beginSend(submissionId: id, amount: amount, style: .midnight, message: "", now: self.now)
        let duplicate = try store.beginSend(submissionId: id, amount: amount, style: .classic, message: "different", now: self.now)
        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(store.balance(.usdt), "998.77")
        XCTAssertEqual(store.balance(.usdt, recipient: true), "0")
        let result = try store.completeSend(first.id, success: true)
        XCTAssertEqual(result.transitions, [.draft, .ready, .sending, .sent, .unopened])
        XCTAssertEqual(try store.beginSend(submissionId: id, amount: amount, style: .classic, message: "", now: self.now).id, first.id)
        XCTAssertThrowsError(try store.completeSend(first.id, success: true))
    }

    func testOpeningCreditsOnceAndKeepsCurrenciesSeparate() throws {
        let store = EnvelopeDemoStore()
        let record = try self.sent(store, "0.1234", currency: .gram)
        XCTAssertEqual(store.balance(.gram), "2499.8766")
        XCTAssertEqual(try store.beginOpening(record.id, now: self.now).state, .opening)
        XCTAssertEqual(store.balance(.gram, recipient: true), "0")
        XCTAssertEqual(try store.completeOpening(record.id).state, .received)
        XCTAssertEqual(store.balance(.gram, recipient: true), "0.1234")
        XCTAssertEqual(store.balance(.usdt), "1000")
        XCTAssertThrowsError(try store.completeOpening(record.id))
        XCTAssertThrowsError(try store.beginOpening(record.id, now: self.now))
        XCTAssertThrowsError(try store.cancel(record.id))
        XCTAssertEqual(store.balance(.gram, recipient: true), "0.1234")
    }

    func testCancelRefundsOnce() throws {
        let store = EnvelopeDemoStore()
        let record = try self.sent(store)
        XCTAssertEqual(try store.cancel(record.id).state, .cancelled)
        XCTAssertEqual(store.balance(.usdt), "1000")
        XCTAssertThrowsError(try store.cancel(record.id))
        XCTAssertThrowsError(try store.beginOpening(record.id, now: self.now))
        XCTAssertEqual(try store.expireIfNeeded(record.id, now: record.expiresAt).state, .cancelled)
        XCTAssertEqual(store.balance(.usdt), "1000")
    }

    func testExpirationBoundaryRefundsAndPreventsClaim() throws {
        let store = EnvelopeDemoStore()
        let record = try self.sent(store)
        XCTAssertEqual(try store.expireIfNeeded(record.id, now: record.expiresAt.addingTimeInterval(-0.001)).state, .unopened)
        XCTAssertThrowsError(try store.beginOpening(record.id, now: record.expiresAt))
        XCTAssertEqual(store.envelopes.first?.state, .expired)
        XCTAssertEqual(store.balance(.usdt), "1000")
        XCTAssertEqual(try store.expireIfNeeded(record.id, now: .distantFuture).state, .expired)
        XCTAssertEqual(store.balance(.usdt, recipient: true), "0")
    }

    func testInterruptedOpeningCanSettleAfterExpirationWithoutRefund() throws {
        let store = EnvelopeDemoStore()
        let record = try self.sent(store)
        try store.beginOpening(record.id, now: self.now)
        XCTAssertEqual(try store.expireIfNeeded(record.id, now: .distantFuture).state, .opening)
        XCTAssertThrowsError(try store.cancel(record.id))
        try store.completeOpening(record.id)
        XCTAssertEqual(store.balance(.usdt), "987.5")
        XCTAssertEqual(store.balance(.usdt, recipient: true), "12.5")
    }

    func testFailedSendRefundsAndCannotBeClaimed() throws {
        let store = EnvelopeDemoStore()
        let record = try store.beginSend(submissionId: UUID(), amount: EnvelopeAmount(text: "1000", currency: .usdt), style: .celebration, message: "", now: self.now)
        XCTAssertEqual(store.balance(.usdt), "0")
        XCTAssertThrowsError(try store.beginOpening(record.id, now: self.now))
        XCTAssertEqual(try store.completeSend(record.id, success: false).state, .failed)
        XCTAssertEqual(store.balance(.usdt), "1000")
        XCTAssertThrowsError(try store.completeSend(record.id, success: false))
        XCTAssertThrowsError(try store.beginOpening(record.id, now: self.now))
    }

    func testMessageLimitUsesCharactersAndDoesNotDebitOnFailure() throws {
        let store = EnvelopeDemoStore()
        let amount = try EnvelopeAmount(text: "1", currency: .usdt)
        XCTAssertThrowsError(try store.beginSend(submissionId: UUID(), amount: amount, style: .classic, message: String(repeating: "🧑‍🚀", count: 201), now: self.now))
        XCTAssertEqual(store.balance(.usdt), "1000")
        XCTAssertTrue(store.envelopes.isEmpty)
        XCTAssertNoThrow(try store.beginSend(submissionId: UUID(), amount: amount, style: .classic, message: String(repeating: "🧑‍🚀", count: 200), now: self.now))
    }

    func testLedgerIsBounded() throws {
        let store = EnvelopeDemoStore()
        for _ in 0 ..< EnvelopeDemoStore.capacity { _ = try self.sent(store, "0.000001") }
        XCTAssertThrowsError(try self.sent(store, "0.000001")) { XCTAssertEqual($0 as? EnvelopeError, .limitReached) }
        XCTAssertEqual(store.balance(.usdt), "999.9999")
    }

    func testUnknownIdentifiersDoNotChangeBalances() {
        let store = EnvelopeDemoStore()
        XCTAssertThrowsError(try store.completeSend(9, success: false))
        XCTAssertThrowsError(try store.cancel(9))
        XCTAssertThrowsError(try store.completeOpening(9))
        XCTAssertEqual(store.balance(.usdt), "1000")
    }

    func testReadOnlyValidationDoesNotReserveFunds() throws {
        let store = EnvelopeDemoStore()
        let amount = try EnvelopeAmount(text: "1000", currency: .usdt)
        try store.validate(amount: amount, message: "")
        XCTAssertTrue(store.envelopes.isEmpty)
        XCTAssertEqual(store.balance(.usdt), "1000")
        XCTAssertThrowsError(try store.validate(amount: EnvelopeAmount(text: "1001", currency: .usdt), message: ""))
        _ = try self.sent(store, "1000")
        XCTAssertThrowsError(try store.validate(amount: amount, message: ""))
        XCTAssertEqual(store.balance(.usdt), "0")
    }

    func testConcurrentDuplicateSendOnlyReservesOnce() throws {
        let store = EnvelopeDemoStore()
        let key = UUID()
        let amount = try EnvelopeAmount(text: "0.000001", currency: .usdt)
        let now = self.now
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            _ = try? store.beginSend(submissionId: key, amount: amount, style: .classic, message: "", now: now)
        }
        XCTAssertEqual(store.envelopes.count, 1)
        XCTAssertEqual(store.balance(.usdt), "999.999999")
    }

    func testConcurrentReceiveCannotDuplicateCredit() throws {
        let store = EnvelopeDemoStore()
        let record = try self.sent(store)
        let now = self.now
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            _ = try? store.beginOpening(record.id, now: now)
            _ = try? store.completeOpening(record.id)
        }
        XCTAssertEqual(store.envelopes.first?.state, .received)
        XCTAssertEqual(store.balance(.usdt, recipient: true), "12.5")
        XCTAssertEqual(store.balance(.usdt), "987.5")
    }

    func testCancelRacingClaimConservesValue() throws {
        for _ in 0 ..< 50 {
            let store = EnvelopeDemoStore()
            let record = try self.sent(store, "1000")
            let now = self.now
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { _ = try? store.cancel(record.id) }
                else {
                    _ = try? store.beginOpening(record.id, now: now)
                    _ = try? store.completeOpening(record.id)
                }
            }
            let state = store.envelopes.first?.state
            XCTAssertTrue(state == .cancelled || state == .received)
            XCTAssertEqual(store.balance(.usdt), state == .cancelled ? "1000" : "0")
            XCTAssertEqual(store.balance(.usdt, recipient: true), state == .received ? "1000" : "0")
        }
    }
}
