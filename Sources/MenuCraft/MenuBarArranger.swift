import AppKit

@MainActor
enum MenuBarArranger {
    enum Placement {
        case leftOf(String)
        case rightOf(String)

        var targetID: String {
            switch self {
            case .leftOf(let id), .rightOf(let id): id
            }
        }
    }

    /// Moves an item next to another by ⌘-dragging it. Both items must be visible in the menu bar.
    /// `snapshot` returns every item currently in the menu bar, ordered left to right.
    static func move(_ itemID: String, _ placement: Placement, snapshot: () async -> [MenuBarItem]) async -> Bool {
        guard Permissions.accessibility else { return false }

        for attempt in 0..<2 {
            let items = await snapshot()
            guard let item = items.first(where: { $0.id == itemID }),
                  let target = items.first(where: { $0.id == placement.targetID })
            else { return false }

            if isSatisfied(itemID, placement, in: items) { return true }

            // Aim the item's center at the target's edge; on retry overshoot slightly.
            let nudge: CGFloat = attempt == 0 ? 0 : 6
            let x: CGFloat = switch placement {
            case .leftOf: target.frame.minX - nudge
            case .rightOf: target.frame.maxX + nudge
            }
            await EventSimulator.commandDrag(
                from: CGPoint(x: item.frame.midX, y: item.frame.midY),
                to: CGPoint(x: x, y: target.frame.midY)
            )
        }
        return isSatisfied(itemID, placement, in: await snapshot())
    }

    private static func isSatisfied(_ itemID: String, _ placement: Placement, in items: [MenuBarItem]) -> Bool {
        let ids = items.map(\.id)
        guard let itemIndex = ids.firstIndex(of: itemID),
              let targetIndex = ids.firstIndex(of: placement.targetID)
        else { return false }
        switch placement {
        case .leftOf: return itemIndex + 1 == targetIndex
        case .rightOf: return itemIndex == targetIndex + 1
        }
    }
}
