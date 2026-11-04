// Run with the LongScreenshotStitcher source prepended; see TESTING.md.
// Fixtures use generated pixels only. No window, pasteboard or screen capture.

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let fixtureWidth = 320
let viewport = 400

func generatedPage(height: Int, period: Int? = nil, document: Bool = false) -> CGImage {
    let buffer = CGContext(data: nil, width: fixtureWidth, height: height, bitsPerComponent: 8,
                           bytesPerRow: fixtureWidth * 4, space: space,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                               | CGBitmapInfo.byteOrder32Big.rawValue)!
    let bytes = buffer.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        let row = period.map { y % $0 } ?? y
        for x in 0..<fixtureWidth {
            let p = (y * fixtureWidth + x) * 4
            let n = UInt32(truncatingIfNeeded: row &* 1_098_189 &+ (x / 8) &* 72_457) &* 2_654_435_761
            let line = row / 18
            let ink = row % 18 < 9 && x >= 18 && x < 100 + (line * 79) % 200 && (x + line) % 11 < 8
            let base = UInt8(truncatingIfNeeded: n >> 24)
            bytes[p] = document ? (ink ? 30 : 250) : base
            bytes[p + 1] = document ? (ink ? 42 : 250) : UInt8(truncatingIfNeeded: n >> 16)
            bytes[p + 2] = document ? (ink ? 56 : 250) : UInt8(truncatingIfNeeded: n >> 8)
            bytes[p + 3] = 255
        }
    }
    return buffer.makeImage()!
}

func portion(_ page: CGImage, y: Int, height: Int = viewport) -> CGImage {
    page.cropping(to: CGRect(x: 0, y: y, width: fixtureWidth, height: height))!
}

func rgba(_ image: CGImage) -> Data {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: context.data!, count: image.width * image.height * 4)
}

func rejects(_ error: LongScreenshotError, _ run: () throws -> Void) throws {
    do {
        try run()
        fatalError("Unexpected success; expected \(error)")
    } catch let caught as LongScreenshotError {
        precondition(caught == error, "Expected \(error); received \(caught)")
    }
}

let fixture = generatedPage(height: 1000)
var stitcher = try LongScreenshotStitcher(first: portion(fixture, y: 0))
try rejects(.unchanged) { try stitcher.append(portion(fixture, y: 0)) }
try rejects(.changedSize) { try stitcher.append(portion(fixture, y: 0, height: viewport - 1)) }
try rejects(.noOverlap) { try stitcher.append(portion(fixture, y: 500)) }
precondition(stitcher.height == viewport && stitcher.frameCount == 1)
try stitcher.append(portion(fixture, y: 156))
try stitcher.append(portion(fixture, y: 456)) // Exactly 25% overlap.
let stitched = try stitcher.renderedImage()
precondition(stitcher.height == 856 && stitcher.frameCount == 3)
precondition(rgba(stitched) == rgba(portion(fixture, y: 0, height: 856)))

let repeating = generatedPage(height: 700, period: 32)
var ambiguous = try LongScreenshotStitcher(first: portion(repeating, y: 0))
try rejects(.ambiguous) { try ambiguous.append(portion(repeating, y: 7)) }
precondition(ambiguous.height == viewport && ambiguous.frameCount == 1)

let document = generatedPage(height: 1000, document: true)
var textPage = try LongScreenshotStitcher(first: portion(document, y: 0))
try textPage.append(portion(document, y: 213))
let stitchedText = try textPage.renderedImage()
precondition(textPage.height == 613)
precondition(rgba(stitchedText) == rgba(portion(document, y: 0, height: 613)))

print("长截图组件：像素与方向、25% 重叠、文本页、无变化、无重叠、重复图案、尺寸变化均通过")
