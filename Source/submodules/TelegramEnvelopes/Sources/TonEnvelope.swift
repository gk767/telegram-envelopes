import Foundation

/// The transport contains no amount, wallet key, endpoint or claim capability.
/// The configured service remains the authority for both participants and state.
public struct EnvelopeMessageReference: Codable, Equatable {
    public let version: Int
    public let id: UUID
    public let senderId: Int64
    public let recipientId: Int64
    public let currency: EnvelopeCurrency

    public static let emojiChoices = ["✨", "💙", "💎", "⭐️", "🎉", "❤️", "🔥", "🦋"]
    public var openingEmoji: [String]
    public static func selection(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where emojiChoices.contains(value) && !result.contains(value) {
            result.append(value)
            if result.count == 3 { break }
        }
        return result
    }

    public init(id: UUID, senderId: Int64, recipientId: Int64, currency: EnvelopeCurrency = .ton) {
        self.openingEmoji = []
        self.version = currency == .usdt ? 2 : 1
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey { case version, id, senderId, recipientId, currency, openingEmoji }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.openingEmoji = Self.selection(try values.decodeIfPresent([String].self, forKey: .openingEmoji) ?? [])
        self.version = try values.decode(Int.self, forKey: .version)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.senderId = try values.decode(Int64.self, forKey: .senderId)
        self.recipientId = try values.decode(Int64.self, forKey: .recipientId)
        self.currency = try values.decodeIfPresent(EnvelopeCurrency.self, forKey: .currency) ?? .ton
    }

    private static let prefix = "✉️ Envelope · demo\ntelegram-envelope-v1:"
    private static let legacyPrefix = "✉️ TON Envelope · demo\ntelegram-envelope-v1:"
    private static let prefixV2 = "✉️ Envelope · demo\ntelegram-envelope-v2:"

    public var messageText: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return (self.version == 2 ? Self.prefixV2 : Self.prefix) + data.base64EncodedString()
    }

    public static func parse(_ text: String, authorId: Int64?, accountId: Int64, chatPeerId: Int64, isForwarded: Bool) -> Self? {
        guard !isForwarded, text.utf8.count < 1024,
              let prefix = [Self.prefix, Self.legacyPrefix, Self.prefixV2].first(where: { text.hasPrefix($0) }),
              let data = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == (prefix == Self.prefixV2 ? 2 : 1),
              value.version != 1 || value.currency == .ton,
              value.currency == .ton || value.currency == .usdt,
              value.senderId == authorId, value.senderId != value.recipientId,
              (value.senderId == accountId && value.recipientId == chatPeerId)
                || (value.recipientId == accountId && value.senderId == chatPeerId) else { return nil }
        return value
    }
}

public enum TonEnvelopeState: String, Codable {
    case sent, opened, cancelled, expired
}

public struct TonEnvelope: Codable, Equatable {
    public let id: UUID
    public let senderId: Int64
    public let recipientId: Int64
    public let state: TonEnvelopeState
    /// True only in the response to the claim which actually credited the wallet.
    public let openedNow: Bool?
    public let amountUnits: Int64?
    public let message: String
    public let createdAt: Int64
    public let expiresAt: Int64
    public let currency: EnvelopeCurrency

    public init(id: UUID, senderId: Int64, recipientId: Int64, state: TonEnvelopeState, amountUnits: Int64?, message: String, createdAt: Int64, expiresAt: Int64, currency: EnvelopeCurrency = .ton) {
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.state = state
        self.openedNow = nil
        self.amountUnits = amountUnits
        self.message = message
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey { case id, senderId, recipientId, state, openedNow, amountUnits, message, createdAt, expiresAt, currency }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.senderId = try values.decode(Int64.self, forKey: .senderId)
        self.recipientId = try values.decode(Int64.self, forKey: .recipientId)
        self.state = try values.decode(TonEnvelopeState.self, forKey: .state)
        self.openedNow = try values.decodeIfPresent(Bool.self, forKey: .openedNow)
        self.amountUnits = try values.decodeIfPresent(Int64.self, forKey: .amountUnits)
        self.message = try values.decode(String.self, forKey: .message)
        self.createdAt = try values.decode(Int64.self, forKey: .createdAt)
        self.expiresAt = try values.decode(Int64.self, forKey: .expiresAt)
        self.currency = try values.decodeIfPresent(EnvelopeCurrency.self, forKey: .currency) ?? .ton
    }

    public var reference: EnvelopeMessageReference {
        return EnvelopeMessageReference(id: self.id, senderId: self.senderId, recipientId: self.recipientId, currency: self.currency)
    }

    public var amountText: String? {
        return self.amountUnits.map { Self.format($0, currency: self.currency) + " " + self.currency.displayName }
    }

    public static func format(_ units: Int64, currency: EnvelopeCurrency = .ton) -> String {
        let whole = units / currency.demoScale
        let fraction = units % currency.demoScale
        guard fraction != 0 else { return String(whole) }
        var suffix = String(format: "%0*lld", currency.demoFractionDigits, fraction)
        while suffix.last == "0" { suffix.removeLast() }
        return "\(whole).\(suffix)"
    }
}

public struct EnvelopeWallet: Codable {
    public let balanceUnits: Int64
    public let currency: EnvelopeCurrency
    private enum CodingKeys: String, CodingKey { case balanceUnits, currency }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.balanceUnits = try values.decode(Int64.self, forKey: .balanceUnits)
        self.currency = try values.decodeIfPresent(EnvelopeCurrency.self, forKey: .currency) ?? .ton
    }
    public var displayText: String { return TonEnvelope.format(self.balanceUnits, currency: self.currency) + " " + self.currency.displayName }
}

public enum EnvelopeServiceError: Error {
    case configuration, unavailable, invalidResponse
    case rejected(String)
}

/// Provisioned by the demo operator, never read from a received Telegram message.
/// A token is bound to one account by the service. There are no role controls in UI.
public struct EnvelopeServiceConfiguration: Codable {
    public let serverURL: URL
    public let accounts: [String: String]

    public static func load() throws -> Self {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("telegram-envelopes-demo.json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.serverURL.user == nil, value.serverURL.password == nil,
              value.serverURL.query == nil, value.serverURL.fragment == nil,
              value.serverURL.path.isEmpty || value.serverURL.path == "/",
              value.serverURL.scheme == "https" || (value.serverURL.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(value.serverURL.host ?? "")) else {
            throw EnvelopeServiceError.configuration
        }
        return value
    }
}

/// Foundation-only boundary: replace this demo HTTP adapter when Telegram provides
/// an envelope API. State and balances are committed by the service, never by an animation.
public final class EnvelopeService {
    public static let changed = Notification.Name("TelegramTonEnvelopeChanged")
    private let accountId: Int64
    private let configuration: EnvelopeServiceConfiguration
    private let token: String
    private let session: URLSession

    public convenience init(accountId: Int64) throws {
        let configuration = try EnvelopeServiceConfiguration.load()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 15
        try self.init(accountId: accountId, configuration: configuration, session: URLSession(configuration: sessionConfiguration))
    }

    init(accountId: Int64, configuration: EnvelopeServiceConfiguration, session: URLSession) throws {
        guard let token = configuration.accounts[String(accountId)], !token.isEmpty else { throw EnvelopeServiceError.configuration }
        self.accountId = accountId
        self.configuration = configuration
        self.token = token
        self.session = session
    }

    deinit { self.session.invalidateAndCancel() }

    public func wallet(currency: EnvelopeCurrency = .ton, completion: @escaping (Result<EnvelopeWallet, Error>) -> Void) {
        guard currency == .ton || currency == .usdt else {
            completion(.failure(EnvelopeServiceError.rejected("invalid_currency"))); return
        }
        self.request("GET", path: "v1/wallet", query: [URLQueryItem(name: "currency", value: currency.rawValue)], body: nil) { (result: Result<EnvelopeWallet, Error>) in
            switch result {
            case let .success(wallet):
                guard wallet.currency == currency, wallet.balanceUnits >= 0 else {
                    completion(.failure(EnvelopeServiceError.invalidResponse)); return
                }
                completion(.success(wallet))
            case let .failure(error): completion(.failure(error))
            }
        }
    }

    public func create(recipientId: Int64, amount: EnvelopeAmount, message: String, submissionId: UUID, completion: @escaping (Result<TonEnvelope, Error>) -> Void) {
        guard (amount.currency == .ton || amount.currency == .usdt), amount.units > 0, amount.units <= 1_000_000 * amount.currency.demoScale,
              recipientId != self.accountId, message.unicodeScalars.count <= 200 else {
            completion(.failure(EnvelopeServiceError.rejected("invalid_amount")))
            return
        }
        self.request("POST", path: "v1/envelopes", body: ["recipientId": recipientId, "amountUnits": amount.units, "currency": amount.currency.rawValue, "message": message, "submissionId": submissionId.uuidString]) { (result: Result<TonEnvelope, Error>) in
            switch result {
            case let .success(envelope):
                guard envelope.senderId == self.accountId, envelope.recipientId == recipientId,
                      envelope.amountUnits == amount.units, envelope.currency == amount.currency,
                      envelope.message == message else {
                    completion(.failure(EnvelopeServiceError.invalidResponse)); return
                }
                completion(.success(envelope))
            case let .failure(error): completion(.failure(error))
            }
        }
    }

    public func fetch(_ reference: EnvelopeMessageReference, completion: @escaping (Result<TonEnvelope, Error>) -> Void) {
        self.envelopeRequest("GET", reference: reference, suffix: "", completion: completion)
    }

    public func claim(_ reference: EnvelopeMessageReference, completion: @escaping (Result<TonEnvelope, Error>) -> Void) {
        self.envelopeRequest("POST", reference: reference, suffix: "/claim", completion: completion)
    }

    public func cancel(_ reference: EnvelopeMessageReference, completion: @escaping (Result<TonEnvelope, Error>) -> Void) {
        self.envelopeRequest("POST", reference: reference, suffix: "/cancel", completion: completion)
    }

    private func envelopeRequest(_ method: String, reference: EnvelopeMessageReference, suffix: String, completion: @escaping (Result<TonEnvelope, Error>) -> Void) {
        self.request(method, path: "v1/envelopes/" + reference.id.uuidString.lowercased() + suffix, body: nil) { (result: Result<TonEnvelope, Error>) in
            switch result {
            case let .success(envelope):
                var identity = reference
                identity.openingEmoji = []
                guard envelope.reference == identity else { completion(.failure(EnvelopeServiceError.invalidResponse)); return }
                if method == "POST" { NotificationCenter.default.post(name: Self.changed, object: reference.id) }
                completion(.success(envelope))
            case let .failure(error): completion(.failure(error))
            }
        }
    }

    private func request<T: Decodable>(_ method: String, path: String, query: [URLQueryItem] = [], body: [String: Any]?, completion: @escaping (Result<T, Error>) -> Void) {
        guard var components = URLComponents(url: self.configuration.serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            completion(.failure(EnvelopeServiceError.configuration)); return
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { completion(.failure(EnvelopeServiceError.configuration)); return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + self.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        self.session.dataTask(with: request) { data, response, error in
            let result: Result<T, Error>
            if let error { result = .failure(error) }
            else if let data, let response = response as? HTTPURLResponse {
                if response.statusCode == 200, let value = try? JSONDecoder().decode(T.self, from: data) { result = .success(value) }
                else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: String], let code = json["error"] { result = .failure(EnvelopeServiceError.rejected(code)) }
                else { result = .failure(EnvelopeServiceError.invalidResponse) }
            } else { result = .failure(EnvelopeServiceError.unavailable) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
