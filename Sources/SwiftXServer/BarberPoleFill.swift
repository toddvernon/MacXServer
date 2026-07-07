import SwiftUI

/// The in-motion thermometer fill, shared by the Machines-window Overview bar
/// and the console windows' top bar: diagonal accent + dark-gray stripes that
/// march steadily to the right (the shimmer) while the guest boots or shuts
/// down. TimelineView + Canvas rather than a repeatForever animation because
/// both hosts are NSPanel/NSWindow-hosted SwiftUI, where repeatForever
/// animations are unreliable (same gotcha family as the NavigationSplitView
/// one).
struct BarberPoleFill: View {
    let accent: Color

    /// Stripe geometry: accent and dark bands of equal width, 45° slant.
    private let stripeWidth: CGFloat = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(accent))
                let period = stripeWidth * 2
                // One full period every ~0.8s, phase-locked to the clock so the
                // march never jumps when SwiftUI rebuilds the view.
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(t.truncatingRemainder(dividingBy: 0.8) / 0.8) * period
                // Parallelogram stripes slanted 45° (offset by the bar height),
                // starting far enough left that the slant covers x = 0.
                var x = phase - period - size.height
                while x < size.width {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: size.height))
                    stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                    stripe.addLine(to: CGPoint(x: x + size.height + stripeWidth, y: 0))
                    stripe.addLine(to: CGPoint(x: x + stripeWidth, y: size.height))
                    stripe.closeSubpath()
                    ctx.fill(stripe, with: .color(.black.opacity(0.35)))
                    x += period
                }
            }
        }
    }
}
