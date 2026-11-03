import Foundation

/// Presentation history on this sender's device. A positive time is an outgoing
/// envelope waiting to open. A negative time suppresses replay on scrolling or retry.
public final class EnvelopeSenderOpenings {
    public static let shared = EnvelopeSenderOpenings(defaults: .standard)
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    @discardableResult
    public func observe(_ reference: EnvelopeMessageReference, state: TonEnvelopeState, visible: Bool) -> Bool {
        let key = "EnvelopeSenderOpenings.\(reference.senderId)"
        var records = self.defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let id = reference.id.uuidString
        let previous = records[id]
        let now = Date().timeIntervalSince1970
        let play: Bool
        switch state {
        case .sent:
            guard previous == nil else { return false }
            records[id] = now
            play = false
        case .opened:
            // A history load must not replay already-open gifts. Only animate a
            // receipt this device knew was pending, when it can actually show it.
            guard visible, let previous, previous >= now - 2 * 86400 else { return false }
            records[id] = -now
            play = true
        case .cancelled, .expired:
            guard let previous, previous > 0 else { return false }
            records[id] = -now
            play = false
        }
        records = records.filter { abs($0.value) >= now - 2 * 86400 }
        if records.count > 256 {
            for old in records.sorted(by: { abs($0.value) < abs($1.value) }).prefix(records.count - 256) {
                records.removeValue(forKey: old.key)
            }
        }
        self.defaults.set(records, forKey: key)
        return play
    }
}
