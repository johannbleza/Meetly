// Builds the Meets brand SVGs from the symbol's pen line.
//
//     swift design/brand/build.swift
//
// The symbol ("Jot") is one round-capped pen stroke: a cursive m whose last leg runs on into the line of a note.
// It's drawn here as a centerline, then outlined and merged with CoreGraphics so the shipped SVGs are plain filled
// paths. Re-render the app icon PNGs afterwards (see CLAUDE.md).

import CoreGraphics
import Foundation

let ink = "#111113"

/// The m, from the pen landing to the turn into the line.
let mStroke = "M 20 168 C 30 130, 52 92, 80 90 C 100 89, 96 126, 82 168 C 94 142, 108 118, 124 118 "
    + "C 140 118, 140 140, 142 150 C 145 164, 154 170, 170 170 "

/// The full mark: a long line with one soft wave.
let master = (line: mStroke + "C 194 170, 208 163, 222 165 C 230 166, 234 169, 240 169", width: 16.0)
/// Reversed (white on dark) reads heavier, so it's drawn a little thinner.
let reversed = (line: master.line, width: 15.0)
/// Heavier, with a shorter line: for the app icon (the full mark looked thin in the Dock), the menu bar and anything
/// 64 px and under.
let small = (line: mStroke + "C 188 170, 200 164, 212 166 C 218 167, 222 169, 226 169", width: 20.0)

// MARK: - Outlining

func path(_ d: String) -> CGPath {
    let tokens = d.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
    let p = CGMutablePath()
    var i = 0
    func num(_ k: Int) -> CGFloat { CGFloat(Double(tokens[k])!) }
    while i < tokens.count {
        switch tokens[i] {
        case "M":
            p.move(to: CGPoint(x: num(i + 1), y: num(i + 2))); i += 3
        case "C":
            p.addCurve(to: CGPoint(x: num(i + 5), y: num(i + 6)),
                       control1: CGPoint(x: num(i + 1), y: num(i + 2)),
                       control2: CGPoint(x: num(i + 3), y: num(i + 4)))
            i += 7
        default:
            fatalError("unsupported path command \(tokens[i])")
        }
    }
    return p
}

/// The stroke as one filled outline, overlaps merged. Merging can leave zero-area slivers behind; those are dropped.
func outline(_ line: String, width: Double) -> CGPath {
    let merged = path(line)
        .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
        .normalized(using: .winding)
    let clean = CGMutablePath()
    for piece in merged.componentsSeparated(using: .winding) {
        let box = piece.boundingBoxOfPath
        if box.width > 1, box.height > 1 { clean.addPath(piece) }
    }
    return clean
}

func fmt(_ v: CGFloat) -> String {
    var s = String(format: "%.2f", Double(v))
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

/// SVG path data, moved by (dx, dy).
func svgData(_ p: CGPath, dx: CGFloat = 0, dy: CGFloat = 0) -> String {
    var out: [String] = []
    func pt(_ q: CGPoint) -> String { "\(fmt(q.x + dx)) \(fmt(q.y + dy))" }
    p.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: out.append("M\(pt(e.points[0]))")
        case .addLineToPoint: out.append("L\(pt(e.points[0]))")
        case .addQuadCurveToPoint: out.append("Q\(pt(e.points[0])) \(pt(e.points[1]))")
        case .addCurveToPoint: out.append("C\(pt(e.points[0])) \(pt(e.points[1])) \(pt(e.points[2]))")
        case .closeSubpath: out.append("Z")
        @unknown default: break
        }
    }
    return out.joined(separator: " ")
}

/// Offset that puts the outline's box at the canvas centre, lifted a little to sit at the optical centre.
func centring(_ p: CGPath) -> (dx: CGFloat, dy: CGFloat) {
    let box = p.boundingBoxOfPath
    return (128 - box.midX, 126 - box.midY)
}

// MARK: - Files

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // design/brand
let repo = root.deletingLastPathComponent().deletingLastPathComponent()

func write(_ text: String, _ url: URL) {
    try! (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(url.path.replacingOccurrences(of: repo.path + "/", with: ""))")
}

func symbolSVG(_ title: String, _ d: String, fill: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" width=\"256\" height=\"256\" role=\"img\">"
        + "<title>\(title)</title><path fill=\"\(fill)\" d=\"\(d)\"/></svg>"
}

/// The white squircle the symbol sits on (unchanged from the previous icon).
func appIconSVG(_ d: String, scale: Double) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\" role=\"img\">"
        + "<title>Meets app icon</title><defs>"
        + "<linearGradient id=\"bg\" x1=\"0\" y1=\"100\" x2=\"0\" y2=\"924\" gradientUnits=\"userSpaceOnUse\">"
        + "<stop offset=\"0\" stop-color=\"#FFFFFF\"/><stop offset=\"1\" stop-color=\"#E9E9EC\"/></linearGradient>"
        + "<filter id=\"shadow\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"125%\">"
        + "<feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"10\" flood-color=\"#000\" flood-opacity=\"0.28\"/></filter>"
        + "</defs>"
        + "<rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" rx=\"185\" fill=\"url(#bg)\" filter=\"url(#shadow)\"/>"
        + "<rect x=\"101\" y=\"101\" width=\"822\" height=\"822\" rx=\"184\" fill=\"none\" stroke=\"#000\" "
        + "stroke-opacity=\"0.1\" stroke-width=\"2\"/>"
        + "<g transform=\"translate(512 512) scale(\(scale)) translate(-128 -128)\">"
        + "<path fill=\"\(ink)\" d=\"\(d)\"/></g></svg>"
}

let masterOutline = outline(master.line, width: master.width)
let c = centring(masterOutline)
let masterData = svgData(masterOutline, dx: c.dx, dy: c.dy)
// The reversed cut shares the master's centre so the two swap in place.
let reversedData = svgData(outline(reversed.line, width: reversed.width), dx: c.dx, dy: c.dy)
let smallOutline = outline(small.line, width: small.width)
let sc = centring(smallOutline)
let smallData = svgData(smallOutline, dx: sc.dx, dy: sc.dy)

write(symbolSVG("Meets symbol", masterData, fill: ink), root.appendingPathComponent("meets-symbol.svg"))
write(symbolSVG("Meets symbol", reversedData, fill: "#FFFFFF"), root.appendingPathComponent("meets-symbol-white.svg"))
write(symbolSVG("Meets symbol, small sizes", smallData, fill: ink), root.appendingPathComponent("meets-symbol-small.svg"))
write(appIconSVG(smallData, scale: 3.05), root.appendingPathComponent("meets-app-icon.svg"))
write(appIconSVG(smallData, scale: 3.15), root.appendingPathComponent("meets-app-icon-small.svg"))

// The template asset for the menu bar and the in-app button: the small cut, cropped to the ink.
let box = smallOutline.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
let crop = "\(fmt(box.minX + sc.dx)) \(fmt(box.minY + sc.dy)) \(fmt(box.width)) \(fmt(box.height))"
write("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(crop)\" width=\"\(fmt(box.width))\" "
      + "height=\"\(fmt(box.height))\" role=\"img\"><title>Meets symbol</title>"
      + "<path fill=\"#000000\" d=\"\(smallData)\"/></svg>",
      repo.appendingPathComponent("Meetly/Assets.xcassets/MeetsSymbol.imageset/MeetsSymbol.svg"))
print("MeetsSymbol aspect \(fmt(box.width / box.height)) : 1")
