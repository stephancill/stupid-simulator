// Vision OCR that prints recognized text with on-device screen coordinates.
//
// Usage:
//   ocr <image-path> [scale] [--raw] [--meta] [--regions [n]] [--accurate]
//
//   - scale   : pixels -> points divisor (device @2x or @3x). Default 3.
//   - --raw   : print the recognized string only (no coordinates).
//   - --meta  : also print a "META ..." line (white fraction + element count) so a caller
//               can tell "blank because unreadable" from "blank/dim screen".
//   - --regions [n] : also print up to n "REGION cx cy w h" boxes for non-background
//               pixel clusters (useful when text is unreadable but a button/panel exists).
//   Text is lightly normalized (e.g. "0×" -> "0x", repeated spaces collapsed).
import Foundation
import Vision
import AppKit

let args = CommandLine.arguments
guard args.count >= 2,
  let img = NSImage(contentsOfFile: args[1]),
  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  print("ERR: cannot load image")
  exit(1)
}

var scale: Double = 3.0
var rawMode = false
var metaMode = false
var regionLimit = 0
var accurate = false
for a in args.dropFirst(2) {
  if a == "--raw" { rawMode = true }
  else if a == "--meta" { metaMode = true }
  else if a == "--regions" { regionLimit = 12 }
  else if a == "--accurate" { accurate = true }
  else if let f = Double(a), f > 0 { scale = f }
}

let W = Double(cg.width)
let H = Double(cg.height)

func cleaned(_ s: String) -> String {
  // Normalize noisy OCR output: Vision often renders "0x" as "0×" and adds stray spaces.
  let out = s
    .replacingOccurrences(of: "0×", with: "0x")
    .replacingOccurrences(of: "÷", with: "x")
    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  return out
}

// --- Text recognition ---------------------------------------------------------
func runTextOCR() {
  let req = VNRecognizeTextRequest()
  // Fast by default: on macOS 27 (Darwin 27.0) the accurate recognizer fails in Vision's
  // neural runtime (e5rtError 13) on every compute device, CPU included.
  req.recognitionLevel = accurate ? .accurate : .fast
  req.minimumTextHeight = 0.003
  req.usesLanguageCorrection = true
  // A failed request is reported, not mistaken for a screen with no text on it.
  do {
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
  } catch {
    let hint = accurate ? " Try without --accurate." : ""
    FileHandle.standardError.write(Data("ERR: text recognition failed: \(error).\(hint)\n".utf8))
    exit(1)
  }
  guard let results = req.results else { return }
  for obs in results {
    guard let text = obs.topCandidates(1).first?.string else { continue }
    if rawMode {
      print(cleaned(text))
    } else {
      let b = obs.boundingBox
      let cx = (b.midX) * W / scale
      let cy = (1.0 - b.midY) * H / scale
      print(String(format: "%6.0f %6.0f  %@", cx, cy, cleaned(text)))
    }
  }
}

// --- Screen stats ----------------------------------------------------------------
// Reads raw RGBA once for both white-fraction and region detection.
struct RGBA { let r: UInt8, g: UInt8, b: UInt8 }

func scanPixels() -> (white: Double, regions: [(cx: Double, cy: Double, kind: String)]) {
  guard let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
    return (white: 0, regions: [])
  }
  let bpp = cg.bitsPerPixel / 8
  var white = 0
  var total = 0
  // Downsample for both speed and connected-component blob detection.
  let gridX = 80
  let gridY = 160
  var marked = [[Bool]](repeating: [Bool](repeating: false, count: gridX), count: gridY)
  for gy in 0..<gridY {
    let py = min(gy * (cg.height / gridY), cg.height - 1)
    for gx in 0..<gridX {
      let px = min(gx * (cg.width / gridX), cg.width - 1)
      let idx = (py * cg.width + px) * bpp
      let r = Int(bytes[idx])
      let g = Int(bytes[idx + 1])
      let b = Int(bytes[idx + 2])
      total += 1
      if r > 235, g > 235, b > 235 { white += 1 }
      // Flag strong-color or dark pixels that differ from the light background.
      let isDark = (r + g + b) < 420
      let isStrongColor = (max(r, g, b) - min(r, g, b)) > 60
      marked[gy][gx] = isDark || isStrongColor
    }
  }
  // Connected components on the downsampled grid, take the largest blobs.
  var visited = [[Bool]](repeating: [Bool](repeating: false, count: gridX), count: gridY)
  var blobs: [(sx: Int, sy: Int, size: Int)] = []
  let dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)]
  for gy in 0..<gridY {
    for gx in 0..<gridX where marked[gy][gx] && !visited[gy][gx] {
      var stack = [(gy, gx)]
      var minx = gx, maxx = gx, miny = gy, maxy = gy
      var size = 0
      visited[gy][gx] = true
      while let (y, x) = stack.popLast() {
        size += 1
        minx = min(minx, x); maxx = max(maxx, x)
        miny = min(miny, y); maxy = max(maxy, y)
        for (dy, dx) in dirs {
          let ny = y + dy, nx = x + dx
          if ny >= 0 && ny < gridY && nx >= 0 && nx < gridX && marked[ny][nx] && !visited[ny][nx] {
            visited[ny][nx] = true
            stack.append((ny, nx))
          }
        }
      }
      if size >= 4 { blobs.append((sx: minx, sy: miny, size: size)) }
    }
  }
  blobs.sort { $0.size > $1.size }
  var regions: [(Double, Double, String)] = []
  for blob in blobs.prefix(regionLimit) {
    let px = Double(blob.sx) + 0.5
    let py = Double(blob.sy) + 0.5
    let cx = (px * Double(cg.width) / Double(gridX)) / scale
    let cy = (py * Double(cg.height) / Double(gridY)) / scale
    regions.append((cx, cy, blob.size >= 40 ? "panel" : "dot"))
  }
  return (Double(white) / Double(max(total, 1)), regions)
}

if rawMode {
  runTextOCR()
} else {
  let stats = scanPixels()
  if metaMode {
    print(String(format: "META white=%0.2f", stats.white))
  }
  for (cx, cy, kind) in stats.regions {
    print(String(format: "REGION %6.0f %6.0f %@", cx, cy, kind))
  }
  runTextOCR()
}