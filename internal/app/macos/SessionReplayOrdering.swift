import Foundation

enum SessionReplayOrdering {
    static func align(
        merged: [SessionIdentity: SessionStateRecord],
        replay: [SessionIdentity: SessionStateRecord],
        existing: [SessionIdentity: SessionStateRecord]
    ) -> [SessionIdentity: SessionStateRecord] {
        var aligned = merged
        let groups = Dictionary(grouping: merged.values.filter(\.orderingKnown), by: \.evidenceAt)
        for group in groups.values {
            let ordered = group.sorted { ($0.evidenceOrdinal ?? 0) > ($1.evidenceOrdinal ?? 0) }
            let matched = ordered.filter { $0.evidenceID == replay[$0.identity]?.evidenceID }
            let replayOrder = matched.sorted {
                (replay[$0.identity]?.evidenceOrdinal ?? 0) > (replay[$1.identity]?.evidenceOrdinal ?? 0)
            }
            // Ordinals from separate replay generations are comparable only after their tie order is proven.
            if matched.count == group.count {
                if matched.map(\.identity) != replayOrder.map(\.identity) {
                    for record in matched {
                        aligned[record.identity]?.evidenceOrdinal = replay[record.identity]?.evidenceOrdinal
                    }
                }
                continue
            }
            let retained = Set(matched.filter {
                $0.evidenceID == existing[$0.identity]?.evidenceID &&
                    $0.evidenceOrdinal == existing[$0.identity]?.evidenceOrdinal
            }.map(\.identity))
            let priorKnownOrder = matched.filter { retained.contains($0.identity) }.map(\.identity)
            let replayKnownOrder = replayOrder.filter { retained.contains($0.identity) }.map(\.identity)
            for record in matched where !retained.contains(record.identity) || priorKnownOrder != replayKnownOrder {
                aligned[record.identity] = record.withUnknownOrdering()
            }
        }
        return aligned
    }
}
