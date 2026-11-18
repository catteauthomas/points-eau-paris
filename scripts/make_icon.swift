// Icône de l'appli : une goutte blanche sur un dégradé bleu Seine, avec une étoile dorée (le jeu).
// Usage : swift scripts/make_icon.swift ios/PointsEau/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else { fatalError("usage : make_icon.swift <sortie.png>") }
let side = 1024
// Pas de canal alpha : App Store Connect refuse les icônes transparentes
let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

// Fond : dégradé diagonal bleu profond → bleu clair
let fond = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x083D77), color(0x0F72D7), color(0x3CC7F0)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(fond, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])

// Goutte (repère CoreGraphics : y vers le haut)
func goutte(cx: CGFloat, cy: CGFloat, r: CGFloat, pointe: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: pointe))
    p.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + r * 0.25, y: pointe - (pointe - cy) * 0.35),
               control2: CGPoint(x: cx + r, y: cy + r * 0.85))
    p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi, clockwise: true)
    p.addCurve(to: CGPoint(x: cx, y: pointe), control1: CGPoint(x: cx - r, y: cy + r * 0.85),
               control2: CGPoint(x: cx - r * 0.25, y: pointe - (pointe - cy) * 0.35))
    p.closeSubpath()
    return p
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x02203F, 0.45))
ctx.addPath(goutte(cx: 480, cy: 400, r: 250, pointe: 900))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Reflet dans la goutte
ctx.addPath(goutte(cx: 400, cy: 420, r: 70, pointe: 560))
ctx.setFillColor(color(0xBFE6FF))
ctx.fillPath()

// Étoile dorée (les points du jeu)
func etoile(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<10 {
        let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let rr = i % 2 == 0 ? r : r * 0.45
        let pt = CGPoint(x: cx + rr * cos(a), y: cy + rr * sin(a))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x02203F, 0.5))
ctx.addPath(etoile(cx: 770, cy: 730, r: 165))
ctx.setFillColor(color(0xFFC21A))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(etoile(cx: 770, cy: 730, r: 165))
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(18)
ctx.setLineJoin(.round)
ctx.strokePath()

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("écriture de l'icône impossible") }
print("icône écrite : \(args[1])")
