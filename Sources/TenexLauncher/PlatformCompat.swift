/// macOS shims for iOS-only SwiftUI APIs.
/// Allows the TenexMVP iOS sources to compile unchanged on macOS.

import SwiftUI
import AppKit
import Observation

// MARK: - navigationBarTitleDisplayMode (iOS-only modifier)

enum NavigationBarTitleDisplayMode {
    case inline, large, automatic
}

extension View {
    @ViewBuilder
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayMode) -> some View {
        self
    }
}

// MARK: - Toolbar placements (iOS-only)

#if os(macOS)
extension ToolbarItemPlacement {
    static var bottomBar: ToolbarItemPlacement { .automatic }
    static var topBarTrailing: ToolbarItemPlacement { .automatic }
    static var topBarLeading: ToolbarItemPlacement { .automatic }
}
#endif

// MARK: - ListStyle .insetGrouped (iOS-only → .inset on macOS)

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { .inset }
}

// MARK: - listSectionSpacing (iOS 17+, macOS unavailable)

extension View {
    @ViewBuilder
    func listSectionSpacing(_ spacing: CGFloat) -> some View {
        self
    }
}

// MARK: - SearchFieldPlacement.navigationBarDrawer (iOS-only)

#if os(macOS)
struct NavBarDrawerDisplayMode {
    static let automatic = NavBarDrawerDisplayMode()
    static let always = NavBarDrawerDisplayMode()
}

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: NavBarDrawerDisplayMode) -> SearchFieldPlacement {
        .automatic
    }
}
#endif

// MARK: - Text input autocapitalization (iOS-only)

enum TextInputAutocapitalization {
    case never, words, sentences, characters
}

enum UITextAutocapitalizationType {
    case none, words, sentences, allCharacters
}

extension View {
    @ViewBuilder
    func autocapitalization(_ style: UITextAutocapitalizationType) -> some View {
        self
    }

    @ViewBuilder
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
        self
    }
}

// MARK: - UIApplication background tasks (iOS-only)

#if os(macOS)
enum UIBackgroundTaskIdentifier: RawRepresentable {
    case invalid
    init(rawValue: Int) { self = .invalid }
    var rawValue: Int { 0 }
}

enum UIApplication {
    static let shared = UIApplicationShim()
}

struct UIApplicationShim {
    func beginBackgroundTask(expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        .invalid
    }
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}
}
#endif

// MARK: - DictationManager stub (iOS Speech APIs unavailable on macOS 14)

@MainActor
@Observable
final class DictationManager {
    enum State: Equatable {
        case idle
        case recording(partialText: String)

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    private(set) var state: State = .idle
    private(set) var finalText: String = ""
    private(set) var error: String?

    let phoneticLearner = PhoneticLearner()

    func startRecording() async throws {}
    func stopRecording() {}
    func cancelRecording() {}
    func reset() {
        state = .idle
        finalText = ""
        error = nil
    }
}

// MARK: - DictationOverlayView stub

struct DictationOverlayView: View {
    @Bindable var manager: DictationManager
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        Text("Dictation not available on macOS")
            .foregroundStyle(.secondary)
    }
}

// MARK: - CADisplayLink stub (iOS-only, used by FrameRateMonitor)

#if os(macOS)
@objc class CADisplayLink: NSObject {
    @objc var timestamp: CFTimeInterval = 0
    init(target: Any, selector: Selector) { super.init() }
    func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    func invalidate() {}
}
#endif

// MARK: - iOS system colors → macOS NSColor equivalents

extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var systemGroupedBackground: NSColor { .controlBackgroundColor }
    static var systemGray4: NSColor { .systemGray.withAlphaComponent(0.45) }
    static var systemGray5: NSColor { .systemGray.withAlphaComponent(0.35) }
    static var systemGray6: NSColor { .systemGray.withAlphaComponent(0.25) }
}

// MARK: - Color(uiColor:) → Color(nsColor:) bridge

extension Color {
    init(uiColor: NSColor) {
        self.init(nsColor: uiColor)
    }
}
