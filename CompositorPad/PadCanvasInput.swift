import UIKit

/// What a touch does with the Move tool and the selection tools, as the Mac's canvas does with the mouse, apart from
/// UIKit's touches: a press, drag and lift at points in the canvas's coordinates, with the keys a hardware keyboard
/// holds. The iPad canvas feeds it touches; tests feed it points.
@MainActor final class PadCanvasInput {
    let session: EditorSession
    /// Asks for the overlay to be drawn again though nothing it observes changed, as the lines a drag snaps to.
    var overlayChanged: () -> Void = {}
    /// Work a press started and left running, such as the Magic Wand's: tests wait for it.
    private(set) var pending: Task<Void, Never>?

    /// How far a finger may land from a handle, or from a polygonal lasso's first corner to close it.
    static let reach: CGFloat = 22

    private lazy var overlay = CanvasOverlay(session: session)
    private enum Drag {
        /// The Move tool: a handle or the layer, and whether its first step drags a copy (Option).
        case transform(TransformDrag, duplicates: Bool)
        /// A marquee or lasso outline being drawn.
        case outline
        /// The next corner of a polygonal lasso, placed where the touch lifts.
        case corner
        /// The selection's outline, dragged from `start`.
        case selection(start: CGPoint)
        /// The selected pixels, cut or copied (Command, Option) and dragged from `start`.
        case pixels(start: CGPoint)
    }
    private var drag: Drag?
    /// Whether Shift squares a marquee: a Shift already held at the press chose Add instead, until it's let go.
    private var squareArmed = false

    init(session: EditorSession) {
        self.session = session
    }

    /// Whether this handles touches with `tool`.
    static func handles(_ tool: NavigationTool) -> Bool { tool == .move || tool.isSelectionTool }

    var isDragging: Bool { drag != nil }

    private func pixel(_ point: CGPoint) -> CGPoint? {
        session.document.map { session.viewport.documentPoint(from: point, documentSize: $0.size) }
    }

    /// A touch coming down at `point`. False when it starts nothing to follow, as a tap with the Magic Wand.
    @discardableResult
    func began(at point: CGPoint, keys: UIKeyModifierFlags = []) -> Bool {
        guard let pixel = pixel(point) else { return false }
        if session.tool == .move {
            // A handle of the transform box, or else the layer under the touch when Auto Select is on, as the Mac's
            // Move tool picks it. Command flips Auto Select, Command-Shift adds the layer to the selection, Command on
            // a handle distorts and Option drags a copy.
            let handle = overlay.geometry?.hit(touch: point, reach: Self.reach)
            guard let transform = session.beginTransformDrag(at: pixel, handle: handle, command: keys.contains(.command),
                                                             shift: keys.contains(.shift)) else { return false }
            if case .move = transform.mode { drag = .transform(transform, duplicates: keys.contains(.alternate)) }
            else { drag = .transform(transform, duplicates: false) }
            return true
        }
        guard session.tool.isSelectionTool else { return false }
        squareArmed = !keys.contains(.shift)
        // A polygonal lasso already begun: the next corner follows the finger and goes down where it lifts.
        if session.lassoDraft?.kind == .polygonal {
            session.moveLassoCursor(to: pixel)
            drag = .corner
            return true
        }
        // Command inside the selection cuts and moves its pixels, and Option with it copies them, as on the Mac.
        if keys.contains(.command), session.canMoveSelection(at: pixel) {
            guard session.beginPixelMove(duplicate: keys.contains(.alternate)) else { Platform.beep(); return false }
            drag = .pixels(start: pixel)
            return true
        }
        let mode = session.selectionMode(shift: keys.contains(.shift), option: keys.contains(.alternate))
        // In New mode a drag inside the selection moves its outline rather than drawing another.
        if mode == .replace, session.canMoveSelection(at: pixel), session.beginSelectionMove() {
            drag = .selection(start: pixel)
            return true
        }
        if session.tool == .wand {
            select(at: pixel, mode: mode)
            return false
        }
        session.beginLasso(at: session.tool == .marquee ? snappedCorner(pixel, keys: keys) : pixel, mode: mode)
        drag = .outline
        return true
    }

    func moved(to point: CGPoint, keys: UIKeyModifierFlags = []) {
        guard let drag, let pixel = pixel(point) else { return }
        switch drag {
        case .transform(let transform, let duplicates):
            if duplicates {
                self.drag = .transform(transform, duplicates: false)
                session.beginDuplicateTransform()
            }
            session.dragTransform(transform, to: pixel, shift: keys.contains(.shift), option: keys.contains(.alternate),
                                  control: keys.contains(.control))
            overlayChanged()
        case .outline:
            switch session.lassoDraft?.kind {
            case .freehand: session.extendLasso(to: pixel)
            case .polygonal: session.moveLassoCursor(to: pixel)
            case .rectangle, .ellipse:
                if !keys.contains(.shift) { squareArmed = true }
                session.dragMarquee(to: snappedCorner(pixel, keys: keys), square: squareArmed && keys.contains(.shift), fromCenter: false)
                overlayChanged()
            case nil: break
            }
        case .corner:
            session.moveLassoCursor(to: pixel)
        case .selection(let start):
            var offset = CGSize(width: pixel.x - start.x, height: pixel.y - start.y)
            var horizontal = true, vertical = true
            // Shift keeps the move on one axis, whichever the drag has gone further along.
            if keys.contains(.shift) {
                if abs(offset.width) >= abs(offset.height) { offset.height = 0; vertical = false }
                else { offset.width = 0; horizontal = false }
            }
            // It snaps to View > Snap To targets as a drawn Marquee does, unless Control is held.
            if keys.contains(.control) { session.snapGuides = ([], []) }
            else {
                offset = session.snappedSelectionOffset(offset, tolerance: TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001),
                                                        horizontal: horizontal, vertical: vertical)
            }
            session.moveSelection(by: offset)
            overlayChanged()
        case .pixels(let start):
            var offset = CGSize(width: pixel.x - start.x, height: pixel.y - start.y)
            if keys.contains(.shift) {
                if abs(offset.width) >= abs(offset.height) { offset.height = 0 } else { offset.width = 0 }
            }
            session.movePixels(by: offset)
        }
    }

    /// The touch lifting at `point`, after `tapCount` taps in quick succession.
    func ended(at point: CGPoint, keys: UIKeyModifierFlags = [], tapCount: Int = 1) {
        defer { finish() }
        guard let drag else { return }
        switch drag {
        case .transform:
            // As the Mac's does: a drag applies itself when it's let go, unless it's part of an edit waiting for Apply.
            if session.transformEdit?.persistent == false { session.commitTransform() }
        case .outline:
            if session.lassoDraft?.kind != .polygonal { session.finishLasso() }
        case .corner:
            guard let draft = session.lassoDraft, let document = session.document, let pixel = pixel(point) else { break }
            // A double tap, or a tap back on the first corner once there are three, closes the outline.
            let first = session.viewport.viewPoint(from: draft.points[0], documentSize: document.size)
            if tapCount >= 2 || (draft.points.count >= 3 && hypot(point.x - first.x, point.y - first.y) <= Self.reach) {
                session.finishLasso()
            } else {
                session.extendLasso(to: pixel)
                session.moveLassoCursor(to: nil)
            }
        case .selection(let start):
            let moved = session.selectionMoveOrigin != session.selection
            session.endSelectionMove()
            // A tap inside the selection: the Magic tools select afresh from there, and the others deselect.
            if !moved, session.tool == .wand { select(at: start, mode: .replace) }
            else if !moved { session.deselect() }
        case .pixels:
            pending = Task { [session] in await session.finishPixelMove() }
        }
    }

    /// The touch taken away, as by a second finger coming down to zoom: what it was doing is undone.
    func cancelled() {
        defer { finish() }
        guard let drag else { return }
        switch drag {
        case .transform(let transform, _):
            session.previewTransform(transform.original)
            if let corners = transform.originalCorners { session.previewCorners(corners) }
            if session.transformEdit?.persistent == false { session.cancelTransform() }
        case .outline:
            if session.lassoDraft?.kind != .polygonal { session.cancelLasso() }
        case .corner:
            session.moveLassoCursor(to: nil)
        case .selection:
            session.endSelectionMove()
        case .pixels:
            session.cancelPixelMove()
        }
    }

    private func finish() {
        drag = nil
        session.snapGuides = ([], [])
        overlayChanged()
    }

    /// The Magic tool at `pixel`: the object there, or the pixels of similar color.
    private func select(at pixel: CGPoint, mode: SelectionMode) {
        let session = session
        pending = Task {
            if session.wandMode == .object { await session.selectObject(at: pixel, mode: mode) }
            else { await session.magicWand(at: pixel, mode: mode) }
        }
    }

    /// A marquee corner at `pixel`, snapped to View > Snap To targets unless Control is held.
    private func snappedCorner(_ pixel: CGPoint, keys: UIKeyModifierFlags) -> CGPoint {
        guard !keys.contains(.control) else { session.snapGuides = ([], []); return pixel }
        return session.snappedPoint(pixel, tolerance: TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001))
    }
}
