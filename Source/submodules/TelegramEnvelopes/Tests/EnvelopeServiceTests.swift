import Foundation
import XCTest
@testable import TelegramEnvelopes

private final class EnvelopeResponseProtocol: URLProtocol {
    static var response: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    override func startLoading() {
        do {
            let data = try Self.response!(self.request)
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class EnvelopeServiceTests: XCTestCase {
    private func service() throws -> EnvelopeService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EnvelopeResponseProtocol.self]
        return try EnvelopeService(accountId: 11, configuration: EnvelopeServiceConfiguration(serverURL: URL(string: "https://demo.invalid")!, accounts: ["11": "test-token"]), session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        EnvelopeResponseProtocol.response = nil
        super.tearDown()
    }

    func testClaimDistinguishesFirstOpenFromReplayAndLegacyReceipt() throws {
        let service = try self.service()
        let reference = EnvelopeMessageReference(id: UUID(), senderId: 22, recipientId: 11)
        for flag in [true, false, nil] as [Bool?] {
            EnvelopeResponseProtocol.response = { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertTrue(request.url?.path.hasSuffix("/claim") == true)
                var receipt: [String: Any] = ["id": reference.id.uuidString, "senderId": 22, "recipientId": 11,
                    "state": "opened", "amountUnits": 15_000_000_000, "message": "", "createdAt": 100, "expiresAt": 86500]
                if let flag { receipt["openedNow"] = flag }
                return try JSONSerialization.data(withJSONObject: receipt)
            }
            let finished = expectation(description: "claim receipt")
            service.claim(reference) { result in
                switch result {
                case let .success(receipt): XCTAssertEqual(receipt.openedNow, flag)
                case let .failure(error): XCTFail(String(describing: error))
                }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 3)
        }
    }

    func testUSDTWalletQueryAndResponseAreCurrencyBound() throws {
        EnvelopeResponseProtocol.response = { request in
            XCTAssertEqual(request.url?.path, "/v1/wallet")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "currency", value: "USDT")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return Data("{\"balanceUnits\":15000001,\"currency\":\"USDT\"}".utf8)
        }
        let service = try self.service()
        let finished = expectation(description: "wallet")
        service.wallet(currency: .usdt) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get().displayText, "15.000001 USDT")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
    }

    func testUSDTWalletCannotInterpretLegacyTONResponseAsUSDT() throws {
        EnvelopeResponseProtocol.response = { _ in Data("{\"balanceUnits\":15000000000}".utf8) }
        let service = try self.service()
        let finished = expectation(description: "currency mismatch")
        service.wallet(currency: .usdt) { result in
            guard case .failure(EnvelopeServiceError.invalidResponse) = result else {
                XCTFail("An untagged legacy TON balance must not become USDT"); finished.fulfill(); return
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
    }

    func testIdempotentCreateAcceptsMatchingTerminalReceipts() throws {
        let amount = try EnvelopeAmount(text: "12.5", currency: .usdt)
        let submissionId = UUID()
        let service = try self.service()
        for state in [TonEnvelopeState.expired, .cancelled, .opened] {
            EnvelopeResponseProtocol.response = { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/v1/envelopes")
                // URLSession may materialize HTTP bodies as streams for URLProtocol.
                var data = request.httpBody
                if data == nil, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var body = Data()
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while true {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                    data = body
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
                XCTAssertEqual(body["currency"] as? String, "USDT")
                XCTAssertEqual(body["amountUnits"] as? Int64, 12_500_000)
                XCTAssertEqual(body["submissionId"] as? String, submissionId.uuidString)
                return try JSONEncoder().encode(TonEnvelope(id: UUID(), senderId: 11, recipientId: 22, state: state, amountUnits: amount.units, message: "Note", createdAt: 100, expiresAt: 86500, currency: .usdt))
            }
            let finished = expectation(description: state.rawValue)
            service.create(recipientId: 22, amount: amount, message: "Note", submissionId: submissionId) { result in
                XCTAssertEqual(try? result.get().state, state)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 3)
        }
    }

    func testCreateRejectsReceiptForAnotherCurrencyOrPayload() throws {
        let service = try self.service()
        for (currency, message) in [(EnvelopeCurrency.ton, "Note"), (.usdt, "Changed")] {
            EnvelopeResponseProtocol.response = { _ in
                try JSONEncoder().encode(TonEnvelope(id: UUID(), senderId: 11, recipientId: 22, state: .sent, amountUnits: 15_000_000, message: message, createdAt: 100, expiresAt: 86500, currency: currency))
            }
            let finished = expectation(description: "mismatched receipt")
            service.create(recipientId: 22, amount: try EnvelopeAmount(text: "15", currency: .usdt), message: "Note", submissionId: UUID()) { result in
                guard case .failure(EnvelopeServiceError.invalidResponse) = result else {
                    XCTFail("A mismatched receipt must not be queued"); finished.fulfill(); return
                }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 3)
        }
    }
}
