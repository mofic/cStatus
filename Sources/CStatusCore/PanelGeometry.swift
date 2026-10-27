import Foundation
import CoreGraphics

public enum EdgeSide: String, Codable, CaseIterable { case left, right }
public enum PanelGeometry {
    public static func frame(screen: CGRect, side: EdgeSide, expanded: Bool, height: CGFloat, y: CGFloat) -> CGRect {
        let width: CGFloat = expanded ? min(340, screen.width) : 12
        let h = min(height, screen.height)
        return CGRect(x: side == .left ? screen.minX : screen.maxX - width,
                      y: min(max(y, screen.minY), screen.maxY - h), width: width, height: h)
    }
}
