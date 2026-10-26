#if os(macOS)
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import ProjectionMath
import ThreeSixtyEngine

struct MediaFacts: Equatable {
    var width = 0
    var height = 0
    var fps = 30000.0 / 1001.0
    var frameValue: Int64 = 1001
    var frameTimescale: Int32 = 30000
    var duration = 0.0
    var codec = "—"
    var isImage = false
}

struct LibraryItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var subtitle: String
    var isImage: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var library: [LibraryItem] = []
    @Published var libraryFilter: LibraryFilter = .all
    @Published var facts: MediaFacts?
    @Published var fileName = "No clip"
    @Published var view = ViewParams.standard()
    @Published var input = InputParams.sp360Dome()
    @Published var currentTime = 0.0
    @Published var isPlaying = false
    @Published var inPoint: Double?
    @Published var outPoint: Double?
    @Published var calibrating = false
    @Published var spinDegreesPerSecond: Double = 0
    @Published var preset: ExportPreset = .hd
    @Published var codec: VideoCodec = .h264
    @Published var fullQuality = true
    @Published var includeAudio = true
    @Published var useInOut = false
    @Published var stillFormat: StillFormat = .jpeg
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    @Published var exportStatus = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var showAbout = false
    @Published var showJoin = false
    @Published var joinURLs: [URL] = []
    @Published var isRecording = false
    @Published var directorCount = 0
    @Published var backName: String?

    let cancellation = ExportCancellation()
    private var session: PlaybackSession?
    private var savedMode: UnfoldMode?
    private var sourceURL: URL?
    private var backImage: RGBAImage?
    private(set) var backToken = 0
    private var director: [DirectorSample] = []
    private var lastSpin = Date()
    private var blend: ViewBlend?
    private var flingX: Float = 0
    private var flingY: Float = 0
    private var lookWidth: Float = 900
    private var lookHeight: Float = 600

    var duration: Double { facts?.duration ?? 0 }
    var filteredLibrary: [LibraryItem] {
        switch libraryFilter {
        case .all: return library
        case .videos: return library.filter { !$0.isImage }
        case .photos: return library.filter(\.isImage)
        }
    }

    var hud: String {
        let size = facts.map { "\($0.width)×\($0.height) · \(formatFPS($0.fps)) · \(timecode($0.duration)) · \($0.codec)" } ?? "Drop a clip or choose File → Open"
        let aim = "\(view.mode.title) · \(input.mount.title) · Yaw \(deg(view.yaw)) · Pitch \(deg(view.pitch)) · Roll \(deg(view.roll)) · \(zoomLabel)"
        return size + "\n" + aim
    }

    var zoomLabel: String {
        switch view.mode {
        case .dome: return "Dome \(deg(view.domeFOV))"
        case .fisheye: return "Fisheye \(deg(view.fisheyeOutFOV))"
        case .global, .littlePlanet: return String(format: "Scale %.2f", view.planetScale)
        case .panorama: return "Band \(deg(view.panoramaVert))"
        case .ring: return "Ring \(deg(view.ringLatSpan))"
        case .magicFlat: return "Width \(deg(view.magicHoriz))"
        case .throwOut: return String(format: "Bulge %.2f", view.throwScale)
        case .original: return "Source"
        default: return "FOV \(deg(view.fovY))"
        }
    }

    var exportSizeLabel: String {
        let size = frameSize()
        return "\(size.width)×\(size.height)"
    }

    var upscaleNote: String {
        guard let facts else { return "A 1072×1072 fisheye upscales when the export is larger than the source." }
        let size = frameSize()
        if size.width > facts.width || size.height > facts.height {
            return "Source is \(facts.width)×\(facts.height), so \(size.width)×\(size.height) is upscaled."
        }
        return "Export is \(size.width)×\(size.height), within the source."
    }

    var viewerNote: String {
        guard let facts else { return "" }
        guard max(facts.width, facts.height) < 1920 else { return "" }
        return "Source is \(facts.width)×\(facts.height), so full-screen and 4K are upscaled."
    }

    func frameSize(mode: UnfoldMode? = nil) -> (width: Int, height: Int) {
        exportPixelSize(
            mode: mode ?? view.mode,
            preset: preset,
            sourceWidth: facts?.width ?? 0,
            sourceHeight: facts?.height ?? 0
        )
    }

    var frameIndexLabel: String {
        let fps = max(facts?.fps ?? 30, 1)
        let index = Int((currentTime * fps).rounded(.down))
        let total = Int((duration * fps).rounded())
        return "\(timecode(currentTime)) · frame \(max(0, index)) / \(max(total, index))"
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .image, .png, .jpeg, .heic]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if panel.urls.count > 1 { adoptBack(panel.urls[1]) }
        open(url)
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFolder(url)
    }

    func backLensPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .image, .png, .jpeg, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptBack(url)
        if input.mode == .singleFisheye || input.mode == .flat {
            input.mode = .dualTwoFiles
            input.mount = .lensForward
            input.lensA = .dualLeft()
            input.lensB = .dualRight()
            input.lensA.centerX = 0.5
            input.lensB.centerX = 0.5
        }
    }

    func openDropped(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
            loadFolder(first)
            return
        }
        if urls.count > 1 { adoptBack(urls[1]) }
        open(first)
    }

    func open(_ url: URL) {
        isLoading = true
        errorMessage = nil
        sourceURL = url
        fileName = url.lastPathComponent
        Task {
            do {
                let opened = try await PlaybackSession.open(url)
                session = opened
                facts = opened.facts
                currentTime = 0
                inPoint = nil
                outPoint = nil
                isPlaying = false
                director = []
                directorCount = 0
                isRecording = false
                let suggestion = suggestInput(width: opened.facts.width, height: opened.facts.height)
                input = suggestion.makeInput()
                view = suggestion.makeView()
                opened.onTime = { [weak self] time in
                    guard let self else { return }
                    if !self.isPlaying { self.currentTime = time; return }
                    self.currentTime = time
                    if self.isRecording {
                        self.director.append(DirectorSample(time: time, view: self.view))
                        self.directorCount = self.director.count
                    }
                    if let out = self.outPoint, time >= out {
                        self.session?.pause()
                        self.isPlaying = false
                    }
                }
                isLoading = false
            } catch {
                fail(error.localizedDescription)
                isLoading = false
            }
        }
    }

    func loadFolder(_ url: URL) {
        let keys: Set<String> = ["mp4", "mov", "m4v", "png", "jpg", "jpeg", "heic", "tif", "tiff"]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        library = urls
            .filter { keys.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { item in
                let image = ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(item.pathExtension.lowercased())
                return LibraryItem(url: item, subtitle: image ? "Photo" : "Video", isImage: image)
            }
        if library.isEmpty {
            fail("That folder has no videos or photos this app can open.")
        }
    }

    func togglePlay() {
        guard let session else { return }
        if isPlaying { session.pause(); isPlaying = false }
        else { session.play(); isPlaying = true; lastSpin = Date() }
    }

    func step(_ frames: Int) {
        session?.pause()
        isPlaying = false
        let timing = facts.map { FrameTiming(value: $0.frameValue, timescale: $0.frameTimescale) }
            ?? frameTiming(forNominalFPS: 29.97)
        session?.step(frames, timing: timing)
    }

    func jump(to end: Bool) {
        let target = end ? duration : 0
        session?.seek(target)
        currentTime = target
        isPlaying = false
    }

    func seek(_ seconds: Double) {
        let clamped = min(max(0, seconds), max(duration, 0))
        currentTime = clamped
        session?.seek(clamped)
    }

    func markIn() { inPoint = currentTime }
    func markOut() { outPoint = max(currentTime, (inPoint ?? 0) + 0.05) }
    func clearRange() { inPoint = nil; outPoint = nil; useInOut = false }

    func nudge(_ nudge: Nudge) {
        holdMotion()
        view = nudged(view, nudge)
    }

    func drag(dx: Float, dy: Float, viewWidth: Float = 900, viewHeight: Float = 600) {
        blend = nil
        flingX = 0
        flingY = 0
        lookWidth = max(viewWidth, 1)
        lookHeight = max(viewHeight, 1)
        applyLook(dx: dx, dy: dy)
    }

    func fling(dxPerSecond: Float, dyPerSecond: Float) {
        guard !calibrating else { return }
        blend = nil
        flingX = dxPerSecond
        flingY = dyPerSecond
    }

    func zoom(by factor: Float) {
        guard !calibrating else { return }
        blend = nil
        view = zoomed(view, factor: factor)
    }

    func scroll(delta: Float, roll: Bool) {
        if calibrating {
            input.lensA.radius = clampRange(input.lensA.radius + delta * 0.002, 0.15, 0.7)
            return
        }
        blend = nil
        if roll {
            view = nudged(view, .roll(delta * 0.12))
        } else {
            let factor = exp(delta * 0.008)
            view = zoomed(view, factor: factor)
        }
    }

    func holdMotion() {
        blend = nil
        flingX = 0
        flingY = 0
    }

    func tickMotion() {
        let now = Date()
        let dt = Float(min(max(now.timeIntervalSince(lastSpin), 0), 0.05))
        lastSpin = now
        guard dt > 0 else { return }
        if let blend {
            let u = min(1, now.timeIntervalSince(blend.started) / blend.duration)
            let eased = Float(1 - pow(1 - u, 3))
            view = blended(blend.from, blend.to, eased)
            if u >= 1 { self.blend = nil }
            return
        }
        if abs(flingX) > 12 || abs(flingY) > 12 {
            applyLook(dx: flingX * dt, dy: flingY * dt)
            let decay = exp(-2.4 * dt)
            flingX *= decay
            flingY *= decay
        } else {
            flingX = 0
            flingY = 0
        }
        guard abs(spinDegreesPerSecond) > 0.05, !calibrating else { return }
        view.yaw = wrapRadians(view.yaw + (Float(spinDegreesPerSecond) * dt).degreesToRadians)
    }

    func resetView() {
        var target = ViewParams.standard(mode: view.mode)
        target.yaw = 0
        target.pitch = 0
        animate(to: target)
    }

    func apply(preset: LookPreset) {
        animate(to: preset.makeView())
    }

    func setUnfold(_ mode: UnfoldMode) {
        guard view.mode != mode else { return }
        var target = view
        target.mode = mode
        if mode == .extraction {
            target.fovY = 50.degreesToRadians
        } else if mode == .front16x9 || mode == .front4x3 || mode == .seg || mode == .quad, view.mode != mode {
            target.fovY = 100.degreesToRadians
        }
        animate(to: target)
    }

    func setYaw(_ yaw: Float) {
        holdMotion()
        view.yaw = wrapRadians(yaw)
    }

    private func animate(to target: ViewParams) {
        flingX = 0
        flingY = 0
        blend = ViewBlend(from: view, to: target, started: Date(), duration: 0.48)
    }

    private func applyLook(dx: Float, dy: Float) {
        if calibrating {
            input.lensA.centerX = clampRange(input.lensA.centerX + dx, 0.05, 0.95)
            input.lensA.centerY = clampRange(input.lensA.centerY + dy, 0.05, 0.95)
            return
        }
        view = draggedView(view, dx: dx, dy: dy, width: lookWidth, height: lookHeight)
    }

    private func blended(_ from: ViewParams, _ to: ViewParams, _ t: Float) -> ViewParams {
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
        var view = to
        view.yaw = lerpAngle(from.yaw, to.yaw, t)
        view.pitch = mix(from.pitch, to.pitch)
        view.roll = lerpAngle(from.roll, to.roll, t)
        view.fovY = mix(from.fovY, to.fovY)
        view.domeFOV = mix(from.domeFOV, to.domeFOV)
        view.fisheyeOutFOV = mix(from.fisheyeOutFOV, to.fisheyeOutFOV)
        view.planetScale = mix(from.planetScale, to.planetScale)
        view.panoramaHoriz = mix(from.panoramaHoriz, to.panoramaHoriz)
        view.panoramaVert = mix(from.panoramaVert, to.panoramaVert)
        view.magicHoriz = mix(from.magicHoriz, to.magicHoriz)
        view.magicVert = mix(from.magicVert, to.magicVert)
        view.ringInner = mix(from.ringInner, to.ringInner)
        view.ringLat0 = mix(from.ringLat0, to.ringLat0)
        view.ringLatSpan = mix(from.ringLatSpan, to.ringLatSpan)
        view.throwScale = mix(from.throwScale, to.throwScale)
        view.segYawOffset = lerpAngle(from.segYawOffset, to.segYawOffset, t)
        return view
    }

    func resetAdjustments() {
        let mode = input.mode
        input = mode == .equirectangular ? .equirect() : (mode == .dualSideBySide ? .dualSideBySide() : .sp360Dome())
        input.mode = mode
        view = ViewParams.standard(mode: .dome)
        spinDegreesPerSecond = 0
    }

    func setCalibration(_ on: Bool) {
        if on {
            savedMode = view.mode
            view.mode = .original
            calibrating = true
        } else {
            calibrating = false
            if let savedMode { view.mode = savedMode }
        }
    }

    func rotateVideo(turns: Int) { input.userQuarterTurns = turns }

    func toggleRecording() {
        if isRecording {
            isRecording = false
            session?.pause()
            isPlaying = false
            if director.count > 1 { exportView(useDirector: true) }
            else { fail("Record a little longer so the path has more than one sample.") }
        } else {
            director = [DirectorSample(time: currentTime, view: view)]
            directorCount = 1
            isRecording = true
            session?.play()
            isPlaying = true
        }
    }

    func pullFrame() -> CVPixelBuffer? { session?.pullFrame() }
    func currentBackImage() -> RGBAImage? { backImage }
    var backGeneration: Int { backToken }

    func exportStill() {
        guard facts != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [stillFormat == .png ? .png : .jpeg]
        panel.nameFieldStringValue = baseName() + (stillFormat == .png ? ".png" : ".jpg")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let buffer = pullFrame() else { fail("No frame is ready yet."); return }
        let source = readRGBA(buffer)
        let size = frameSize()
        let image = renderFrame(
            source: source, back: backImage, view: view, input: input,
            outputWidth: size.width, outputHeight: size.height, showCalibration: calibrating
        )
        do {
            try MovieExporter.writeStill(image, to: url, format: stillFormat, jpegQuality: 0.92)
            exportStatus = "Saved \(url.lastPathComponent)"
        } catch { fail(error.localizedDescription) }
    }

    func exportView(useDirector: Bool = false) {
        guard let sourceURL, facts?.isImage == false else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = baseName() + (useDirector ? "-path.mp4" : "-view.mp4")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = frameSize()
        let job = ExportJob(
            outputURL: url, width: size.width, height: size.height, codec: codec,
            includeAudio: includeAudio, useMetal: true, view: view, input: input,
            director: useDirector ? director : [], showCalibration: calibrating,
            fileURL: sourceURL, rangeStart: useInOut ? inPoint : nil, rangeEnd: useInOut ? outPoint : nil,
            backImage: backImage
        )
        runExport(job, label: useDirector ? "Recording the view path" : "Exporting the current view")
    }

    func exportYouTube() {
        guard let sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = baseName() + "-360.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let youtube = preset.forcedEquirect == nil ? ExportPreset.youtube4k : preset
        let size = exportPixelSize(mode: .equirect, preset: youtube, sourceWidth: facts?.width ?? 0, sourceHeight: facts?.height ?? 0)
        var oriented = view
        oriented.mode = .equirect
        let frames: [RGBAImage]
        let file: URL?
        if facts?.isImage == true, let buffer = pullFrame() {
            frames = [readRGBA(buffer)]
            file = nil
        } else {
            frames = []
            file = sourceURL
        }
        let job = ExportJob(
            outputURL: url, width: size.width, height: size.height, codec: codec,
            includeAudio: includeAudio && file != nil, injectSpherical: true, useMetal: true,
            view: oriented, input: input, showCalibration: false, fileURL: file,
            rangeStart: useInOut ? inPoint : nil, rangeEnd: useInOut ? outPoint : nil,
            backImage: backImage, sequenceFPS: 30, sequenceFrames: frames.isEmpty ? [] : Array(repeating: frames[0], count: 30)
        )
        runExport(job, label: "Converting to equirectangular 360")
    }

    func trimOriginal() {
        guard let sourceURL, facts?.isImage == false else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = baseName() + "-trim.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        exportProgress = 0.2
        exportStatus = "Trimming the original file"
        Task {
            do {
                try await MovieExporter.trim(source: sourceURL, start: useInOut ? inPoint : nil, end: useInOut ? outPoint : nil, output: url)
                exportStatus = "Saved \(url.lastPathComponent)"
                exportProgress = 1
            } catch { fail(error.localizedDescription) }
            isExporting = false
        }
    }

    func exportStillsAsVideo() {
        let photos = library.filter(\.isImage)
        guard !photos.isEmpty else { fail("Open a folder that contains photos first."); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "stills.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        exportStatus = "Building a video from photos"
        Task {
            do {
                var frames: [RGBAImage] = []
                for photo in photos {
                    let image = try MovieExporter.loadImage(photo.url)
                    frames.append(contentsOf: Array(repeating: image, count: 60))
                }
                let size = frameSize()
                let job = ExportJob(
                    outputURL: url, width: size.width, height: size.height, codec: codec,
                    includeAudio: false, useMetal: true, view: view, input: input,
                    sequenceFPS: 30, sequenceFrames: frames
                )
                try await MovieExporter.export(job, cancel: cancellation) { [weak self] value in
                    Task { @MainActor in self?.exportProgress = value }
                }
                exportStatus = "Saved \(url.lastPathComponent)"
            } catch { fail(error.localizedDescription) }
            isExporting = false
        }
    }

    func joinSelected() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "joined.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let urls = joinURLs
        showJoin = false
        isExporting = true
        exportStatus = "Joining clips"
        Task {
            do {
                try await MovieExporter.join(urls: urls, output: url)
                exportStatus = "Saved \(url.lastPathComponent)"
                exportProgress = 1
            } catch { fail(error.localizedDescription) }
            isExporting = false
        }
    }

    func cancelExport() { cancellation.cancel(); exportStatus = "Cancelling…" }

    func fail(_ message: String) {
        errorMessage = message
        showError = true
        exportStatus = message
    }

    private func runExport(_ job: ExportJob, label: String) {
        cancellation.reset()
        isExporting = true
        exportProgress = 0
        exportStatus = label
        Task {
            do {
                try await MovieExporter.export(job, cancel: cancellation) { [weak self] value in
                    Task { @MainActor in
                        self?.exportProgress = value
                        self?.exportStatus = "\(label) · \(Int(value * 100))%"
                    }
                }
                exportStatus = "Saved \(job.outputURL.lastPathComponent)"
            } catch {
                fail(error.localizedDescription)
            }
            isExporting = false
        }
    }

    private func adoptBack(_ url: URL) {
        let imageExtensions = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            if let image = try? MovieExporter.loadImage(url) {
                backImage = image
                backToken += 1
                backName = url.lastPathComponent
            }
        } else {
            backName = url.lastPathComponent + " (use a still, or a side-by-side file)"
        }
    }

    private func baseName() -> String {
        sourceURL?.deletingPathExtension().lastPathComponent ?? "export"
    }
}

struct LookPreset: Equatable {
    var id: String
    var title: String
    var symbol: String
    var detail: String
    var mode: UnfoldMode
    var yaw: Float
    var pitch: Float
    var fovY: Float?

    func makeView() -> ViewParams {
        var view = ViewParams.standard(mode: mode)
        view.yaw = yaw
        view.pitch = pitch
        view.roll = 0
        if let fovY { view.fovY = fovY }
        return view
    }

    func matches(_ view: ViewParams) -> Bool {
        guard view.mode == mode else { return false }
        let yawGap = abs(wrapRadians(view.yaw - yaw))
        let pitchGap = abs(view.pitch - pitch)
        let yawLimit: Float = mode == .littlePlanet || mode == .ring || mode == .equirect ? 0.35 : 0.18
        return yawGap < yawLimit && pitchGap < 0.18
    }

    static let gallery: [LookPreset] = [
        LookPreset(id: "front", title: "Front", symbol: "video.fill", detail: "Driver view, looking forward", mode: .front16x9, yaw: 0, pitch: 0, fovY: 100.degreesToRadians),
        LookPreset(id: "rear", title: "Rear", symbol: "arrow.uturn.backward", detail: "Look behind the camera", mode: .front16x9, yaw: .pi, pitch: 0, fovY: 100.degreesToRadians),
        LookPreset(id: "left", title: "Left", symbol: "arrow.left", detail: "Look to the left", mode: .front16x9, yaw: -.pi / 2, pitch: 0, fovY: 100.degreesToRadians),
        LookPreset(id: "right", title: "Right", symbol: "arrow.right", detail: "Look to the right", mode: .front16x9, yaw: .pi / 2, pitch: 0, fovY: 100.degreesToRadians),
        LookPreset(id: "sky", title: "Sky", symbol: "sun.max.fill", detail: "Look up", mode: .front16x9, yaw: 0, pitch: 72.degreesToRadians, fovY: 110.degreesToRadians),
        LookPreset(id: "planet", title: "Tiny Planet", symbol: "globe", detail: "Little planet", mode: .littlePlanet, yaw: 0, pitch: 0, fovY: nil),
        LookPreset(id: "equirect", title: "Panorama 360", symbol: "pano", detail: "Full equirectangular sphere", mode: .equirect, yaw: 0, pitch: 0, fovY: nil),
        LookPreset(id: "split", title: "Split", symbol: "rectangle.split.2x1", detail: "Front and rear side by side", mode: .seg, yaw: 0, pitch: 0, fovY: 100.degreesToRadians),
        LookPreset(id: "ring", title: "Ring", symbol: "circle.circle", detail: "Panorama strip around the horizon", mode: .ring, yaw: 0, pitch: 0, fovY: nil),
    ]
}

private struct ViewBlend {
    var from: ViewParams
    var to: ViewParams
    var started: Date
    var duration: TimeInterval
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, videos, photos
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .videos: return "Video"
        case .photos: return "Photo"
        }
    }
}

func deg(_ radians: Float) -> String {
    String(format: "%.1f°", wrapDegrees(radians.radiansToDegrees))
}

func timecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
    let total = Int(seconds)
    let tenths = Int((seconds - Double(total)) * 10)
    return String(format: "%02d:%02d.%d", total / 60, total % 60, tenths)
}

private func formatFPS(_ fps: Double) -> String {
    fps < 1 ? "still" : String(format: "%.2g fps", fps)
}

@MainActor
final class PlaybackSession {
    let facts: MediaFacts
    private let player: AVPlayer?
    private let output: AVPlayerItemVideoOutput?
    private var observer: Any?
    private var latest: CVPixelBuffer?
    var onTime: ((Double) -> Void)?

    init(facts: MediaFacts, player: AVPlayer?, output: AVPlayerItemVideoOutput?, latest: CVPixelBuffer?) {
        self.facts = facts
        self.player = player
        self.output = output
        self.latest = latest
    }

    static func open(_ url: URL) async throws -> PlaybackSession {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), !type.conforms(to: .movie) {
            let image = try MovieExporter.loadImage(url)
            guard let buffer = makePixelBuffer(width: image.width, height: image.height, metal: true) else {
                throw ExportFailure.image("Couldn't prepare \(url.lastPathComponent)")
            }
            writeBGRA(image, into: buffer)
            return PlaybackSession(
                facts: MediaFacts(width: image.width, height: image.height, fps: 0, duration: 0, codec: url.pathExtension.uppercased(), isImage: true),
                player: nil, output: nil, latest: buffer
            )
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportFailure.noVideo }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let width = Int(abs(rect.width).rounded())
        let height = Int(abs(rect.height).rounded())
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let codec = fourCC(try await track.load(.formatDescriptions).first)
        let minFrame = try await track.load(.minFrameDuration)
        let timing = (minFrame.isValid && minFrame.seconds > 0.001 && minFrame.seconds < 0.5)
            ? FrameTiming(value: minFrame.value, timescale: minFrame.timescale)
            : frameTiming(forNominalFPS: fps > 1 ? fps : 29.97)
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let preview = (try? generator.copyCGImage(at: .zero, actualTime: nil)).flatMap(pixelBuffer(from:))
        let session = PlaybackSession(
            facts: MediaFacts(
                width: max(width, 1), height: max(height, 1), fps: fps,
                frameValue: timing.value, frameTimescale: timing.timescale,
                duration: duration, codec: codec, isImage: false
            ),
            player: player, output: output, latest: preview
        )
        session.observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            Task { @MainActor in session.onTime?(time.seconds) }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            Task { @MainActor in
                player.pause()
                session.onTime?(duration)
            }
        }
        player.pause()
        return session
    }

    func play() { player?.play() }
    func pause() { player?.pause() }
    func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ frames: Int, timing: FrameTiming) {
        guard let player else { return }
        pause()
        let delta = CMTime(value: timing.value * Int64(frames), timescale: timing.timescale)
        let target = CMTimeAdd(player.currentTime(), delta)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pullFrame() -> CVPixelBuffer? {
        guard let output else { return latest }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            latest = buffer
        }
        return latest
    }
}

private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let rgba = RGBAImage(width: width, height: height, rgba: pixels)
    guard let buffer = makePixelBuffer(width: width, height: height, metal: true) else { return nil }
    writeBGRA(rgba, into: buffer)
    return buffer
}

extension AppModel {
    func handleKey(_ code: UInt16) {
        switch code {
        case 49: togglePlay()
        case 123: nudge(.yaw(-4))
        case 124: nudge(.yaw(4))
        case 126: nudge(.pitch(4))
        case 125: nudge(.pitch(-4))
        case 34: markIn()
        case 31: markOut()
        case 24: view = zoomed(view, factor: 1.08 as Float)
        case 27: view = zoomed(view, factor: 0.92 as Float)
        default: break
        }
    }
}

private func fourCC(_ description: CMFormatDescription?) -> String {
    guard let description else { return "—" }
    let code = CMFormatDescriptionGetMediaSubType(description)
    let bytes = [
        UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
    ]
    let text = String(bytes: bytes, encoding: .ascii) ?? "—"
    return text.trimmingCharacters(in: .whitespaces)
}
#endif
