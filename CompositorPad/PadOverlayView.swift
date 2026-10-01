import Observation
import UIKit

/// What's drawn over the canvas: the transform box and its handles, guides, the crop frame, marching ants and the
/// lines a move snaps to, drawn by the editor's own `CanvasOverlay`, as the Mac's canvas draws them.
final class PadOverlayView: UIView {
    let overlay: CanvasOverlay

    init(session: EditorSession) {
        overlay = CanvasOverlay(session: session)
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        overlay.needsDisplay = { [weak self] in self?.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws, and draws again when anything it read from the editor changes. The lines a move snaps to aren't
    /// observed; the canvas asks for those itself as it drags.
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        withObservationTracking {
            overlay.draw(in: context, bounds: bounds, deviceScale: traitCollection.displayScale)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.setNeedsDisplay() }
        }
    }
}

extension TransformOverlayGeometry {
    /// What a touch at `point` grabs. A fingertip is broader than a pointer, so the nearest handle within `reach`
    /// counts, though less of it around a small box, which a finger should still move by pressing inside it; the edges
    /// count within a pointer's 10 points.
    func hit(touch point: CGPoint, reach: CGFloat = 22) -> TransformDrag.Mode? {
        let side = min(hypot(handles[2].x - handles[0].x, handles[2].y - handles[0].y),
                       hypot(handles[6].x - handles[0].x, handles[6].y - handles[0].y))
        let reach = min(reach, max(10, side / 3))
        var nearest: (mode: TransformDrag.Mode, distance: CGFloat)?
        func consider(_ mode: TransformDrag.Mode, at handle: CGPoint) {
            let distance = hypot(point.x - handle.x, point.y - handle.y)
            if distance <= reach, distance < nearest?.distance ?? .infinity { nearest = (mode, distance) }
        }
        if showsRotation { consider(.rotate, at: rotationHandle) }
        for (index, handle) in handles.enumerated() { consider(.resize(index), at: handle) }
        return nearest?.mode ?? hit(point)
    }
}
