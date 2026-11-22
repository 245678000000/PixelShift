import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func grad(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
}

/// Apple-style continuous-corner squircle (superellipse).
func squircle(_ r: CGRect, n: CGFloat = 4.2) -> CGPath {
    let p = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func rounded(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// ---------- Background tile ----------
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(c(0.1, 0.1, 0.2)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(grad([c(0.20, 0.22, 0.42), c(0.08, 0.09, 0.20)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// soft glow behind the cards
ctx.drawRadialGradient(grad([c(0.45, 0.40, 1.0, 0.55), c(0.45, 0.40, 1.0, 0)]),
                       startCenter: CGPoint(x: 520, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 520, y: 560), endRadius: 420, options: [])
ctx.restoreGState()

// inner top highlight
ctx.saveGState()
ctx.addPath(tilePath); ctx.setStrokeColor(c(1, 1, 1, 0.12)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

// ---------- Cards ----------
func card(center: CGPoint, size: CGSize, angle: CGFloat, draw: (CGRect) -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    let r = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    // shadow + white frame
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: c(0, 0, 0, 0.45))
    ctx.addPath(rounded(r, 44)); ctx.setFillColor(c(0.98, 0.98, 1)); ctx.fillPath()
    ctx.restoreGState()
    let inner = r.insetBy(dx: 26, dy: 26)
    ctx.saveGState()
    ctx.addPath(rounded(inner, 24)); ctx.clip()
    draw(inner)
    ctx.restoreGState()
    ctx.restoreGState()
}

// Back card: warm sunset photo
card(center: CGPoint(x: 430, y: 560), size: CGSize(width: 430, height: 500), angle: 12) { r in
    ctx.drawLinearGradient(grad([c(1.0, 0.62, 0.30), c(0.96, 0.32, 0.45)]),
                           start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    ctx.setFillColor(c(1, 0.92, 0.6, 0.95))
    ctx.fillEllipse(in: CGRect(x: r.midX - 60, y: r.midY - 20, width: 120, height: 120))
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: r.minX, y: r.minY))
    hill.addLine(to: CGPoint(x: r.minX, y: r.midY - 40))
    hill.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY - 90), control: CGPoint(x: r.midX, y: r.midY + 40))
    hill.addLine(to: CGPoint(x: r.maxX, y: r.minY)); hill.closeSubpath()
    ctx.addPath(hill); ctx.setFillColor(c(0.55, 0.16, 0.38)); ctx.fillPath()
}

// Front card: blue sky + mountains
card(center: CGPoint(x: 590, y: 480), size: CGSize(width: 440, height: 510), angle: -7) { r in
    ctx.drawLinearGradient(grad([c(0.38, 0.74, 1.0), c(0.70, 0.90, 1.0)]),
                           start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    ctx.setFillColor(c(1, 0.86, 0.30))
    ctx.fillEllipse(in: CGRect(x: r.maxX - 150, y: r.maxY - 160, width: 96, height: 96))
    let far = CGMutablePath()
    far.move(to: CGPoint(x: r.minX, y: r.minY))
    far.addLine(to: CGPoint(x: r.minX, y: r.midY - 10))
    far.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.midY + 90))
    far.addLine(to: CGPoint(x: r.minX + r.width * 0.62, y: r.midY - 20))
    far.addLine(to: CGPoint(x: r.maxX, y: r.midY + 50))
    far.addLine(to: CGPoint(x: r.maxX, y: r.minY)); far.closeSubpath()
    ctx.addPath(far); ctx.setFillColor(c(0.30, 0.52, 0.86)); ctx.fillPath()
    let near = CGMutablePath()
    near.move(to: CGPoint(x: r.minX, y: r.minY))
    near.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.25))
    near.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18),
                      control: CGPoint(x: r.midX, y: r.minY + r.height * 0.48))
    near.addLine(to: CGPoint(x: r.maxX, y: r.minY)); near.closeSubpath()
    ctx.addPath(near); ctx.setFillColor(c(0.16, 0.62, 0.50)); ctx.fillPath()
}

// ---------- Convert badge ----------
let bc = CGPoint(x: 735, y: 285), br: CGFloat = 118
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: c(0, 0, 0, 0.45))
ctx.setFillColor(c(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: bc.x - br - 10, y: bc.y - br - 10, width: 2 * br + 20, height: 2 * br + 20))
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: 2 * br, height: 2 * br)); ctx.clip()
ctx.drawLinearGradient(grad([c(0.55, 0.45, 1.0), c(0.85, 0.30, 0.85)]),
                       start: CGPoint(x: bc.x - br, y: bc.y + br), end: CGPoint(x: bc.x + br, y: bc.y - br), options: [])
ctx.restoreGState()
// two curved arrows (cycle)
ctx.saveGState()
ctx.setStrokeColor(c(1, 1, 1)); ctx.setFillColor(c(1, 1, 1))
ctx.setLineWidth(22); ctx.setLineCap(.round)
let ar: CGFloat = 58
for k in 0..<2 {
    let start = CGFloat(k) * .pi + 0.35, end = start + .pi - 0.75
    ctx.addArc(center: bc, radius: ar, startAngle: start, endAngle: end, clockwise: false)
    ctx.strokePath()
    // arrow head at end
    let tip = CGPoint(x: bc.x + ar * cos(end), y: bc.y + ar * sin(end))
    let dir = end + .pi / 2 // tangent direction (counter-clockwise)
    let len: CGFloat = 40, wid: CGFloat = 30
    let fwd = CGPoint(x: tip.x + cos(dir) * len * 0.6, y: tip.y + sin(dir) * len * 0.6)
    let back = CGPoint(x: tip.x - cos(dir) * len * 0.4, y: tip.y - sin(dir) * len * 0.4)
    let nx = cos(dir + .pi / 2) * wid, ny = sin(dir + .pi / 2) * wid
    ctx.move(to: fwd)
    ctx.addLine(to: CGPoint(x: back.x + nx, y: back.y + ny))
    ctx.addLine(to: CGPoint(x: back.x - nx, y: back.y - ny))
    ctx.closePath(); ctx.fillPath()
}
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
