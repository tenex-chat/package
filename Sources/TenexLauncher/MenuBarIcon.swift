import AppKit

enum MenuBarIcon {
    /// Creates a template NSImage for the menu bar.
    /// Draws a small network-hub icon: central node with three radiating connections,
    /// representing the TENEX agent daemon.
    static func create(running: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let color = NSColor.black // template image — system handles actual color

            ctx.setFillColor(color.cgColor)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.4)
            ctx.setLineCap(.round)

            // Three satellite nodes positioned around the center
            let satelliteRadius: CGFloat = 2.0
            let orbitRadius: CGFloat = 6.5
            let angles: [CGFloat] = [.pi / 2, .pi / 2 + 2 * .pi / 3, .pi / 2 + 4 * .pi / 3]

            let satellites = angles.map { angle in
                CGPoint(
                    x: center.x + orbitRadius * cos(angle),
                    y: center.y + orbitRadius * sin(angle)
                )
            }

            // Connection lines from center to each satellite
            for sat in satellites {
                ctx.move(to: center)
                ctx.addLine(to: sat)
            }
            ctx.strokePath()

            // Satellite dots
            for sat in satellites {
                let dotRect = CGRect(
                    x: sat.x - satelliteRadius,
                    y: sat.y - satelliteRadius,
                    width: satelliteRadius * 2,
                    height: satelliteRadius * 2
                )
                ctx.fillEllipse(in: dotRect)
            }

            // Central node — larger, filled when running, ring when stopped
            let centralRadius: CGFloat = 3.2
            let centralRect = CGRect(
                x: center.x - centralRadius,
                y: center.y - centralRadius,
                width: centralRadius * 2,
                height: centralRadius * 2
            )

            if running {
                ctx.fillEllipse(in: centralRect)
            } else {
                ctx.setLineWidth(1.6)
                ctx.strokeEllipse(in: centralRect)
            }

            return true
        }

        image.isTemplate = true
        return image
    }
}
