// DOOM Recomp installer for macOS.
//
//   Welcome -> Install Location -> Choose Components -> Game Files -> Installing -> Completed
//
// Unlike a normal installer it carries no game: it carries this project's source
// (Contents/Resources/source) and builds the game from the user's own copy of
// DOOM (2016), by running scripts/build.sh in a work folder. The KosmicKrisp Vulkan driver (built from
// Mesa source) comes prebuilt in source/prebuilt/kosmickrisp.
//
// build_installer.sh compiles this into "Install DOOM Recomp.app".

import AppKit
import CryptoKit

let appName = "DOOM Recomp"
let setupTitle = "DOOM Recomp Setup"
let bundleID = "com.nightsightproductions.doom-recomp"
let gameTitle = "DOOM"
let gameAppName = "DOOM"   // the installed app: "DOOM.app"
// Executable profiles supported by scripts/build_profile.sh. GOG support is experimental.
let supportedSHA256 = [
    "3d8b4393649f80bdae85c19ae2c985c45ec9ac54f74ab04a18816e30ead63c21", // Steam
    "a32df8ffa042090f14fe0a200f1c5d7dddf9c947fac223916c252f826f1ecf11", // GOG (experimental)
]

// MARK: - Install state

final class InstallState {
    var installDir = URL(fileURLWithPath: "/Applications")
    var desktopShortcut = true
    var steamShortcut = true
    var importSaves = true
    var steamPlay = false   // Steam Play tool (needs NotProton); opt-in
    var gameApp: URL?   // the game folder (contains DOOMx64vk.exe)
    var gameProfile = "steam"

    let resources = Bundle.main.resourceURL!
    var sourceDir: URL { resources.appendingPathComponent("source") }
    var installedApp: URL { installDir.appendingPathComponent("\(gameAppName).app") }

    // Temporary build folder: the translated code and objects (about 4 GB) live here
    // during installation and are deleted afterwards.
    static var workDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/DOOM-Recomp")
    }
}

func directorySize(_ url: URL) -> Int64 {
    var total: Int64 = 0
    if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    return total
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func gameExecutable(_ dir: URL) -> URL { dir.appendingPathComponent("DOOMx64vk.exe") }

func isGameApp(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: gameExecutable(url).path)
}

// The game ships no Mac icon to borrow (the built app gets one from the game's executable).
func useGameIcon(_ dir: URL?) {}

func sha256(of url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// Look in Steam folders of CrossOver and Whisky (and extra libraries), Mac Steam, then the known
// Heroic GOG install location. Other GOG locations can be selected with Browse.
func detectGame() -> URL? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    var steamDirs: [URL] = []
    for bottles in ["Library/Application Support/CrossOver/Bottles", "Library/Containers/com.isaacmarovitz.Whisky/Bottles"] {
        let root = home.appendingPathComponent(bottles)
        for b in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            for pf in ["Program Files (x86)", "Program Files"] {
                steamDirs.append(root.appendingPathComponent(b).appendingPathComponent("drive_c/\(pf)/Steam/steamapps"))
            }
        }
    }
    steamDirs.append(home.appendingPathComponent("Library/Application Support/Steam/steamapps"))
    var candidates: [URL] = []
    for steamApps in steamDirs {
        candidates.append(steamApps.appendingPathComponent("common/DOOM"))
        if let vdf = try? String(contentsOf: steamApps.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8) {
            for line in vdf.split(separator: "\n") {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if parts.count == 2, parts[0] == "path" {
                    // a Windows path (C:\\...) inside the bottle's drive_c
                    var p = parts[1].replacingOccurrences(of: "\\\\", with: "/")
                    if p.count > 2, p.dropFirst().hasPrefix(":") { p = String(p.dropFirst(2)) }
                    let driveC = steamApps.deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent()
                    candidates.append(driveC.appendingPathComponent(p).appendingPathComponent("steamapps/common/DOOM"))
                }
            }
        }
    }
    candidates.append(home.appendingPathComponent("Games/Heroic/DOOM (2016)"))
    return candidates.first(where: isGameApp)
}

// MARK: - Small view helpers

// A read-only path field that shortens long paths in the middle instead of growing: its row's Browse… button
// must stay visible (a long CrossOver path used to push it out of the window).
func pathField(_ f: NSTextField) {
    f.isEditable = false
    f.lineBreakMode = .byTruncatingMiddle
    f.cell?.lineBreakMode = .byTruncatingMiddle
    f.cell?.usesSingleLineMode = true
    f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    f.setContentHuggingPriority(.defaultLow, for: .horizontal)
}
func setPath(_ f: NSTextField, _ p: String) { f.stringValue = p; f.toolTip = p }

func label(_ text: String, bold: Bool = false, size: CGFloat = 12, wraps: Bool = true) -> NSTextField {
    let l = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func pin(_ v: NSView, in parent: NSView, _ make: (NSView) -> [NSLayoutConstraint]) {
    v.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(v)
    NSLayoutConstraint.activate(make(v))
}

final class HoverButton: NSButton {
    var onHover: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
}

// MARK: - Pages

protocol WizardPage: AnyObject {
    var view: NSView { get }
    var headerTitle: String { get }
    var headerSubtitle: String { get }
    var isWelcome: Bool { get }
    func willShow()
    func canLeave() -> Bool
}

extension WizardPage {
    var isWelcome: Bool { false }
    func willShow() {}
    func canLeave() -> Bool { true }
}

final class WelcomePage: WizardPage {
    let view = NSView()
    let headerTitle = ""
    let headerSubtitle = ""
    var isWelcome: Bool { true }
    var onUninstall: (() -> Void)?

    init(state: InstallState) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor

        // Optional banner (Contents/Resources/WelcomeImage.png).
        let bannerImage = NSImage(contentsOf: state.resources.appendingPathComponent("WelcomeImage.png"))
        let banner = NSImageView(image: bannerImage ?? NSImage())
        banner.imageScaling = .scaleAxesIndependently
        pin(banner, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                                 $0.topAnchor.constraint(equalTo: self.view.topAnchor),
                                 $0.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
                                 $0.widthAnchor.constraint(equalToConstant: bannerImage == nil ? 0 : 164)] }

        let title = label("Welcome to \(appName) Setup", bold: true, size: 16)
        title.textColor = .black
        let body = label("Setup builds a native Apple Silicon version of \(gameTitle) from your own copy of the game. Steam is supported; GOG support is experimental.\n\n" +
                         "You need the Windows version of DOOM (2016) from Steam or GOG, " +
                         "Apple's Command Line Tools (Setup will offer to install them) and an internet connection. " +
                         "Building takes about 15 minutes and needs about 4 GB of temporary disk space.\n\n" +
                         "Click Next to continue.")
        body.textColor = .black
        let uninstall = NSButton(title: "Uninstall \(appName)…", target: nil, action: nil)
        uninstall.bezelStyle = .inline
        uninstall.target = self
        uninstall.action = #selector(uninstallClicked)

        for (v, top) in [(title as NSView, 20.0), (body, 70.0)] {
            pin(v, in: view) { [$0.leadingAnchor.constraint(equalTo: banner.trailingAnchor, constant: 18),
                                $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -18),
                                $0.topAnchor.constraint(equalTo: self.view.topAnchor, constant: top)] }
        }
        pin(uninstall, in: view) { [$0.leadingAnchor.constraint(equalTo: banner.trailingAnchor, constant: 18),
                                    $0.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -14)] }
    }

    @objc func uninstallClicked() { onUninstall?() }
}

final class DirectoryPage: WizardPage {
    let view = NSView()
    let headerTitle = "Choose Install Location"
    let headerSubtitle = "Choose the folder in which to install \(appName)."
    let state: InstallState
    let path = NSTextField()
    let available = label("", wraps: false)

    init(state: InstallState) {
        self.state = state
        let top = label("Setup will install \(appName) in the following folder. To install in a different folder, click Browse and select another folder. Click Next to continue.")
        let box = NSBox()
        box.title = "Destination Folder"
        setPath(path, state.installDir.path)
        pathField(path)
        let browse = NSButton(title: "Browse…", target: nil, action: nil)
        browse.target = self
        browse.action = #selector(browseClicked)
        let required = label("Space required: about 200 MB, plus about 4 GB while building", wraps: false)

        pin(top, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                              $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                              $0.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 14)] }
        pin(box, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                              $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                              $0.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 16),
                              $0.heightAnchor.constraint(equalToConstant: 64)] }
        let content = box.contentView!
        pin(path, in: content) { [$0.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                                  $0.centerYAnchor.constraint(equalTo: content.centerYAnchor)] }
        pin(browse, in: content) { [$0.leadingAnchor.constraint(equalTo: self.path.trailingAnchor, constant: 8),
                                    $0.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                                    $0.centerYAnchor.constraint(equalTo: content.centerYAnchor)] }
        pin(required, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                                   $0.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 16)] }
        pin(available, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                                    $0.topAnchor.constraint(equalTo: required.bottomAnchor, constant: 4)] }
        updateAvailable()
    }

    func updateAvailable() {
        let free = (try? state.installDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        available.stringValue = "Space available: \(formatSize(free))"
    }

    @objc func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = state.installDir
        panel.message = "Choose the folder in which to install \(appName)."
        if panel.runModal() == .OK, let url = panel.url {
            state.installDir = url
            setPath(path, url.path)
            updateAvailable()
        }
    }
}

final class ComponentsPage: WizardPage {
    let view = NSView()
    let headerTitle = "Choose Components"
    let headerSubtitle = "Choose which features of \(appName) you want to install."
    let state: InstallState
    let game = HoverButton(checkboxWithTitle: "\(gameTitle) (Required)", target: nil, action: nil)
    let shortcut = HoverButton(checkboxWithTitle: "Desktop Shortcut", target: nil, action: nil)
    let steam = HoverButton(checkboxWithTitle: "Add to Steam Library", target: nil, action: nil)
    let saves = HoverButton(checkboxWithTitle: "Import Windows Saves", target: nil, action: nil)
    let steamPlay = HoverButton(checkboxWithTitle: "Steam Play Tool (needs NotProton)", target: nil, action: nil)
    let desc = label("Position your mouse over a component to see its description.", size: 11)

    init(state: InstallState) {
        self.state = state
        let top = label("Check the components you want to install and uncheck the components you don't want to install. Click Next to continue.")
        game.state = .on
        game.isEnabled = false
        shortcut.state = state.desktopShortcut ? .on : .off
        shortcut.target = self
        shortcut.action = #selector(changed)
        game.onHover = { [weak self] in self?.desc.stringValue = "Builds the game from your copy of \(gameTitle) and installs it" }
        shortcut.onHover = { [weak self] in self?.desc.stringValue = "Place a shortcut for the game onto the Desktop" }
        steam.state = state.steamShortcut ? .on : .off
        steam.target = self
        steam.action = #selector(changed)
        steam.onHover = { [weak self] in self?.desc.stringValue = "Add the game to your Steam for Mac library, so it can be started from Steam (Steam restarts once)" }
        saves.state = state.importSaves ? .on : .off
        saves.target = self
        saves.action = #selector(changed)
        saves.onHover = { [weak self] in self?.desc.stringValue = "Copy your saves from the Windows version (CrossOver or Whisky) into free save slots. Existing saves are kept and backed up." }

        steamPlay.state = state.steamPlay ? .on : .off
        steamPlay.target = self
        steamPlay.action = #selector(changed)
        steamPlay.onHover = { [weak self] in self?.desc.stringValue = "For NotProton users: Steam's own DOOM entry can start this port. Restart Steam, then choose it under DOOM > Properties > Compatibility." }

        let list = NSStackView(views: [game, shortcut, steam, saves, steamPlay])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        let descBox = NSBox()
        descBox.title = "Description"

        pin(top, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                              $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                              $0.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 14)] }
        let select = label("Select components to install:", wraps: false)
        pin(select, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                                 $0.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 18)] }
        pin(list, in: view) { [$0.leadingAnchor.constraint(equalTo: select.trailingAnchor, constant: 16),
                               $0.topAnchor.constraint(equalTo: select.topAnchor)] }
        pin(descBox, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                                  $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                                  $0.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 18),
                                  $0.heightAnchor.constraint(equalToConstant: 60)] }
        let content = descBox.contentView!
        pin(desc, in: content) { [$0.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                                  $0.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                                  $0.topAnchor.constraint(equalTo: content.topAnchor, constant: 4)] }
    }

    @objc func changed(_ sender: NSButton) { state.desktopShortcut = shortcut.state == .on; state.steamShortcut = steam.state == .on; state.importSaves = saves.state == .on; state.steamPlay = steamPlay.state == .on }
}

// Locates and verifies the user's copy of the game.
final class GameFilesPage: WizardPage {
    let view = NSView()
    let headerTitle = "\(gameTitle) Game Files"
    let headerSubtitle = "Setup needs your copy of the game to build \(appName)."
    let state: InstallState
    let path = NSTextField()

    init(state: InstallState) {
        self.state = state
        let top = label("Choose the DOOM folder from your Steam installation of \(gameTitle) (2016, the Windows version): the folder " +
                        "that contains DOOMx64vk.exe. It is only read: Setup translates the game's code on this Mac, and " +
                        "\(appName) loads the game data from this location. A copy found on this Mac is filled in; use Browse… to choose a different one.")
        let box = NSBox()
        box.title = "Your copy of the game (the folder with DOOMx64vk.exe)"
        pathField(path)
        let browse = NSButton(title: "Browse…", target: nil, action: nil)
        browse.target = self
        browse.action = #selector(browseClicked)

        pin(top, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                              $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                              $0.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 14)] }
        pin(box, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                              $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                              $0.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 16),
                              $0.heightAnchor.constraint(equalToConstant: 64)] }
        let content = box.contentView!
        pin(path, in: content) { [$0.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                                  $0.centerYAnchor.constraint(equalTo: content.centerYAnchor)] }
        pin(browse, in: content) { [$0.leadingAnchor.constraint(equalTo: self.path.trailingAnchor, constant: 8),
                                    $0.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                                    $0.centerYAnchor.constraint(equalTo: content.centerYAnchor)] }
    }

    func willShow() {
        if state.gameApp == nil { state.gameApp = detectGame() }
        setPath(path, state.gameApp?.path ?? "")
        useGameIcon(state.gameApp)
    }

    func canLeave() -> Bool {
        let alert = NSAlert()
        guard let app = state.gameApp, isGameApp(app) else {
            alert.messageText = "DOOMx64vk.exe was not found in the specified folder. Please choose your copy of \(gameTitle)."
            alert.runModal()
            return false
        }
        guard let sha = sha256(of: gameExecutable(app)), supportedSHA256.contains(sha) else {
            alert.messageText = "This copy of the game is not supported."
            alert.informativeText = "\(appName) supports the current Steam release and the experimental GOG profile of \(gameTitle) (2016) for Windows. " +
                                    "Make sure the game is fully downloaded and updated, and has not been modified."
            alert.runModal()
            return false
        }
        state.gameProfile = sha == "a32df8ffa042090f14fe0a200f1c5d7dddf9c947fac223916c252f826f1ecf11" ? "gog" : "steam"
        return true
    }

    @objc func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the DOOM folder: the one that contains DOOMx64vk.exe."
        panel.directoryURL = state.gameApp?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            state.gameApp = url
            setPath(path, url.path)
            useGameIcon(url)
        }
    }
}

final class InstallPage: WizardPage {
    let view = NSView()
    var headerTitle = "Installing"
    var headerSubtitle = "Please wait while \(appName) is being built and installed."
    let status = label("", wraps: false)
    let progress = NSProgressIndicator()
    let details = NSTextView()

    init() {
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        status.lineBreakMode = .byTruncatingMiddle
        // long build-output lines are truncated, never widen the window
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        details.autoresizingMask = [.width]
        scroll.documentView = details

        pin(status, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                                 $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                                 $0.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 14)] }
        pin(progress, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                                   $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                                   $0.topAnchor.constraint(equalTo: self.status.bottomAnchor, constant: 8)] }
        pin(scroll, in: view) { [$0.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
                                 $0.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
                                 $0.topAnchor.constraint(equalTo: self.progress.bottomAnchor, constant: 10),
                                 $0.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -10)] }
    }

    func log(_ line: String) {
        status.stringValue = line
        details.textStorage?.append(NSAttributedString(string: line + "\n", attributes: [.font: details.font!, .foregroundColor: NSColor.textColor]))
        details.scrollToEndOfDocument(nil)
    }
}

// MARK: - Installation

enum InstallError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let s) = self { return s }; return nil }
}

@discardableResult
func runTool(_ tool: String, _ args: [String], quiet: Bool = false) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if quiet { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func runAsAdmin(_ shell: String) throws {
    let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    if try runTool("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"]) != 0 {
        throw InstallError.failed("The installation was cancelled or the administrator password was not accepted.")
    }
}

func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

final class Installation {
    let state: InstallState
    let page: InstallPage

    init(state: InstallState, page: InstallPage) {
        self.state = state
        self.page = page
    }

    private func ui(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
    private func log(_ s: String) { ui { self.page.log(s) } }
    private func setProgress(_ v: Double) { ui { self.page.progress.doubleValue = v } }

    // Apple's Command Line Tools provide the compiler, make, ar and Python.
    private func requireCommandLineTools() throws {
        let ok = (try? runTool("/usr/bin/xcrun", ["--find", "clang"], quiet: true)) == 0 &&
                 (try? runTool("/usr/bin/xcrun", ["--find", "python3"], quiet: true)) == 0
        if ok { return }
        _ = try? runTool("/usr/bin/xcode-select", ["--install"], quiet: true)
        throw InstallError.failed("Apple's Command Line Tools are required. Install them from the window macOS just opened, then run Setup again.")
    }

    // Runs scripts/build.sh, streaming its output; "==> [n/6]" lines drive the progress bar.
    private func build(in source: URL, game: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [source.appendingPathComponent("scripts/build.sh").path, game.path]
        p.currentDirectoryURL = source
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var buffer = Data()
        let steps = 6.0
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                if line.hasPrefix("==> ["), let n = Double(line.dropFirst(5).prefix(while: { $0.isNumber })) {
                    self.setProgress(0.05 + 0.85 * (n - 1) / steps)
                }
                if !line.isEmpty { self.log(line) }
            }
        }
        try p.run()
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if p.terminationStatus != 0 {
            throw InstallError.failed("Building \(appName) failed. The details are listed above.")
        }
    }

    func run() throws {
        let fm = FileManager.default
        guard let game = state.gameApp else { throw InstallError.failed("No game selected.") }

        log("Checking for Apple's Command Line Tools")
        try requireCommandLineTools()

        // Fresh copy of the project source in the work folder.
        let work = InstallState.workDir
        let source = work.appendingPathComponent("source")
        log("Output folder: \(work.path)")
        if fm.fileExists(atPath: source.path) { try fm.removeItem(at: source) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.copyItem(at: state.sourceDir, to: source)
        setProgress(0.05)

        try build(in: source, game: game)

        // Install the app.
        let buildDir = state.gameProfile == "gog" ? "build-gog" : "build"
        let built = source.appendingPathComponent("\(buildDir)/\(gameAppName).app")
        let app = state.installedApp
        log("Output folder: \(state.installDir.path)")
        do {
            if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }
            try fm.copyItem(at: built, to: app)
        } catch {
            log("Copying \(gameAppName).app as administrator…")
            try runAsAdmin("rm -rf \(q(app.path)) && ditto \(q(built.path)) \(q(app.path))")
        }
        _ = try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], quiet: true)

        // Tell the app where the game is, so it does not have to ask.
        let config = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/doom-recomp")
        try? fm.createDirectory(at: config, withIntermediateDirectories: true)
        try? (game.path + "\n").write(to: config.appendingPathComponent("game-dir.txt"), atomically: true, encoding: .utf8)

        if state.desktopShortcut {
            let alias = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(gameAppName)")
            log("Create shortcut: \(alias.path)")
            try? fm.removeItem(at: alias)
            if let bookmark = try? app.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil) {
                try? URL.writeBookmarkData(bookmark, to: alias)
            }
        }

        if state.importSaves {
            log("Importing saves from the Windows version")
            _ = try? runTool("/usr/bin/python3", [source.appendingPathComponent("tools/import_saves.py").path], quiet: true)
        }
        if state.steamShortcut {
            log("Adding \(gameAppName) to the Steam library")
            _ = try? runTool("/usr/bin/python3", [source.appendingPathComponent("tools/steam_shortcut.py").path, "--app", app.path, "--restart-steam"], quiet: true)
        }

        if state.steamPlay {
            log("Registering the Steam Play tool")
            _ = try? runTool("/usr/bin/python3", steamPlayToolArgs(source) + ["--app", app.path], quiet: true)
        }

        // The translated code is only needed while building.
        log("Removing temporary build files")
        try? fm.removeItem(at: work)
        log("Completed")
        setProgress(1)
    }
}

// The Steam Play compatibility tool (framework/tools/steam_play_tool.py): Steam's DOOM entry starts this port
// when the user picks the tool, which needs NotProton to switch on Steam for Mac's compatibility tools.
func steamPlayToolArgs(_ source: URL) -> [String] {
    [source.appendingPathComponent("framework/tools/steam_play_tool.py").path, "--id", "doom_recomp",
     "--display", "DOOM Recomp (native Apple Silicon)", "--exe", "doomx64*.exe", "--force-exe", "DOOMx64vk.exe"]
}

// Removes the app, the desktop shortcut, the Steam Play tool and the build cache. Saved games and settings
// (~/Library/Application Support/doom-recomp) are kept.
func uninstall(window: NSWindow) {
    let fm = FileManager.default
    let apps = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("\(gameAppName).app") }
        .filter { fm.fileExists(atPath: $0.path) }

    let alert = NSAlert()
    if apps.isEmpty {
        alert.messageText = "\(gameTitle) was not found in Applications."
        alert.informativeText = "To remove it from another folder, drag it to the Trash."
        alert.beginSheetModal(for: window)
        return
    }
    alert.messageText = "Remove \(gameTitle)?"
    alert.informativeText = apps.map(\.path).joined(separator: "\n") +
        "\n\nYour saved games and settings for \(gameTitle) are kept."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        for app in apps {
            if (try? fm.removeItem(at: app)) == nil {
                try? runAsAdmin("rm -rf \(q(app.path))")
            }
        }
        try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(gameAppName)"))
        try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/compatibilitytools.d/doom_recomp"))
        try? fm.removeItem(at: InstallState.workDir)
        let done = NSAlert()
        done.messageText = "\(gameTitle) was successfully removed from your computer."
        done.beginSheetModal(for: window) { _ in NSApp.terminate(nil) }
    }
}

// MARK: - Wizard window

final class Wizard: NSObject, NSWindowDelegate {
    let state = InstallState()
    let window: NSWindow
    let header = NSView()
    let headerTitle = label("", bold: true, size: 13, wraps: false)
    let headerSubtitle = label("", wraps: false)
    let pageArea = NSView()
    let headerLine = NSBox()
    let back = NSButton(title: "< Back", target: nil, action: nil)
    let next = NSButton(title: "Next >", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)

    static weak var current: Wizard?
    let headerIcon = NSImageView()
    var pages: [WizardPage] = []
    var index = 0
    let installPage = InstallPage()
    var installing = false
    var finished = false

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        Wizard.current = self
        window.title = setupTitle
        window.delegate = self

        let welcome = WelcomePage(state: state)
        welcome.onUninstall = { [unowned self] in uninstall(window: self.window) }
        pages = [welcome, DirectoryPage(state: state), ComponentsPage(state: state), GameFilesPage(state: state), installPage]

        let root = window.contentView!
        // the window keeps its size whatever a page's labels contain (a long build line used to stretch it)
        NSLayoutConstraint.activate([root.widthAnchor.constraint(equalToConstant: 520),
                                     root.heightAnchor.constraint(equalToConstant: 400)])
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.white.cgColor
        headerTitle.textColor = .black
        headerSubtitle.textColor = .black
        let icon = headerIcon
        icon.image = NSApp.applicationIconImage
        pin(header, in: root) { [$0.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                 $0.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                 $0.topAnchor.constraint(equalTo: root.topAnchor),
                                 $0.heightAnchor.constraint(equalToConstant: 58)] }
        pin(headerTitle, in: header) { [$0.leadingAnchor.constraint(equalTo: self.header.leadingAnchor, constant: 16),
                                        $0.topAnchor.constraint(equalTo: self.header.topAnchor, constant: 11)] }
        pin(headerSubtitle, in: header) { [$0.leadingAnchor.constraint(equalTo: self.header.leadingAnchor, constant: 26),
                                           $0.topAnchor.constraint(equalTo: self.headerTitle.bottomAnchor, constant: 4)] }
        pin(icon, in: header) { [$0.trailingAnchor.constraint(equalTo: self.header.trailingAnchor, constant: -10),
                                 $0.centerYAnchor.constraint(equalTo: self.header.centerYAnchor),
                                 $0.widthAnchor.constraint(equalToConstant: 44), $0.heightAnchor.constraint(equalToConstant: 44)] }
        headerLine.boxType = .separator
        pin(headerLine, in: root) { [$0.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                     $0.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     $0.topAnchor.constraint(equalTo: self.header.bottomAnchor)] }

        let footerLine = NSBox()
        footerLine.boxType = .separator
        let brand = label(setupTitle, size: 10, wraps: false)
        brand.textColor = .tertiaryLabelColor
        for b in [back, next, cancel] { b.bezelStyle = .rounded; b.target = self }
        back.action = #selector(goBack)
        next.action = #selector(goNext)
        cancel.action = #selector(cancelClicked)
        next.keyEquivalent = "\r"
        pin(cancel, in: root) { [$0.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                                 $0.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
                                 $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)] }
        pin(next, in: root) { [$0.trailingAnchor.constraint(equalTo: self.cancel.leadingAnchor, constant: -12),
                               $0.centerYAnchor.constraint(equalTo: self.cancel.centerYAnchor),
                               $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)] }
        pin(back, in: root) { [$0.trailingAnchor.constraint(equalTo: self.next.leadingAnchor),
                               $0.centerYAnchor.constraint(equalTo: self.cancel.centerYAnchor),
                               $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)] }
        pin(brand, in: root) { [$0.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                                $0.bottomAnchor.constraint(equalTo: self.cancel.topAnchor, constant: -4)] }
        pin(footerLine, in: root) { [$0.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 6),
                                     $0.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     $0.centerYAnchor.constraint(equalTo: brand.centerYAnchor)] }

        pin(pageArea, in: root) { [$0.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                   $0.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                   $0.topAnchor.constraint(equalTo: root.topAnchor),
                                   $0.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -1)] }
        showPage()
        window.center()
    }

    func showPage() {
        let page = pages[index]
        pageArea.subviews.forEach { $0.removeFromSuperview() }
        let welcome = page.isWelcome
        header.isHidden = welcome
        headerLine.isHidden = welcome
        headerTitle.stringValue = page.headerTitle
        headerSubtitle.stringValue = page.headerSubtitle
        page.willShow()
        pin(page.view, in: pageArea) { [$0.leadingAnchor.constraint(equalTo: self.pageArea.leadingAnchor),
                                        $0.trailingAnchor.constraint(equalTo: self.pageArea.trailingAnchor),
                                        $0.topAnchor.constraint(equalTo: self.pageArea.topAnchor, constant: welcome ? 0 : 59),
                                        $0.bottomAnchor.constraint(equalTo: self.pageArea.bottomAnchor)] }
        back.isHidden = index == 0 || page === installPage
        next.title = index + 1 < pages.count && pages[index + 1] === installPage ? "Install" : "Next >"
        next.isEnabled = true
        if page === installPage { next.isEnabled = false; cancel.isEnabled = false }
    }

    @objc func goBack() {
        guard index > 0 else { return }
        index -= 1
        showPage()
    }

    @objc func goNext() {
        if finished { window.close(); return }
        guard pages[index].canLeave(), index + 1 < pages.count else { return }
        index += 1
        showPage()
        if pages[index] === installPage { startInstall() }
    }

    func startInstall() {
        installing = true
        let job = Installation(state: state, page: installPage)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try job.run() } catch { failure = error }
            DispatchQueue.main.async { self.installFinished(failure) }
        }
    }

    func installFinished(_ error: Error?) {
        installing = false
        finished = true
        if let error = error {
            installPage.log("Error: \(error.localizedDescription)")
            installPage.headerTitle = "Installation Aborted"
            installPage.headerSubtitle = "Setup was not completed successfully."
        } else {
            installPage.headerTitle = "Installation Complete"
            installPage.headerSubtitle = "Setup was completed successfully."
        }
        headerTitle.stringValue = installPage.headerTitle
        headerSubtitle.stringValue = installPage.headerSubtitle
        next.title = "Close"
        next.isEnabled = true
        cancel.isEnabled = false
        if error == nil {
            let play = NSButton(checkboxWithTitle: "Run \(gameTitle)", target: nil, action: nil)
            play.state = .on
            pin(play, in: window.contentView!) { [$0.leadingAnchor.constraint(equalTo: self.window.contentView!.leadingAnchor, constant: 20),
                                                  $0.centerYAnchor.constraint(equalTo: self.cancel.centerYAnchor)] }
            playCheckbox = play
        }
    }
    var playCheckbox: NSButton?

    @objc func cancelClicked() { window.performClose(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if installing { return false }
        if finished { return true }
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to quit \(appName) Setup?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        if finished, playCheckbox?.state == .on {
            NSWorkspace.shared.openApplication(at: state.installedApp, configuration: NSWorkspace.OpenConfiguration())
        }
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var wizard: Wizard?
    func applicationDidFinishLaunching(_ notification: Notification) {
        useGameIcon(detectGame())
        wizard = Wizard()
        wizard?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
