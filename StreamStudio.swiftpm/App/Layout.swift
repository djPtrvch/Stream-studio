import CoreGraphics

/// How slot A and slot B are arranged on the 16:9 canvas.
enum LayoutMode: String, CaseIterable {
    case single     // only the primary slot
    case pip        // primary full screen + the other one small
    case side       // 50/50
}

struct SlotPlacement {
    var rect: CGRect
    var visible: Bool
    var zIndex: Double
    var cornerRadius: CGFloat
}

enum LayoutEngine {
    static func placement(for slot: Slot, primary: Slot, mode: LayoutMode, in size: CGSize) -> SlotPlacement {
        let full = CGRect(origin: .zero, size: size)
        let margin = size.width * 0.025
        let pipWidth = size.width * 0.28
        let pipHeight = pipWidth * 9 / 16
        let pip = CGRect(x: size.width - pipWidth - margin,
                         y: size.height - pipHeight - margin,
                         width: pipWidth, height: pipHeight)
        let isPrimary = slot == primary

        switch mode {
        case .single:
            return isPrimary
                ? SlotPlacement(rect: full, visible: true, zIndex: 0, cornerRadius: 0)
                : SlotPlacement(rect: pip, visible: false, zIndex: 1, cornerRadius: 12)
        case .pip:
            return isPrimary
                ? SlotPlacement(rect: full, visible: true, zIndex: 0, cornerRadius: 0)
                : SlotPlacement(rect: pip, visible: true, zIndex: 1, cornerRadius: 12)
        case .side:
            let half = size.width / 2
            let rect = CGRect(x: isPrimary ? 0 : half, y: 0, width: half, height: size.height)
            return SlotPlacement(rect: rect, visible: true, zIndex: 0, cornerRadius: 0)
        }
    }
}
