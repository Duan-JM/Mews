import Foundation

@MainActor
extension SessionListPresentationModel {
    var effectiveCanonicalRows: [SessionPresentationRow] {
        return canonicalRows.filter { !suppressedRowIDs.contains($0.id) }
    }

    func reconcilePresentedRows() {
        let effectiveRows = effectiveCanonicalRows
        let canonicalByID = Dictionary(
            uniqueKeysWithValues: effectiveRows.map { ($0.id, $0) }
        )
        let canonicalIDs = Set(canonicalByID.keys)
        let canonicalByIdentity = Dictionary(
            uniqueKeysWithValues: effectiveRows.map { ($0.identity, $0) }
        )

        let replacedRemovalIDs = removalTokens.keys.filter { rowID in
            !canonicalIDs.contains(rowID) && canonicalByIdentity[rowID.identity] != nil
        }
        for rowID in replacedRemovalIDs {
            removalTokens.removeValue(forKey: rowID)
            snapshot.rowVisuals.removeValue(forKey: rowID)
        }

        if let target = interaction.target,
           !effectiveRows.contains(where: { $0.dismissalRequest == target }) {
            if let row = snapshot.rows.first(where: {
                $0.dismissalRequest == target
            }) {
                snapshot.rowVisuals.removeValue(forKey: row.id)
            }
            interaction.reset()
            activeOperation = nil
        }

        var nextRows = snapshot.rows.compactMap { row -> SessionPresentationRow? in
            if removalTokens[row.id] != nil {
                return row
            }
            return canonicalByID[row.id] ?? canonicalByIdentity[row.identity]
        }
        let retainedIDs = Set(nextRows.map(\.id))
        nextRows.append(contentsOf: effectiveRows.filter {
            !retainedIDs.contains($0.id)
        })
        snapshot.rows = nextRows
        let nextRowIDs = Set(nextRows.map(\.id))
        snapshot.rowVisuals = snapshot.rowVisuals.filter {
            nextRowIDs.contains($0.key)
        }
    }
}
