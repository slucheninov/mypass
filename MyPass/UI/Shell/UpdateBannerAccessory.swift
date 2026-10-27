import SwiftUI
import AppKit

/// Owns the update banner's native titlebar accessory on one window.
///
/// Why an accessory and not a SwiftUI inset or stacked row: the main window's content is a
/// `NavigationSplitView`, whose columns manage their own toolbar/safe-area inset. A
/// `safeAreaInset` on the whole split view does not shrink them (the sidebar and entry list
/// painted underneath the banner), and a row stacked above it leaves the toolbar's reserved
/// band empty. A bottom titlebar accessory is laid out by AppKit itself: it extends the
/// titlebar region, `contentLayoutRect` shrinks by exactly its height, and the split view
/// starts below it with no offsets computed here.
///
/// The accessory exists only while the banner is visible. An empty SwiftUI body inside a
/// still-attached accessory would keep its height, so hiding means removing it from the
/// window, and showing again installs a fresh one. The controller never retains the window.
@MainActor
final class UpdateBannerAccessoryController {
    private let makeContent: () -> AnyView
    private weak var window: NSWindow?
    private var accessory: NSTitlebarAccessoryViewController?

    init(content: @escaping () -> AnyView) {
        self.makeContent = content
    }

    /// Whether this controller currently has an accessory installed on its window.
    var isInstalled: Bool { installedIndex != nil }

    /// Brings the window's accessory in line with `isVisible`. Idempotent: repeated calls with
    /// the same arguments never add a second accessory, and a changed window first removes the
    /// accessory from the old one.
    func update(window newWindow: NSWindow?, isVisible: Bool) {
        if newWindow !== window {
            removeAccessory()
            window = newWindow
        }
        if isVisible, window != nil {
            installAccessory()
        } else {
            removeAccessory()
        }
    }

    /// Removes the accessory and forgets the window.
    func detach() {
        removeAccessory()
        window = nil
    }

    private var installedIndex: Int? {
        guard let window, let accessory else { return nil }
        return window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory })
    }

    private func installAccessory() {
        guard let window, accessory == nil else { return }
        let hostingView = NSHostingView(rootView: makeContent())
        // The banner's own height drives the accessory's height; no fixed number lives here.
        hostingView.sizingOptions = [.intrinsicContentSize]
        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .bottom
        controller.view = hostingView
        window.addTitlebarAccessoryViewController(controller)
        accessory = controller
    }

    private func removeAccessory() {
        if let window, let index = installedIndex {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        accessory = nil
    }
}

/// Zero-size view that reports the window it lives in and drives the accessory controller.
private struct UpdateBannerAccessoryAnchor: NSViewRepresentable {
    let isVisible: Bool
    let content: () -> AnyView

    func makeCoordinator() -> UpdateBannerAccessoryController {
        UpdateBannerAccessoryController(content: content)
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        let controller = context.coordinator
        view.onWindowChange = { [weak view, weak controller] window in
            controller?.update(window: window, isVisible: view?.isVisible ?? false)
        }
        view.isVisible = isVisible
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.isVisible = isVisible
        context.coordinator.update(window: view.window, isVisible: isVisible)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: UpdateBannerAccessoryController) {
        view.onWindowChange = nil
        coordinator.detach()
    }

    final class AnchorView: NSView {
        var isVisible = false
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

/// Puts the update banner into the main window's titlebar region while a newer release
/// exists. It observes the checker itself, so `ContentView` does not re-render for update
/// state. Both environment objects are re-injected into the accessory's hosting view, which
/// sits outside this view hierarchy and would otherwise not see them.
private struct UpdateBannerAccessoryModifier: ViewModifier {
    @EnvironmentObject private var updateChecker: AppUpdateChecker
    @EnvironmentObject private var vaultSession: VaultSession

    func body(content: Content) -> some View {
        content.background(anchor)
    }

    private var anchor: some View {
        UpdateBannerAccessoryAnchor(
            isVisible: updateChecker.bannerText != nil,
            content: {
                AnyView(
                    UpdateBannerView()
                        .environmentObject(updateChecker)
                        .environmentObject(vaultSession)
                )
            }
        )
        .frame(width: 0, height: 0)
    }
}

extension View {
    /// Shows `UpdateBannerView` as a native bottom titlebar accessory of the hosting window.
    func updateBannerAccessory() -> some View {
        modifier(UpdateBannerAccessoryModifier())
    }
}
