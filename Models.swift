import Foundation

struct EffectSettings: Equatable {
    var brightness = 0.0      // -1...1
    var contrast = 1.0        // 0...2
    var saturation = 1.0      // 0...2
    var blur = 0.0            // 0...20
    var vignette = 0.0        // 0...2
    var chromaKey = false
    var keyHue = 0.33         // 0.33 = grün, 0.66 = blau
    var keyRange = 0.10
    var removeBackground = false   // Personen-Freistellung (Vision)
    var speed = 1.0           // 0.25...4
    var trimStart = 0.0       // Anteil 0...1
    var trimEnd = 1.0
}
