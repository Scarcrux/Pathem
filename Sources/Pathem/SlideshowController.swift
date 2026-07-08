import AppKit

/// A borderless full-screen image slideshow, like Finder's. Auto-advances on a timer; arrow keys
/// step, Space plays/pauses, Esc (or a click outside the image) exits. Images load off the main
/// thread. Self-contained: hand it a list of image URLs and a starting index.
@MainActor
final class SlideshowController: NSObject {
    private var window: SlideshowWindow?
    private let imageView = NSImageView()
    private let counter = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    private var urls: [URL] = []
    private var index = 0
    private var timer: Timer?
    private var interval: TimeInterval = 4
    private(set) var isPlaying = false

    /// Present a slideshow of `urls` (non-images are ignored), starting at `startAt`. Beeps and
    /// does nothing if there are no images.
    func start(urls: [URL], startAt: Int = 0) {
        let images = urls.filter { BrowserViewController.isImageName($0.lastPathComponent) }
        guard !images.isEmpty else { NSSound.beep(); return }
        self.urls = images
        index = min(max(startAt, 0), images.count - 1)
        present()
        loadCurrent()
        play()
    }

    /// True while the slideshow window is up (used by the smoke check).
    var isActive: Bool { window?.isVisible == true }

    private func present() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = self.window ?? makeWindow(frame: frame)
        self.window = window
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(window.contentView)
    }

    private func makeWindow(frame: NSRect) -> SlideshowWindow {
        let window = SlideshowWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .mainMenu + 1  // cover the menu bar for a true full-screen feel
        window.backgroundColor = .black
        window.isOpaque = true

        let root = SlideshowView()
        root.onKey = { [weak self] keyCode in self?.handleKey(keyCode) }
        root.onClick = { [weak self] in self?.next() }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown  // never upscale past 100%, letterboxed
        imageView.animates = true
        root.addSubview(imageView)

        counter.translatesAutoresizingMaskIntoConstraints = false
        counter.font = .systemFont(ofSize: 13, weight: .medium)
        counter.textColor = .white
        counter.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.6)
        hint.alignment = .center
        hint.stringValue = L(
            "slideshow.hint", "Space: play/pause    ←/→: previous/next    Esc: exit")
        root.addSubview(counter)
        root.addSubview(hint)

        window.contentView = root
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            imageView.bottomAnchor.constraint(equalTo: counter.topAnchor, constant: -12),
            counter.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            counter.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -4),
            hint.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        return window
    }

    private func handleKey(_ keyCode: UInt16) {
        switch keyCode {
        case 53: close()  // Esc
        case 123: step(-1)  // Left
        case 124: step(1)  // Right
        case 49: togglePlay()  // Space
        default: break
        }
    }

    private func step(_ delta: Int) {
        guard !urls.isEmpty else { return }
        index = (index + delta + urls.count) % urls.count
        loadCurrent()
        if isPlaying { play() }  // reset the dwell timer after a manual step
    }

    private func next() { step(1) }

    private func togglePlay() { isPlaying ? pause() : play() }

    private func play() {
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        updateCounter()
    }

    private func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        updateCounter()
    }

    private func loadCurrent() {
        guard urls.indices.contains(index) else { return }
        let url = urls[index]
        updateCounter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = NSImage(contentsOf: url)
            DispatchQueue.main.async {
                guard let self, self.urls.indices.contains(self.index), self.urls[self.index] == url else { return }
                self.imageView.image = image
            }
        }
    }

    private func updateCounter() {
        let state = isPlaying ? "▶" : "❚❚"
        counter.stringValue = "\(state)   \(index + 1) / \(urls.count)   ·   \(urls[safe: index]?.lastPathComponent ?? "")"
    }

    func close() {
        pause()
        window?.orderOut(nil)
        imageView.image = nil
    }
}

/// A borderless window that can still become key (so it receives the arrow/Space/Esc keys).
private final class SlideshowWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The full-screen content view: forwards key presses and a click to the controller.
private final class SlideshowView: NSView {
    var onKey: ((UInt16) -> Void)?
    var onClick: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event.keyCode) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
