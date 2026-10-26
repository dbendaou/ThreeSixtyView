#if os(macOS)
import AppKit
import Combine
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import UniformTypeIdentifiers
import ProjectionMath
import ThreeSixtyEngine

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let model = AppModel()
    private var subscriptions = Set<AnyCancellable>()
    private var motionTimer: Timer?
    private var hideChrome: DispatchWorkItem?
    private let libraryTable = NSTableView()
    private let filterControl = NSSegmentedControl()
    private let nameLabel = NSTextField(labelWithString: "ThreeSixtyView")
    private let metaLabel = NSTextField(labelWithString: "Drop a square fisheye or a 2:1 equirectangular clip")
    private let aimLabel = NSTextField(labelWithString: "")
    private let upscaleHint = NSTextField(wrappingLabelWithString: "")
    private let qualityCheck = NSButton(checkboxWithTitle: "Full quality", target: nil, action: nil)
    private let exportNote = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "00:00.0")
    private let durationLabel = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyTitle = NSTextField(labelWithString: "Drop a 360 clip")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "Square video opens as a 225° fisheye, ceiling-mounted, looking forward. A 2:1 frame opens as a panorama.")
    private let spinner = NSProgressIndicator()
    private let scrubber = NSSlider()
    private let playButton = SymbolButton(symbol: "play.fill", tooltip: "Play (space)", pointSize: 16)
    private let modeControl = NSSegmentedControl()
    private let projectionPopup = NSPopUpButton()
    private let mountPopup = NSPopUpButton()
    private let unfoldPopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let codecPopup = NSPopUpButton()
    private let stillPopup = NSPopUpButton()
    private let audioCheck = NSButton(checkboxWithTitle: "Include audio", target: nil, action: nil)
    private let useInOut = NSButton(checkboxWithTitle: "Use in and out points", target: nil, action: nil)
    private let sharpCheck = NSButton(checkboxWithTitle: "Unsharp mask", target: nil, action: nil)
    private let calibrateCheck = NSButton(checkboxWithTitle: "Calibration circle", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let sheetProgress = NSProgressIndicator()
    private let sheetStatus = NSTextField(wrappingLabelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var sliders: [String: NSSlider] = [:]
    private var valueLabels: [String: NSTextField] = [:]
    private let fisheyeBox = NSStackView()
    private let dualBox = NSStackView()
    private let sharpBox = NSStackView()
    private let rotationButtons = ["0°", "90°", "180°", "270°"].map { NSButton(title: $0, target: nil, action: nil) }
    private let factsLabel = NSTextField(wrappingLabelWithString: "No clip open")
    private var recordButton: NSButton!
    private var cancelExportButton: NSButton!
    private var viewer: ViewerMTKView!
    private var coordinator: ViewerCoordinator!
    private var chrome: ClickThroughView!
    private var presetRow: NSStackView!
    private var cards: [String: PresetCard] = [:]
    private var compass: CompassDial!
    private var inspectorWidth: NSLayoutConstraint!
    private var inspectorOpen = false
    private var exportSheet: NSWindow?
    private var thumbToken = 0
    private var thumbKey = ""
    private var libraryURLs: [URL] = []
    private let quickModes: [(String, UnfoldMode)] = [
        ("Front", .front16x9),
        ("Dome", .dome),
        ("360", .equirect),
        ("Ring", .ring),
        ("Planet", .littlePlanet),
    ]

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ThreeSixtyView"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 880, height: 620)
        window.setFrameAutosaveName("ThreeSixtyViewMain")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 1)
        self.init(window: window)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        build()
        bind()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        viewer = ViewerMTKView(frame: .zero)
        viewer.device = MTLCreateSystemDefaultDevice()
        viewer.colorPixelFormat = MetalRenderer.colorFormat
        viewer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        viewer.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.022, alpha: 1)
        viewer.framebufferOnly = true
        viewer.autoResizeDrawable = false
        viewer.prepareStableLayer()
        viewer.isPaused = false
        viewer.enableSetNeedsDisplay = false
        viewer.preferredFramesPerSecond = 60
        coordinator = ViewerCoordinator(model: model)
        viewer.delegate = coordinator
        viewer.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            self.model.drag(dx: dx, dy: dy, viewWidth: Float(self.viewer.bounds.width), viewHeight: Float(self.viewer.bounds.height))
        }
        viewer.onFling = { [weak self] dx, dy in self?.model.fling(dxPerSecond: dx, dyPerSecond: dy) }
        viewer.onScroll = { [weak self] delta, option in
            let scale: Float = 1
            self?.model.scroll(delta: delta * scale, roll: option)
        }
        viewer.onZoom = { [weak self] factor in self?.model.zoom(by: factor) }
        viewer.onReset = { [weak self] in self?.model.resetView() }
        viewer.onKey = { [weak self] code in self?.model.handleKey(code) }
        viewer.onDropURLs = { [weak self] urls in self?.model.openDropped(urls) }
        viewer.onActivity = { [weak self] in self?.revealChrome() }

        emptyTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        emptyTitle.textColor = .white
        emptyDetail.font = .systemFont(ofSize: 13)
        emptyDetail.textColor = NSColor.white.withAlphaComponent(0.72)
        emptyDetail.alignment = .center
        emptyDetail.maximumNumberOfLines = 3
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isDisplayedWhenStopped = false
        let emptyCard = glass(20)
        let emptyStack = NSStackView(views: [emptyTitle, emptyDetail])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        emptyStack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        emptyCard.addSubview(emptyStack)
        pin(emptyStack, to: emptyCard)

        content.addSubview(viewer)
        pin(viewer, to: content)
        content.addSubview(emptyCard)
        content.addSubview(spinner)
        emptyCard.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyCard.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyCard.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyCard.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        chrome = ClickThroughView()
        content.addSubview(chrome)
        pin(chrome, to: content)

        let top = shadowWrap(infoCapsule(), radius: 22)
        let modes = shadowWrap(modeCapsule(), radius: 18)
        let presets = presetStrip()
        let transport = shadowWrap(transportCapsule(), radius: 26)
        compass = CompassDial()
        compass.toolTip = "Drag to change heading"
        compass.onHeading = { [weak self] yaw in self?.model.setYaw(yaw) }
        let dial = glass(32)
        dial.addSubview(compass)
        pin(compass, to: dial)
        let compassWrap = shadowWrap(dial, radius: 32)
        chrome.addSubview(top)
        chrome.addSubview(modes)
        chrome.addSubview(presets)
        chrome.addSubview(transport)
        chrome.addSubview(compassWrap)
        top.translatesAutoresizingMaskIntoConstraints = false
        modes.translatesAutoresizingMaskIntoConstraints = false
        presets.translatesAutoresizingMaskIntoConstraints = false
        transport.translatesAutoresizingMaskIntoConstraints = false
        compassWrap.translatesAutoresizingMaskIntoConstraints = false

        let guide = window!.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 20),
            top.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            top.widthAnchor.constraint(lessThanOrEqualTo: chrome.widthAnchor, multiplier: 0.36),
            modes.centerXAnchor.constraint(equalTo: chrome.centerXAnchor),
            modes.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            presets.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 16),
            presets.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -16),
            presets.bottomAnchor.constraint(equalTo: transport.topAnchor, constant: -12),
            transport.leadingAnchor.constraint(equalTo: compassWrap.trailingAnchor, constant: 12),
            transport.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -18),
            transport.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -18),
            compassWrap.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 18),
            compassWrap.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            compassWrap.widthAnchor.constraint(equalToConstant: 64),
            compassWrap.heightAnchor.constraint(equalToConstant: 64),
        ])

        let inspector = buildInspector()
        content.addSubview(inspector)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            inspector.topAnchor.constraint(equalTo: content.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspectorWidth,
        ])

        let tools = toolCluster()
        chrome.addSubview(tools)
        tools.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tools.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -18),
            tools.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
        ])

        buildExportSheet()
        revealChrome(sticky: true)
        refresh()
    }

    private func bind() {
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.model.tickMotion()
        }
    }

    private func infoCapsule() -> NSView {
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        metaLabel.lineBreakMode = .byTruncatingTail
        aimLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        aimLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        upscaleHint.font = .systemFont(ofSize: 11)
        upscaleHint.textColor = NSColor.white.withAlphaComponent(0.62)
        upscaleHint.maximumNumberOfLines = 2
        qualityCheck.font = .systemFont(ofSize: 11, weight: .medium)
        qualityCheck.contentTintColor = .white
        qualityCheck.toolTip = "Draw at the full Retina size of the window with Catmull-Rom sampling. Turn it off to draw at point size while the window is moving."
        wire(qualityCheck, #selector(qualityToggled(_:)))
        let column = NSStackView(views: [nameLabel, metaLabel, aimLabel, qualityCheck, upscaleHint])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        let capsule = glass(22)
        capsule.addSubview(column)
        pin(column, to: capsule)
        return capsule
    }

    private func modeCapsule() -> NSView {
        modeControl.segmentCount = quickModes.count
        modeControl.segmentStyle = .separated
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .regular
        for (index, item) in quickModes.enumerated() {
            modeControl.setLabel(item.0, forSegment: index)
            modeControl.setWidth(58, forSegment: index)
        }
        modeControl.target = self
        modeControl.action = #selector(quickMode(_:))
        modeControl.toolTip = "View mode"
        let host = glass(18)
        host.addSubview(modeControl)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
            modeControl.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -6),
            modeControl.topAnchor.constraint(equalTo: host.topAnchor, constant: 4),
            modeControl.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -4),
        ])
        return host
    }

    private func presetStrip() -> NSView {
        presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.spacing = 10
        presetRow.alignment = .centerY
        for preset in LookPreset.gallery {
            let card = PresetCard(preset: preset)
            card.onPick = { [weak self] chosen in
                self?.revealChrome()
                self?.model.apply(preset: chosen)
                self?.focusPicture()
            }
            cards[preset.id] = card
            presetRow.addArrangedSubview(card)
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = presetRow
        presetRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            presetRow.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            presetRow.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            presetRow.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            presetRow.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
        scroll.heightAnchor.constraint(equalToConstant: 108).isActive = true
        return scroll
    }

    private func transportCapsule() -> NSView {
        playButton.toolTip = "Play or pause (space)"
        playButton.target = self
        playButton.action = #selector(togglePlay(_:))
        playButton.layer?.cornerRadius = 21
        let start = symbol("backward.end.fill", "Go to start", #selector(jumpStart(_:)))
        let back = symbol("backward.frame.fill", "Previous frame", #selector(stepBack(_:)))
        let forward = symbol("forward.frame.fill", "Next frame", #selector(stepForward(_:)))
        let end = symbol("forward.end.fill", "Go to end", #selector(jumpEnd(_:)))
        let markIn = symbol("arrow.right.to.line", "Mark in (I)", #selector(markIn(_:)))
        let markOut = symbol("arrow.left.to.line", "Mark out (O)", #selector(markOut(_:)))
        scrubber.minValue = 0
        scrubber.maxValue = 1
        scrubber.target = self
        scrubber.action = #selector(scrubbed(_:))
        scrubber.isContinuous = true
        scrubber.controlSize = .small
        scrubber.toolTip = "Drag to scrub"
        scrubber.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrubber.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .white
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        rangeLabel.font = .systemFont(ofSize: 10)
        rangeLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        statusLabel.lineBreakMode = .byTruncatingTail
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        let times = NSStackView(views: [timeLabel, durationLabel])
        times.orientation = .horizontal
        times.spacing = 6
        let readouts = NSStackView(views: [times, rangeLabel, statusLabel, progress])
        readouts.orientation = .vertical
        readouts.alignment = .leading
        readouts.spacing = 2
        let row = NSStackView(views: [start, back, playButton, forward, end, scrubber, readouts, markIn, markOut])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 14)
        scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let capsule = glass(26)
        capsule.addSubview(row)
        pin(row, to: capsule)
        return capsule
    }

    private func toolCluster() -> NSView {
        let snap = symbol("camera.fill", "Save a still", #selector(exportStill(_:)))
        let export = symbol("square.and.arrow.up", "Export", #selector(showExport(_:)))
        let adjust = symbol("slider.horizontal.3", "Adjustments", #selector(toggleInspector(_:)))
        let reset = symbol("arrow.counterclockwise", "Reset view (double-click the picture)", #selector(resetView(_:)))
        let row = NSStackView(views: [reset, snap, export, adjust])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func buildInspector() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let body = NSStackView(views: [
            section("Library"),
            libraryBlock(),
            section("Picture info"),
            fileFacts(),
            section("Input"),
            inputBlock(),
            section("Look"),
            lookBlock(),
            section("Grade"),
            gradeBlock(),
        ])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 36, left: 16, bottom: 24, right: 16)
        scroll.documentView = body
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -16).isActive = true
        effect.addSubview(scroll)
        pin(scroll, to: effect)
        return effect
    }

    private func libraryBlock() -> NSView {
        libraryTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        libraryTable.headerView = nil
        libraryTable.dataSource = self
        libraryTable.delegate = self
        libraryTable.rowHeight = 28
        libraryTable.backgroundColor = .clear
        libraryTable.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = libraryTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        filterControl.segmentCount = LibraryFilter.allCases.count
        for (index, filter) in LibraryFilter.allCases.enumerated() {
            filterControl.setLabel(filter.title, forSegment: index)
        }
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        filterControl.controlSize = .small
        let folder = NSButton(title: "Open Folder…", target: self, action: #selector(openFolder(_:)))
        folder.bezelStyle = .rounded
        folder.controlSize = .small
        let column = NSStackView(views: [filterControl, scroll, folder])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func fileFacts() -> NSView {
        factsLabel.font = .systemFont(ofSize: 12)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.maximumNumberOfLines = 3
        return factsLabel
    }

    private func inputBlock() -> NSView {
        fill(projectionPopup, InputMode.allCases.map(\.title), #selector(projectionChanged(_:)))
        fill(mountPopup, MountOrientation.allCases.map(\.title), #selector(mountChanged(_:)))
        fill(unfoldPopup, UnfoldMode.allCases.map(\.title), #selector(unfoldPicked(_:)))
        let rotations = NSStackView()
        rotations.orientation = .horizontal
        rotations.spacing = 6
        for (index, button) in rotationButtons.enumerated() {
            button.tag = index
            button.toolTip = "\(index * 90)° video rotation"
            button.target = self
            button.action = #selector(rotate(_:))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.pushOnPushOff)
            rotations.addArrangedSubview(button)
        }
        wire(calibrateCheck, #selector(calibrateToggled(_:)))
        fisheyeBox.orientation = .vertical
        fisheyeBox.alignment = .leading
        fisheyeBox.spacing = 4
        fisheyeBox.addArrangedSubview(sliderRow("Lens FOV", "fov", 120, 250))
        fisheyeBox.addArrangedSubview(sliderRow("Radius", "radius", 0.2, 0.7))
        fisheyeBox.addArrangedSubview(sliderRow("Center X", "cx", 0, 1))
        fisheyeBox.addArrangedSubview(sliderRow("Center Y", "cy", 0, 1))
        dualBox.orientation = .vertical
        dualBox.alignment = .leading
        dualBox.spacing = 4
        dualBox.addArrangedSubview(sliderRow("Back yaw", "backYaw", 90, 270))
        dualBox.addArrangedSubview(sliderRow("Blend", "blend", 0, 40))
        let back = NSButton(title: "Add Back Lens…", target: self, action: #selector(addBackLens(_:)))
        back.bezelStyle = .rounded
        back.controlSize = .small
        dualBox.addArrangedSubview(back)
        let column = NSStackView(views: [
            muted("Projection"), projectionPopup,
            muted("Mount"), mountPopup,
            muted("Unfold"), unfoldPopup,
            muted("Video rotation"), rotations,
            calibrateCheck, fisheyeBox, dualBox,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        projectionPopup.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func lookBlock() -> NSView {
        let column = NSStackView(views: [
            sliderRow("Yaw", "yaw", -180, 180),
            sliderRow("Pitch", "pitch", -89, 89),
            sliderRow("Roll", "roll", -180, 180),
            sliderRow("Zoom", "zoom", 10, 140),
            sliderRow("Auto-rotate", "spin", -40, 40),
            muted("Drag to look. Scroll or pinch to zoom. Double-click resets. Arrows nudge."),
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        return column
    }

    private func gradeBlock() -> NSView {
        wire(sharpCheck, #selector(sharpToggled(_:)))
        sharpBox.orientation = .vertical
        sharpBox.addArrangedSubview(sliderRow("Amount", "sharp", 0, 1.5))
        let reset = NSButton(title: "Default picture", target: self, action: #selector(resetGrade(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        let column = NSStackView(views: [
            sliderRow("Brightness", "bright", -0.4, 0.4),
            sliderRow("Contrast", "contrast", 0.5, 1.8),
            sliderRow("Saturation", "sat", 0, 2),
            sharpCheck, sharpBox, reset,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        return column
    }

    private func buildExportSheet() {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Export"
        sheet.appearance = NSAppearance(named: .darkAqua)
        fill(presetPopup, ExportPreset.allCases.map(\.name), #selector(presetChanged(_:)))
        fill(codecPopup, VideoCodec.allCases.map(\.title), #selector(codecChanged(_:)))
        fill(stillPopup, StillFormat.allCases.map(\.title), #selector(stillChanged(_:)))
        wire(audioCheck, #selector(audioToggled(_:)))
        wire(useInOut, #selector(inOutToggled(_:)))
        sheetProgress.isIndeterminate = false
        sheetProgress.minValue = 0
        sheetProgress.maxValue = 1
        sheetStatus.maximumNumberOfLines = 2
        exportNote.maximumNumberOfLines = 3
        exportNote.textColor = .secondaryLabelColor
        exportNote.font = .systemFont(ofSize: 12)
        let still = NSButton(title: "Save Still", target: self, action: #selector(exportStill(_:)))
        let view = NSButton(title: "Export Current View", target: self, action: #selector(exportView(_:)))
        let youtube = NSButton(title: "YouTube 360", target: self, action: #selector(exportYouTube(_:)))
        recordButton = NSButton(title: "Record View Path", target: self, action: #selector(toggleRecord(_:)))
        let trim = NSButton(title: "Trim Original", target: self, action: #selector(trimOriginal(_:)))
        let join = NSButton(title: "Join Clips…", target: self, action: #selector(joinClips(_:)))
        let stills = NSButton(title: "Stills to Video", target: self, action: #selector(stillsToVideo(_:)))
        let close = NSButton(title: "Close", target: self, action: #selector(closeExport(_:)))
        cancelExportButton = NSButton(title: "Cancel Export", target: self, action: #selector(cancelExport(_:)))
        let actions: [NSButton] = [still, view, youtube, recordButton, trim, join, stills, close, cancelExportButton]
        for button in actions { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [still, view, youtube, recordButton, trim, join, stills])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 6
        let column = NSStackView(views: [
            section("Size"), presetPopup, sizeLabel, exportNote,
            section("Codec"), codecPopup,
            section("Still"), stillPopup,
            audioCheck, useInOut,
            buttons, sheetProgress, sheetStatus, cancelExportButton, close,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        sheet.contentView = column
        exportSheet = sheet
    }

    func refresh() {
        let facts = model.facts
        nameLabel.stringValue = model.fileName == "No clip" ? "ThreeSixtyView" : model.fileName
        if let facts {
            let fps = facts.isImage ? "Still" : String(format: "%.2f fps", facts.fps)
            metaLabel.stringValue = "\(facts.width)×\(facts.height)  ·  \(fps)  ·  \(facts.isImage ? facts.codec : timecode(facts.duration))  ·  \(facts.codec)"
        } else {
            metaLabel.stringValue = "Drop a square fisheye or a 2:1 equirectangular clip"
        }
        aimLabel.stringValue = facts == nil ? "" : "\(model.view.mode.title)  ·  \(model.input.mount.title)  ·  Yaw \(deg(model.view.yaw))  ·  Pitch \(deg(model.view.pitch))  ·  \(model.zoomLabel)"
        upscaleHint.stringValue = model.viewerNote
        upscaleHint.isHidden = model.viewerNote.isEmpty
        if qualityCheck.state != (model.fullQuality ? .on : .off) {
            qualityCheck.state = model.fullQuality ? .on : .off
        }
        if viewer.fullQuality != model.fullQuality {
            viewer.fullQuality = model.fullQuality
        }
        playButton.image = symbolImage(model.isPlaying ? "pause.fill" : "play.fill", pointSize: 16)
        playButton.toolTip = model.isPlaying ? "Pause (space)" : "Play (space)"
        let imageOnly = facts?.isImage != false
        scrubber.isEnabled = !imageOnly && facts != nil
        scrubber.maxValue = max(model.duration, 0.01)
        if window?.firstResponder !== scrubber { scrubber.doubleValue = model.currentTime }
        timeLabel.stringValue = timecode(model.currentTime)
        durationLabel.stringValue = facts == nil || imageOnly ? "" : "/  \(timecode(model.duration))"
        if model.inPoint != nil || model.outPoint != nil {
            let start = model.inPoint.map(timecode) ?? "—"
            let end = model.outPoint.map(timecode) ?? "—"
            rangeLabel.stringValue = "In \(start)   Out \(end)"
            rangeLabel.isHidden = false
        } else {
            rangeLabel.stringValue = ""
            rangeLabel.isHidden = true
        }
        statusLabel.stringValue = model.exportStatus
        statusLabel.isHidden = model.exportStatus.isEmpty
        progress.doubleValue = model.exportProgress
        progress.isHidden = !model.isExporting
        emptyTitle.superview?.superview?.isHidden = facts != nil || model.isLoading
        if model.isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        compass.heading = CGFloat(model.view.yaw)

        let savedModeAction = modeControl.action
        modeControl.action = nil
        if let match = quickModes.firstIndex(where: { $0.1 == model.view.mode }) {
            if modeControl.selectedSegment != match { modeControl.selectedSegment = match }
        } else if modeControl.selectedSegment != -1 {
            modeControl.selectedSegment = -1
        }
        modeControl.action = savedModeAction
        for preset in LookPreset.gallery {
            cards[preset.id]?.isPicked = preset.matches(model.view)
        }

        let urls = model.filteredLibrary.map(\.url)
        if urls != libraryURLs {
            libraryURLs = urls
            libraryTable.reloadData()
        }
        select(projectionPopup, Int(model.input.mode.rawValue))
        select(mountPopup, Int(model.input.mount.rawValue))
        select(unfoldPopup, Int(model.view.mode.rawValue))
        let fisheye = model.input.mode == .singleFisheye || model.input.mode == .dualSideBySide || model.input.mode == .dualTwoFiles
        fisheyeBox.isHidden = !fisheye
        dualBox.isHidden = model.input.mode != .dualSideBySide && model.input.mode != .dualTwoFiles
        for button in rotationButtons {
            button.state = button.tag == model.input.userQuarterTurns ? .on : .off
        }
        setSlider("fov", Double(model.input.lensA.fov.radiansToDegrees), format: "%.0f°")
        setSlider("radius", Double(model.input.lensA.radius), format: "%.3f")
        setSlider("cx", Double(model.input.lensA.centerX), format: "%.3f")
        setSlider("cy", Double(model.input.lensA.centerY), format: "%.3f")
        setSlider("backYaw", Double(model.input.lensB.yaw.radiansToDegrees), format: "%.0f°")
        setSlider("blend", Double(model.input.blend.radiansToDegrees), format: "%.0f°")
        setSlider("yaw", Double(wrapDegrees(model.view.yaw.radiansToDegrees)), format: "%.1f°")
        setSlider("pitch", Double(model.view.pitch.radiansToDegrees), format: "%.1f°")
        setSlider("roll", Double(wrapDegrees(model.view.roll.radiansToDegrees)), format: "%.1f°")
        if let zoom = sliders["zoom"] {
            switch model.view.mode {
            case .dome, .fisheye: zoom.minValue = 20; zoom.maxValue = 270
            case .global, .littlePlanet: zoom.minValue = 0.15; zoom.maxValue = 8
            case .panorama, .ring, .magicFlat: zoom.minValue = 10; zoom.maxValue = 360
            case .throwOut: zoom.minValue = 0.05; zoom.maxValue = 3
            case .original: zoom.minValue = 0; zoom.maxValue = 1
            default: zoom.minValue = 10; zoom.maxValue = 140
            }
        }
        setSlider("zoom", zoomPosition(), format: model.zoomLabel)
        setSlider("spin", model.spinDegreesPerSecond, format: "%.0f°/s")
        setSlider("bright", Double(model.input.grade.brightness), format: "%+.2f")
        setSlider("contrast", Double(model.input.grade.contrast), format: "%.2f")
        setSlider("sat", Double(model.input.grade.saturation), format: "%.2f")
        setSlider("sharp", Double(model.input.grade.sharpness), format: "%.2f")
        sharpCheck.state = model.input.grade.sharpnessEnabled ? .on : .off
        sharpBox.isHidden = !model.input.grade.sharpnessEnabled
        calibrateCheck.state = model.calibrating ? .on : .off
        audioCheck.state = model.includeAudio ? .on : .off
        useInOut.state = model.useInOut ? .on : .off
        useInOut.isEnabled = model.inPoint != nil && model.outPoint != nil
        select(presetPopup, ExportPreset.allCases.firstIndex(of: model.preset) ?? 0)
        select(codecPopup, VideoCodec.allCases.firstIndex(of: model.codec) ?? 0)
        select(stillPopup, StillFormat.allCases.firstIndex(of: model.stillFormat) ?? 0)
        sizeLabel.stringValue = model.exportSizeLabel
        exportNote.stringValue = model.upscaleNote
        sheetProgress.doubleValue = model.exportProgress
        sheetProgress.isHidden = !model.isExporting
        sheetStatus.stringValue = model.exportStatus
        recordButton.title = model.isRecording ? "Stop and Save Path" : "Record View Path"
        cancelExportButton.isHidden = !model.isExporting
        factsLabel.stringValue = facts.map { "\($0.width)×\($0.height) · \(String(format: "%.3f", $0.fps)) fps · \($0.codec)\n\($0.isImage ? "Still" : timecode($0.duration)) · \(model.input.mode.title)" } ?? "No clip open"
        window?.title = model.fileName == "No clip" ? "ThreeSixtyView" : model.fileName
        scheduleThumbs()
        if model.showError {
            model.showError = false
            let alert = NSAlert()
            alert.messageText = "Couldn't open that"
            alert.informativeText = model.errorMessage ?? ""
            alert.runModal()
        }
    }

    private func scheduleThumbs() {
        guard model.facts != nil else { return }
        let bucket = Int((model.currentTime * 3).rounded(.down))
        let grade = model.input.grade
        let key = "\(model.fileName)|\(bucket)|\(model.input.mode.rawValue)|\(model.input.mount.rawValue)|\(model.input.lensA.fov)|\(model.input.lensA.radius)|\(model.input.lensA.centerX)|\(model.input.lensA.centerY)|\(model.input.userQuarterTurns)|\(model.backGeneration)|\(grade.brightness)|\(grade.contrast)|\(grade.saturation)|\(grade.sharpness)|\(grade.sharpnessEnabled)"
        guard key != thumbKey, let buffer = model.pullFrame() else { return }
        thumbKey = key
        let source = readRGBA(buffer)
        let input = model.input
        let back = model.currentBackImage()
        thumbToken += 1
        let token = thumbToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var rendered: [(String, NSImage)] = []
            for preset in LookPreset.gallery {
                let frame = renderFrame(
                    source: source, back: back, view: preset.makeView(), input: input,
                    outputWidth: 168, outputHeight: 104
                )
                rendered.append((preset.id, nsImage(frame)))
            }
            DispatchQueue.main.async {
                guard let self, self.thumbToken == token else { return }
                for (id, image) in rendered { self.cards[id]?.image = image }
            }
        }
    }

    private func zoomPosition() -> Double {
        switch model.view.mode {
        case .dome: return Double(model.view.domeFOV.radiansToDegrees)
        case .fisheye: return Double(model.view.fisheyeOutFOV.radiansToDegrees)
        case .global, .littlePlanet: return Double(model.view.planetScale)
        case .panorama: return Double(model.view.panoramaVert.radiansToDegrees)
        case .ring: return Double(model.view.ringLatSpan.radiansToDegrees)
        case .magicFlat: return Double(model.view.magicHoriz.radiansToDegrees)
        case .throwOut: return Double(model.view.throwScale)
        case .original: return 0
        default: return Double(model.view.fovY.radiansToDegrees)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(viewer)
    }

    private func revealChrome(sticky: Bool = false) {
        hideChrome?.cancel()
        chrome.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            chrome.animator().alphaValue = 1
        }
        guard !sticky, model.facts != nil, !inspectorOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.facts != nil, !self.inspectorOpen else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                self.chrome.animator().alphaValue = 0
            }, completionHandler: {
                if self.chrome.alphaValue < 0.05 { self.chrome.isHidden = true }
            })
        }
        hideChrome = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    private func focusPicture() {
        window?.makeFirstResponder(viewer)
    }

    @objc func openDocument(_ sender: Any?) { model.openPanel() }
    @objc func openFolder(_ sender: Any?) { model.openFolderPanel() }
    @objc func addBackLens(_ sender: Any?) { model.backLensPanel() }
    @objc func exportStill(_ sender: Any?) { finishExportSheet { self.model.exportStill() } }
    @objc func exportView(_ sender: Any?) { finishExportSheet { self.model.exportView() } }
    @objc func exportYouTube(_ sender: Any?) { finishExportSheet { self.model.exportYouTube() } }
    @objc func trimOriginal(_ sender: Any?) { finishExportSheet { self.model.trimOriginal() } }
    @objc func toggleRecord(_ sender: Any?) { finishExportSheet { self.model.toggleRecording() } }
    @objc func stillsToVideo(_ sender: Any?) { finishExportSheet { self.model.exportStillsAsVideo() } }
    @objc func resetView(_ sender: Any?) { model.resetView(); focusPicture() }
    @objc func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "ThreeSixtyView"
        alert.informativeText = "Player for circular-fisheye clips such as the Wideshoot and PixPro SP360 4K files. A square video opens as a 225° fisheye, Ceiling / down, looking forward. Drag to look, scroll or pinch to zoom, and tap a preview to jump there."
        alert.runModal()
    }
    @objc func showExport(_ sender: Any?) {
        guard let sheet = exportSheet, let window else { return }
        refresh()
        window.beginSheet(sheet)
    }
    @objc func closeExport(_ sender: Any?) { finishExportSheet(nil) }

    private func finishExportSheet(_ next: (() -> Void)?) {
        guard let sheet = exportSheet, sheet.isSheet, let window else {
            next?()
            return
        }
        window.endSheet(sheet)
        if let next { DispatchQueue.main.async(execute: next) }
    }
    @objc func toggleInspector(_ sender: Any?) {
        inspectorOpen.toggle()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            inspectorWidth.animator().constant = inspectorOpen ? 320 : 0
        }
        revealChrome(sticky: inspectorOpen)
    }
    @objc func joinClips(_ sender: Any?) {
        finishExportSheet(nil)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose clips that share a codec and frame size."
        guard panel.runModal() == .OK, panel.urls.count >= 2 else { return }
        model.joinURLs = panel.urls
        model.joinSelected()
    }
    @objc func togglePlay(_ sender: Any?) { model.togglePlay(); focusPicture() }
    @objc func jumpStart(_ sender: Any?) { model.jump(to: false); focusPicture() }
    @objc func jumpEnd(_ sender: Any?) { model.jump(to: true); focusPicture() }
    @objc func stepBack(_ sender: Any?) { model.step(-1); focusPicture() }
    @objc func stepForward(_ sender: Any?) { model.step(1); focusPicture() }
    @objc func scrubbed(_ sender: NSSlider) { model.seek(sender.doubleValue); revealChrome() }
    @objc func markIn(_ sender: Any?) { model.markIn(); focusPicture() }
    @objc func markOut(_ sender: Any?) { model.markOut(); focusPicture() }
    @objc func clearRange(_ sender: Any?) { model.clearRange() }
    @objc func inOutToggled(_ sender: NSButton) { model.useInOut = sender.state == .on }
    @objc func filterChanged(_ sender: NSSegmentedControl) {
        model.libraryFilter = LibraryFilter.allCases[sender.selectedSegment]
    }
    @objc func projectionChanged(_ sender: NSPopUpButton) {
        model.holdMotion()
        model.input.mode = InputMode(rawValue: Int32(sender.indexOfSelectedItem)) ?? .singleFisheye
    }
    @objc func mountChanged(_ sender: NSPopUpButton) {
        model.holdMotion()
        model.input.mount = MountOrientation(rawValue: Int32(sender.indexOfSelectedItem)) ?? .lensDown
    }
    @objc func rotate(_ sender: NSButton) { model.rotateVideo(turns: sender.tag) }
    @objc func quickMode(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard quickModes.indices.contains(index) else { return }
        model.setUnfold(quickModes[index].1)
        focusPicture()
    }
    @objc func unfoldPicked(_ sender: NSPopUpButton) {
        model.setUnfold(UnfoldMode(rawValue: Int32(sender.indexOfSelectedItem)) ?? .front16x9)
    }
    @objc func chooseUnfold(_ sender: NSMenuItem) {
        model.setUnfold(UnfoldMode(rawValue: Int32(sender.tag)) ?? .front16x9)
    }
    @objc func nudgeLeft(_ sender: Any?) { model.nudge(.yaw(-6)) }
    @objc func nudgeRight(_ sender: Any?) { model.nudge(.yaw(6)) }
    @objc func nudgeUp(_ sender: Any?) { model.nudge(.pitch(6)) }
    @objc func nudgeDown(_ sender: Any?) { model.nudge(.pitch(-6)) }
    @objc func resetGrade(_ sender: Any?) { model.input.grade = .identity }
    @objc func sharpToggled(_ sender: NSButton) { model.input.grade.sharpnessEnabled = sender.state == .on }
    @objc func calibrateToggled(_ sender: NSButton) { model.setCalibration(sender.state == .on) }
    @objc func audioToggled(_ sender: NSButton) { model.includeAudio = sender.state == .on }
    @objc func presetChanged(_ sender: NSPopUpButton) {
        let chosen = ExportPreset.allCases[sender.indexOfSelectedItem]
        model.preset = chosen
        if chosen.prefersHEVC { model.codec = .hevc }
    }
    @objc func qualityToggled(_ sender: NSButton) {
        model.fullQuality = sender.state == .on
        viewer.fullQuality = model.fullQuality
        focusPicture()
    }
    @objc func codecChanged(_ sender: NSPopUpButton) { model.codec = VideoCodec.allCases[sender.indexOfSelectedItem] }
    @objc func stillChanged(_ sender: NSPopUpButton) { model.stillFormat = StillFormat.allCases[sender.indexOfSelectedItem] }
    @objc func cancelExport(_ sender: Any?) { model.cancelExport() }
    @objc func sliderChanged(_ sender: NSSlider) {
        model.holdMotion()
        let value = Float(sender.doubleValue)
        switch sender.identifier?.rawValue {
        case "fov":
            model.input.lensA.fov = value.degreesToRadians
            model.input.lensB.fov = model.input.lensA.fov
        case "radius": model.input.lensA.radius = value
        case "cx": model.input.lensA.centerX = value
        case "cy": model.input.lensA.centerY = value
        case "backYaw": model.input.lensB.yaw = value.degreesToRadians
        case "blend": model.input.blend = value.degreesToRadians
        case "yaw": model.view.yaw = value.degreesToRadians
        case "pitch": model.view.pitch = value.degreesToRadians
        case "roll": model.view.roll = value.degreesToRadians
        case "spin": model.spinDegreesPerSecond = sender.doubleValue
        case "bright": model.input.grade.brightness = value
        case "contrast": model.input.grade.contrast = value
        case "sat": model.input.grade.saturation = value
        case "sharp": model.input.grade.sharpness = value
        case "zoom": applyZoom(sender.doubleValue)
        default: break
        }
    }

    private func applyZoom(_ raw: Double) {
        let value = Float(raw)
        switch model.view.mode {
        case .dome: model.view.domeFOV = value.degreesToRadians
        case .fisheye: model.view.fisheyeOutFOV = value.degreesToRadians
        case .global, .littlePlanet: model.view.planetScale = value
        case .panorama: model.view.panoramaVert = value.degreesToRadians
        case .ring: model.view.ringLatSpan = value.degreesToRadians
        case .magicFlat: model.view.magicHoriz = value.degreesToRadians
        case .throwOut: model.view.throwScale = value
        case .original: break
        default: model.view.fovY = value.degreesToRadians
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.filteredLibrary.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = model.filteredLibrary[row]
        let text = NSTextField(labelWithString: item.url.lastPathComponent)
        text.lineBreakMode = .byTruncatingMiddle
        text.font = .systemFont(ofSize: 12)
        return text
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = libraryTable.selectedRow
        guard row >= 0, row < model.filteredLibrary.count else { return }
        model.open(model.filteredLibrary[row].url)
    }

    private func sliderRow(_ title: String, _ identifier: String, _ minValue: Double, _ maxValue: Double) -> NSView {
        let slider = NSSlider(value: minValue, minValue: minValue, maxValue: maxValue, target: self, action: #selector(sliderChanged(_:)))
        slider.identifier = NSUserInterfaceItemIdentifier(identifier)
        slider.isContinuous = true
        slider.controlSize = .small
        let readout = NSTextField(labelWithString: "")
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: 64).isActive = true
        sliders[identifier] = slider
        valueLabels[identifier] = readout
        let row = NSStackView(views: [muted(title), readout])
        row.orientation = .horizontal
        let column = NSStackView(views: [row, slider])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        slider.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func setSlider(_ identifier: String, _ value: Double, format: String) {
        guard let slider = sliders[identifier] else { return }
        if window?.firstResponder !== slider {
            slider.doubleValue = min(max(value, slider.minValue), slider.maxValue)
        }
        valueLabels[identifier]?.stringValue = String(format: format, value)
    }

    private func select(_ popup: NSPopUpButton, _ index: Int) {
        guard index >= 0, popup.itemArray.indices.contains(index) else { return }
        if popup.indexOfSelectedItem != index { popup.selectItem(at: index) }
    }

    private func fill(_ popup: NSPopUpButton, _ titles: [String], _ action: Selector) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        popup.controlSize = .small
    }

    private func wire(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
    }

    private func symbol(_ name: String, _ tooltip: String, _ action: Selector) -> SymbolButton {
        let button = SymbolButton(symbol: name, tooltip: tooltip, pointSize: 14)
        button.target = self
        button.action = action
        return button
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func muted(_ title: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: title)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func glass(_ radius: CGFloat) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return effect
    }

    private func shadowWrap(_ content: NSView, radius: CGFloat) -> NSView {
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.shadowColor = NSColor.black.cgColor
        wrap.layer?.shadowOpacity = 0.28
        wrap.layer?.shadowRadius = 16
        wrap.layer?.shadowOffset = CGSize(width: 0, height: 8)
        if let effect = content as? NSVisualEffectView {
            effect.layer?.cornerRadius = radius
            effect.layer?.cornerCurve = .continuous
        }
        wrap.addSubview(content)
        pin(content, to: wrap)
        return wrap
    }

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

final class ViewerCoordinator: NSObject, MTKViewDelegate {
    let model: AppModel
    private var renderer: MetalRenderer?
    private var backTexture: MTLTexture?
    private var backToken = -1

    init(model: AppModel) { self.model = model }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard let viewer = view as? ViewerMTKView else { return }
        viewer.noteDrawableSize(size)
    }

    func draw(in view: MTKView) {
        if renderer == nil, let device = view.device {
            renderer = try? MetalRenderer(device: device)
            if renderer == nil {
                view.isPaused = true
            }
        }
        let pixelSize = view.drawableSize
        guard pixelSize.width > 1, pixelSize.height > 1 else { return }
        guard let renderer, let drawable = view.currentDrawable else { return }
        let outputWidth = drawable.texture.width
        let outputHeight = drawable.texture.height
        guard outputWidth > 1, outputHeight > 1 else { return }
        if model.backGeneration != backToken {
            backTexture = model.currentBackImage().flatMap { renderer.upload($0) }
            backToken = model.backGeneration
        }
        guard let buffer = model.pullFrame(),
              let source = renderer.texture(from: buffer) ?? renderer.upload(readRGBA(buffer)) else { return }
        let uniforms = GPUUniforms.make(
            view: model.view, input: model.input,
            sourceWidth: CVPixelBufferGetWidth(buffer), sourceHeight: CVPixelBufferGetHeight(buffer),
            backWidth: model.currentBackImage()?.width ?? CVPixelBufferGetWidth(buffer),
            backHeight: model.currentBackImage()?.height ?? CVPixelBufferGetHeight(buffer),
            outputWidth: outputWidth, outputHeight: outputHeight,
            hasBack: model.currentBackImage() != nil, showCalibration: model.calibrating
        )
        try? renderer.render(
            source: source, back: backTexture, uniforms: uniforms,
            into: drawable.texture, present: drawable, wait: false, syncWithTransaction: true
        )
    }
}

final class ViewerMTKView: MTKView {
    var onDrag: ((Float, Float) -> Void)?
    var onFling: ((Float, Float) -> Void)?
    var onScroll: ((Float, Bool) -> Void)?
    var onZoom: ((Float) -> Void)?
    var onReset: (() -> Void)?
    var onKey: ((UInt16) -> Void)?
    var onDropURLs: (([URL]) -> Void)?
    var onActivity: (() -> Void)?
    var fullQuality = true {
        didSet {
            if oldValue != fullQuality { syncDrawableSize() }
        }
    }
    private var last: NSPoint?
    private var samples: [(t: TimeInterval, x: CGFloat, y: CGFloat)] = []
    private var announcedDrawable = CGSize.zero

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        prepareStableLayer()
    }

    func prepareStableLayer() {
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .scaleProportionallyToFit
        wantsLayer = true
        layer?.isOpaque = true
        layer?.drawsAsynchronously = false
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.presentsWithTransaction = true
        metalLayer.allowsNextDrawableTimeout = false
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.displaySyncEnabled = true
    }

    func noteDrawableSize(_ size: CGSize) {
        announcedDrawable = size
    }

    func syncDrawableSize() {
        let width = bounds.width
        let height = bounds.height
        guard width > 2, height > 2 else { return }
        let screen = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let scale = fullQuality ? max(screen, 1) : 1
        autoResizeDrawable = false
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        if abs(drawableSize.width - size.width) > 0.5 || abs(drawableSize.height - size.height) > 0.5 {
            drawableSize = size
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        prepareStableLayer()
        syncDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        prepareStableLayer()
        syncDrawableSize()
    }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        syncDrawableSize()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        prepareStableLayer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) { onActivity?() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivity?()
        let local = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        if fromTop < 44, let window {
            if event.clickCount >= 2 { window.performZoom(nil) } else { window.performDrag(with: event) }
            last = nil
            return
        }
        if event.clickCount >= 2 {
            onReset?()
            last = nil
            samples.removeAll()
            return
        }
        last = convert(event.locationInWindow, from: nil)
        samples.removeAll()
    }

    override func mouseDragged(with event: NSEvent) {
        onActivity?()
        let point = convert(event.locationInWindow, from: nil)
        let origin = last ?? point
        let dx = point.x - origin.x
        let dy = origin.y - point.y
        onDrag?(Float(dx), Float(dy))
        samples.append((event.timestamp, dx, dy))
        let cutoff = event.timestamp - 0.09
        samples.removeAll { $0.t < cutoff }
        last = point
    }

    override func mouseUp(with event: NSEvent) {
        let recent = samples.filter { event.timestamp - $0.t < 0.1 }
        if let first = recent.first, recent.count > 1 {
            let dt = max(event.timestamp - first.t, 0.012)
            let sx = recent.reduce(CGFloat(0)) { $0 + $1.x }
            let sy = recent.reduce(CGFloat(0)) { $0 + $1.y }
            let speed = hypot(sx, sy) / dt
            if speed > 180 {
                onFling?(Float(sx / dt), Float(sy / dt))
            }
        }
        samples.removeAll()
        last = nil
    }

    override func scrollWheel(with event: NSEvent) {
        onActivity?()
        let scale: Float = event.hasPreciseScrollingDeltas ? 1 : 14
        onScroll?(Float(event.scrollingDeltaY) * scale, event.modifierFlags.contains(.option))
    }

    override func magnify(with event: NSEvent) {
        onActivity?()
        onZoom?(1 + Float(event.magnification))
    }

    override func keyDown(with event: NSEvent) { onKey?(event.keyCode); onActivity?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            return false
        }
        onDropURLs?(urls)
        return true
    }
}

final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), hit !== self else { return nil }
        return hit
    }
}

final class SymbolButton: NSButton {
    private let pointSize: CGFloat

    init(symbol: String, tooltip: String, pointSize: CGFloat) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        image = symbolImage(symbol, pointSize: pointSize)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        contentTintColor = .white
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
    }
}

final class PresetCard: NSControl {
    let preset: LookPreset
    var onPick: ((LookPreset) -> Void)?
    private let imageView = NSImageView()
    private let symbolView: NSImageView
    private let titleField = NSTextField(labelWithString: "")
    private var hovering = false

    var image: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            imageView.isHidden = newValue == nil
            symbolView.isHidden = newValue != nil
        }
    }

    var isPicked = false { didSet { style() } }

    init(preset: LookPreset) {
        self.preset = preset
        symbolView = NSImageView(image: symbolImage(preset.symbol, pointSize: 18) ?? NSImage())
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        toolTip = preset.detail
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        titleField.stringValue = preset.title
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .white
        titleField.alignment = .center
        titleField.wantsLayer = true
        titleField.layer?.shadowColor = NSColor.black.cgColor
        titleField.layer?.shadowOpacity = 0.8
        titleField.layer?.shadowRadius = 3
        titleField.layer?.shadowOffset = .zero
        symbolView.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(symbolView)
        addSubview(titleField)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 124),
            heightAnchor.constraint(equalToConstant: 96),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        style()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        style()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        style()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.82
    }

    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPick?(preset)
        }
        style()
    }

    private func style() {
        let accent = NSColor.controlAccentColor
        layer?.borderWidth = isPicked ? 2.5 : (hovering ? 1.5 : 0)
        layer?.borderColor = (isPicked ? accent : NSColor.white.withAlphaComponent(0.7)).cgColor
        animator().alphaValue = 1
    }
}

final class CompassDial: NSView {
    var heading: CGFloat = 0 { didSet { needsDisplay = true } }
    var onHeading: ((Float) -> Void)?
    private var dragOrigin = CGFloat(0)
    private var dragHeading = CGFloat(0)

    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 64) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(rect.width, rect.height) * 0.5
        let disc = NSBezierPath(ovalIn: rect)
        NSColor.white.withAlphaComponent(0.1).setFill()
        disc.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        disc.lineWidth = 1
        disc.stroke()

        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: center.x, y: center.y + radius - 4))
        tick.line(to: CGPoint(x: center.x, y: center.y + radius - 12))
        NSColor.controlAccentColor.setStroke()
        tick.lineWidth = 2
        tick.lineCapStyle = .round
        tick.stroke()

        let labels: [(String, CGFloat)] = [("F", 0), ("R", .pi / 2), ("B", .pi), ("L", -.pi / 2)]
        for (text, bearing) in labels {
            let relative = bearing - heading
            let theta = CGFloat.pi / 2 - relative
            let point = CGPoint(x: center.x + cos(theta) * (radius - 18), y: center.y + sin(theta) * (radius - 18))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: text == "F" ? .bold : .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(text == "F" ? 0.95 : 0.55),
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = pointerAngle(point)
        dragHeading = heading
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var delta = pointerAngle(point) - dragOrigin
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        let next = dragHeading - delta
        heading = next
        onHeading?(Float(next))
    }

    private func pointerAngle(_ point: NSPoint) -> CGFloat {
        atan2(point.y - bounds.midY, point.x - bounds.midX)
    }
}

private func symbolImage(_ name: String, pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    return NSImage(systemSymbolName: name, accessibilityDescription: name)?.withSymbolConfiguration(config)
}

private func nsImage(_ image: RGBAImage) -> NSImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let data = Data(image.rgba) as CFData
    guard let provider = CGDataProvider(data: data),
          let cg = CGImage(
            width: image.width, height: image.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
          ) else {
        return NSImage(size: NSSize(width: image.width, height: image.height))
    }
    return NSImage(cgImage: cg, size: NSSize(width: image.width, height: image.height))
}

#endif
