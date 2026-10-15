import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

enum Processor {
    static let ctx = CIContext()

    // Baut Komposition (Trim + Tempo) und Effekt-Pipeline
    static func build(url: URL, settings s: EffectSettings) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let start = CMTimeMultiplyByFloat64(duration, multiplier: s.trimStart)
        let end = CMTimeMultiplyByFloat64(duration, multiplier: max(s.trimEnd, s.trimStart + 0.01))
        let range = CMTimeRange(start: start, end: end)

        let comp = AVMutableComposition()
        try comp.insertTimeRange(range, of: asset, at: .zero)
        if s.speed != 1 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                                toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / s.speed))
        }

        let cube = s.chromaKey ? chromaCube(hue: s.keyHue, range: s.keyRange) : nil
        let vc = AVMutableVideoComposition(asset: comp) { req in
            req.finish(with: apply(s, cube: cube, to: req.sourceImage), context: ctx)
        }
        return (comp, vc)
    }

    static func apply(_ s: EffectSettings, cube: Data?, to input: CIImage) -> CIImage {
        let extent = input.extent
        var img = input

        if s.removeBackground, let m = removeBG(img) { img = m }

        if let cube {
            let f = CIFilter(name: "CIColorCube")!
            f.setValue(32, forKey: "inputCubeDimension")
            f.setValue(cube, forKey: "inputCubeData")
            f.setValue(img, forKey: kCIInputImageKey)
            img = f.outputImage ?? img
        }

        let cc = CIFilter.colorControls()
        cc.inputImage = img
        cc.brightness = Float(s.brightness)
        cc.contrast = Float(s.contrast)
        cc.saturation = Float(s.saturation)
        img = cc.outputImage ?? img

        if s.blur > 0 {
            let b = CIFilter.gaussianBlur()
            b.inputImage = img.clampedToExtent()
            b.radius = Float(s.blur)
            img = b.outputImage ?? img
        }
        if s.vignette > 0 {
            let v = CIFilter.vignette()
            v.inputImage = img
            v.intensity = Float(s.vignette)
            v.radius = 2
            img = v.outputImage ?? img
        }

        let bg = CIImage(color: .black).cropped(to: extent)
        return img.composited(over: bg).cropped(to: extent)
    }

    // Personen-Freistellung mit Apples Vision-Framework
    static func removeBG(_ img: CIImage) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(ciImage: img).perform([req])
        guard let buf = req.results?.first?.pixelBuffer else { return nil }
        var mask = CIImage(cvPixelBuffer: buf)
        mask = mask.transformed(by: CGAffineTransform(scaleX: img.extent.width / mask.extent.width,
                                                      y: img.extent.height / mask.extent.height))
        let f = CIFilter.blendWithMask()
        f.inputImage = img
        f.backgroundImage = CIImage(color: .clear).cropped(to: img.extent)
        f.maskImage = mask
        return f.outputImage
    }

    // Chroma-Key als Farbwürfel: Pixel mit passendem Farbton werden transparent
    static func chromaCube(hue: Double, range: Double) -> Data {
        let n = 32
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let rf = CGFloat(r) / CGFloat(n - 1), gf = CGFloat(g) / CGFloat(n - 1), bf = CGFloat(b) / CGFloat(n - 1)
            var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0
            UIColor(red: rf, green: gf, blue: bf, alpha: 1).getHue(&h, saturation: &sat, brightness: &v, alpha: nil)
            let hit = abs(Double(h) - hue) < range && sat > 0.25 && v > 0.15
            let a: Float = hit ? 0 : 1
            cube[i] = Float(rf) * a; cube[i + 1] = Float(gf) * a; cube[i + 2] = Float(bf) * a; cube[i + 3] = a
            i += 4
        }}}
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func export(_ comp: AVMutableComposition, _ vc: AVMutableVideoComposition) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("flowedit-\(UUID().uuidString).mp4")
        guard let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "FlowEdit", code: 1)
        }
        s.outputURL = out
        s.outputFileType = .mp4
        s.videoComposition = vc
        await withCheckedContinuation { c in s.exportAsynchronously { c.resume() } }
        if s.status != .completed { throw s.error ?? NSError(domain: "FlowEdit", code: 2) }
        return out
    }
}
