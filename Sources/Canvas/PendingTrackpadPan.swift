import AppKit

/// Preserve both travel and release velocity while a pan waits for the canvas to come forward.
struct PendingTrackpadPan {
    private(set) var travel = CGVector.zero
    private(set) var velocity = Magnetism.Velocity()
    private(set) var releaseVelocity: CGVector?
    let viewWidth: CGFloat
    let sensitivity: CGFloat

    init(viewWidth: CGFloat, sensitivity: CGFloat, at time: CFTimeInterval) {
        self.viewWidth = viewWidth
        self.sensitivity = sensitivity
        velocity.add(.zero, at: time)
    }

    mutating func add(_ delta: CGVector, at time: CFTimeInterval) {
        travel.dx += delta.dx
        travel.dy += delta.dy
        let points = CameraInput.trackpadDelta(travel, viewWidth: viewWidth, sensitivity: sensitivity)
        velocity.add(CGPoint(x: points.dx, y: points.dy), at: time)
    }

    mutating func end(at time: CFTimeInterval) {
        releaseVelocity = velocity.release(at: time)
    }
}
