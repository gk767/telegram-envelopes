import Foundation
import XCTest
@testable import TelegramEnvelopes

final class TonEnvelopeTests: XCTestCase {
    func testSenderPlaysPendingOpeningOnceAcrossReopenAndRefresh() throws {
        let suite = "OpeningTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sent = EnvelopeMessageReference(id: UUID(), senderId: 11, recipientId: 22)
        let tracker = EnvelopeSenderOpenings(defaults: defaults)
        XCTAssertFalse(tracker.observe(sent, state: .opened, visible: true))
        XCTAssertFalse(tracker.observe(sent, state: .sent, visible: true))
        XCTAssertFalse(tracker.observe(sent, state: .opened, visible: false))
        let reopened = EnvelopeSenderOpenings(defaults: defaults)
        XCTAssertTrue(reopened.observe(sent, state: .opened, visible: true))
        XCTAssertFalse(tracker.observe(sent, state: .sent, visible: true))
        XCTAssertFalse(tracker.observe(sent, state: .opened, visible: true))
        let anotherAccount = EnvelopeMessageReference(id: sent.id, senderId: 33, recipientId: 22)
        XCTAssertFalse(tracker.observe(anotherAccount, state: .opened, visible: true))
    }
    func testOpeningEmojiSurviveTransportAndAreBounded() throws {
        var ref = EnvelopeMessageReference(id: UUID(), senderId: 1, recipientId: 2)
        ref.openingEmoji = ["💙", "invalid", "✨", "💙", "🔥", "💎"]
        let received = try XCTUnwrap(EnvelopeMessageReference.parse(ref.messageText, authorId: 1, accountId: 2, chatPeerId: 1, isForwarded: false))
        XCTAssertEqual(received.openingEmoji, ["💙", "✨", "🔥"])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ref)) as? [String: Any])
        legacy.removeValue(forKey: "openingEmoji")
        XCTAssertEqual(try JSONDecoder().decode(EnvelopeMessageReference.self, from: JSONSerialization.data(withJSONObject: legacy)).openingEmoji, [])
    }

    func testEditableAmountAcceptsOnlySurroundingWhitespace() throws {
        for text in ["7 ", " 7", "\n7\t", "\u{00a0}7\u{00a0}"] {
            XCTAssertEqual(try EnvelopeAmount(userInput: text, currency: .ton).units, 7_000_000_000)
        }
        for text in ["7 0", "7\n0", " "] {
            XCTAssertThrowsError(try EnvelopeAmount(userInput: text, currency: .ton))
        }
    }

    func testTonNanounitsRemainExact() throws {
        XCTAssertEqual(try EnvelopeAmount(text: "15", currency: .ton).units, 15_000_000_000)
        XCTAssertEqual(try EnvelopeAmount(text: "0,000000001", currency: .ton).units, 1)
        XCTAssertEqual(TonEnvelope.format(15_000_000_001), "15.000000001")
        XCTAssertEqual(TonEnvelope.format(0), "0")
        XCTAssertThrowsError(try EnvelopeAmount(text: "0.0000000001", currency: .ton))
        XCTAssertThrowsError(try EnvelopeAmount(text: "999999999999.9", currency: .ton))
    }

    func testReferenceRoundTripAndParticipantBinding() {
        let reference = EnvelopeMessageReference(id: UUID(), senderId: 123, recipientId: 456)
        let text = reference.messageText
        XCTAssertEqual(EnvelopeMessageReference.parse(text, authorId: 123, accountId: 456, chatPeerId: 123, isForwarded: false), reference)
        XCTAssertEqual(EnvelopeMessageReference.parse(text, authorId: 123, accountId: 123, chatPeerId: 456, isForwarded: false), reference)
        XCTAssertNil(EnvelopeMessageReference.parse(text, authorId: 456, accountId: 456, chatPeerId: 123, isForwarded: false))
        XCTAssertNil(EnvelopeMessageReference.parse(text, authorId: 123, accountId: 789, chatPeerId: 123, isForwarded: false))
        XCTAssertNil(EnvelopeMessageReference.parse(text, authorId: 123, accountId: 456, chatPeerId: 789, isForwarded: false))
        XCTAssertNil(EnvelopeMessageReference.parse(text, authorId: 123, accountId: 456, chatPeerId: 123, isForwarded: true))
        XCTAssertNil(EnvelopeMessageReference.parse(text + "junk", authorId: 123, accountId: 456, chatPeerId: 123, isForwarded: false))
    }

    func testAmountIsAbsentFromTransportAndClosedRecipientResponse() throws {
        let data = Data("""
        {"id":"7CFDBB37-D493-42FD-A19D-92957C49E022","senderId":123,"recipientId":456,"state":"sent","amountUnits":null,"message":"Hello","createdAt":100,"expiresAt":86500}
        """.utf8)
        let envelope = try JSONDecoder().decode(TonEnvelope.self, from: data)
        XCTAssertNil(envelope.amountText)
        let prefix = "telegram-envelope-v1:"
        let payload = try XCTUnwrap(envelope.reference.messageText.components(separatedBy: prefix).last)
        let decoded = try XCTUnwrap(Data(base64Encoded: payload))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["openingEmoji", "version", "id", "senderId", "recipientId", "currency"]))
        XCTAssertEqual(json["currency"] as? String, "TON")
    }

    func testUSDTPrecisionAndReferenceBinding() throws {
        XCTAssertEqual(try EnvelopeAmount(text: "15.000001", currency: .usdt).units, 15_000_001)
        XCTAssertEqual(TonEnvelope.format(15_000_001, currency: .usdt), "15.000001")
        XCTAssertEqual(TonEnvelope.format(0, currency: .usdt), "0")
        XCTAssertThrowsError(try EnvelopeAmount(text: "0.0000001", currency: .usdt))
        let reference = EnvelopeMessageReference(id: UUID(), senderId: 123, recipientId: 456, currency: .usdt)
        XCTAssertEqual(reference.version, 2)
        XCTAssertTrue(reference.messageText.contains("telegram-envelope-v2:"))
        XCTAssertEqual(EnvelopeMessageReference.parse(reference.messageText, authorId: 123, accountId: 456, chatPeerId: 123, isForwarded: false), reference)
        XCTAssertNotEqual(reference, EnvelopeMessageReference(id: reference.id, senderId: 123, recipientId: 456))
        let gram = EnvelopeMessageReference(id: reference.id, senderId: 123, recipientId: 456, currency: .gram)
        XCTAssertNil(EnvelopeMessageReference.parse(gram.messageText, authorId: 123, accountId: 456, chatPeerId: 123, isForwarded: false))
        let opened = TonEnvelope(id: reference.id, senderId: 123, recipientId: 456, state: .opened, amountUnits: 15_000_001, message: "", createdAt: 100, expiresAt: 86500, currency: .usdt)
        XCTAssertEqual(opened.reference, reference)
        XCTAssertEqual(opened.amountText, "15.000001 USDT")
    }

    func testLegacyPayloadAndWalletDecodeAsTON() throws {
        let payload = Data("{\"version\":1,\"id\":\"7CFDBB37-D493-42FD-A19D-92957C49E022\",\"senderId\":123,\"recipientId\":456}".utf8)
        let legacy = "✉️ TON Envelope · demo\ntelegram-envelope-v1:" + payload.base64EncodedString()
        let reference = try XCTUnwrap(EnvelopeMessageReference.parse(legacy, authorId: 123, accountId: 456, chatPeerId: 123, isForwarded: false))
        XCTAssertEqual(reference.currency, .ton)
        let wallet = try JSONDecoder().decode(EnvelopeWallet.self, from: Data("{\"balanceUnits\":15000000000}".utf8))
        XCTAssertEqual(wallet.currency, .ton)
        XCTAssertEqual(wallet.displayText, "15 Gram")
        let usdt = try JSONDecoder().decode(EnvelopeWallet.self, from: Data("{\"balanceUnits\":15000001,\"currency\":\"USDT\"}".utf8))
        XCTAssertEqual(usdt.displayText, "15.000001 USDT")
        // Old clients ignore extra JSON keys in version1. A USDT reference must
        // use version2 so it can never be mistaken for TON by that parser.
        let invalidV1 = Data("{\"version\":1,\"id\":\"7CFDBB37-D493-42FD-A19D-92957C49E022\",\"senderId\":123,\"recipientId\":456,\"currency\":\"USDT\"}".utf8)
        let text = "✉️ TON Envelope · demo\ntelegram-envelope-v1:" + invalidV1.base64EncodedString()
        XCTAssertNil(EnvelopeMessageReference.parse(text, authorId: 123, accountId: 456, chatPeerId: 123, isForwarded: false))
    }
}
