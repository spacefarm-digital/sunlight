import CoreGraphics

/// Converts four-finger travel in trackpad widths into screen-point camera movement.
enum CameraInput {
    static func trackpadDelta(_ travel: CGVector, viewWidth: CGFloat, sensitivity: CGFloat) -> CGVector {
        let scale = viewWidth * 1.5 * sensitivity
        return CGVector(dx: travel.dx * scale, dy: travel.dy * scale)
    }
}
