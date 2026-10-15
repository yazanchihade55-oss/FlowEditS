import AVKit
import Photos
import PhotosUI
import SwiftUI

struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { r in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(r.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: r.file, to: copy)
            return Movie(url: copy)
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var settings = EffectSettings() { didSet { schedule() } }
    @Published var sourceURL: URL?
    @Published var status = ""
    let player = AVPlayer()
    private var task: Task<Void, Never>?

    func load(_ url: URL) { sourceURL = url; settings = EffectSettings(); schedule() }

    private func schedule() {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { await rebuild() }
        }
    }

    private func rebuild() async {
        guard let url = sourceURL,
              let (comp, vc) = try? await Processor.build(url: url, settings: settings) else { return }
        let item = AVPlayerItem(asset: comp)
        item.videoComposition = vc
        let t = player.currentTime()
        player.replaceCurrentItem(with: item)
        await player.seek(to: t)
    }

    func exportToPhotos() async {
        guard let url = sourceURL else { return }
        status = "Exportiere …"
        do {
            let (comp, vc) = try await Processor.build(url: url, settings: settings)
            let out = try await Processor.export(comp, vc)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: out)
            }
            status = "In Fotos gespeichert ✓"
        } catch { status = "Fehler: \(error.localizedDescription)" }
    }
}

struct EditorView: View {
    @StateObject private var m = EditorModel()
    @State private var pick: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if m.sourceURL != nil {
                    VideoPlayer(player: m.player).frame(height: 300)
                } else {
                    Text("Wähle ein Video").frame(height: 300).frame(maxWidth: .infinity).background(.black.opacity(0.1))
                }
                Form {
                    Section("Schnitt") {
                        row("Start", $m.settings.trimStart, 0...0.95)
                        row("Ende", $m.settings.trimEnd, 0.05...1)
                        row("Tempo", $m.settings.speed, 0.25...4)
                    }
                    Section("Farbe") {
                        row("Helligkeit", $m.settings.brightness, -1...1)
                        row("Kontrast", $m.settings.contrast, 0...2)
                        row("Sättigung", $m.settings.saturation, 0...2)
                    }
                    Section("Effekte") {
                        row("Unschärfe", $m.settings.blur, 0...20)
                        row("Vignette", $m.settings.vignette, 0...2)
                        Toggle("Person freistellen", isOn: $m.settings.removeBackground)
                        Toggle("Chroma Key", isOn: $m.settings.chromaKey)
                        if m.settings.chromaKey {
                            row("Farbton", $m.settings.keyHue, 0...1)
                            row("Toleranz", $m.settings.keyRange, 0.02...0.3)
                        }
                    }
                    if !m.status.isEmpty { Text(m.status).font(.footnote) }
                }
            }
            .navigationTitle("FlowEdit")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { PhotosPicker("Video", selection: $pick, matching: .videos) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export") { Task { await m.exportToPhotos() } }.disabled(m.sourceURL == nil)
                }
            }
            .onChange(of: pick) { item in
                Task { if let mv = try? await item?.loadTransferable(type: Movie.self) { m.load(mv.url) } }
            }
        }
    }

    private func row(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        HStack { Text(title).frame(width: 90, alignment: .leading); Slider(value: v, in: r) }
    }
}
