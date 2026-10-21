// Tạo Resources/AppIcon.png từ Resources/AppIcon-source.png: làm trong suốt nền đen bên ngoài ô bo góc.
// Chạy: swift scripts/make-app-icon.swift [--probe]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let src = "Resources/AppIcon-source.png"
let dst = "Resources/AppIcon.png"

func load(_ path: String) -> (w: Int, h: Int, px: [UInt8]) {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(s, 0, nil)
    else { fatalError("không đọc được \(path)") }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
        data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, px)
}

func report(_ name: String, _ d: (w: Int, h: Int, px: [UInt8])) {
    for (x, y) in [(0, 0), (d.w / 2, 0), (d.w / 2, d.h / 2), (d.w - 1, d.h - 1)] {
        let i = (y * d.w + x) * 4
        print("\(name) (\(x),\(y)) RGBA = \(d.px[i]),\(d.px[i+1]),\(d.px[i+2]),\(d.px[i+3])")
    }
}

var d = load(src)
report("trước", d)
let w = d.w, h = d.h
// Ngưỡng: pixel "nền ngoài" là gần đen, nối với mép ảnh. Viền xám của ô (>~25) chặn flood fill.
let lo = 6, hi = 26
func lum(_ i: Int) -> Int { max(Int(d.px[i * 4]), Int(d.px[i * 4 + 1]), Int(d.px[i * 4 + 2])) }
var outside = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
func push(_ x: Int, _ y: Int) {
    let i = y * w + x
    if !outside[i] && lum(i) < hi { outside[i] = true; stack.append(i) }
}
for x in 0..<w { push(x, 0); push(x, h - 1) }
for y in 0..<h { push(0, y); push(w - 1, y) }
while let i = stack.popLast() {
    let x = i % w, y = i / w
    if x > 0 { push(x - 1, y) }
    if x < w - 1 { push(x + 1, y) }
    if y > 0 { push(x, y - 1) }
    if y < h - 1 { push(x, y + 1) }
}
// Alpha mềm ở rìa: pixel ngoài có độ sáng lo...hi giữ một phần alpha (khử răng cưa).
for i in 0..<(w * h) where outside[i] {
    let l = lum(i)
    let a = l <= lo ? 0.0 : Double(l - lo) / Double(hi - lo)
    let af = a
    d.px[i * 4 + 3] = UInt8(max(0, min(255, af * 255)))
    // premultiplied: nhân màu theo alpha
    for c in 0..<3 { d.px[i * 4 + c] = UInt8(Double(d.px[i * 4 + c]) * af) }
}
report("sau", d)
if CommandLine.arguments.contains("--probe") { exit(0) }

let ctx = CGContext(
    data: &d.px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: dst) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("không ghi được \(dst)") }
print("Đã ghi \(dst)")
