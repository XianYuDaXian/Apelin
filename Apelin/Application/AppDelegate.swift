import AlertController
import ApelinCore
import ApelinProtocol
import UIKit

/// Not `@main`: `main.swift` clears saved scenes before `UIApplicationMain`.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?,
    ) -> Bool {
        ExecutableWatch.start {
            let alert = UIAlertController(
                title: String(localized: "Apelin Updated or Removed"),
                message: String(localized: "Quit to apply the change, or keep using this version for now."),
                preferredStyle: .alert,
            )
            alert.addAction(UIAlertAction(title: String(localized: "Later"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "Quit"), style: .destructive) { _ in
                QuietExit.run()
            })
            Self.presentWhenActive(alert, in: application)
        }
        AppJournal.start()
        ConversationNotices.start()
        // the progress card and the alerts carry the app's icon, as Fila's do
        AlertControllerConfiguration.alertImage = UIImage(named: "AppIconMark")
        // the app's own accent (`AppAccent`); the library's default is red
        AlertControllerConfiguration.accentColor = AppAccent.color(glass: .systemBlue)
        AlertControllerConfiguration.accentForegroundColor = AppAccent.foreground(glass: .white)
        ConsoleLaunch.start()
        return true
    }

    /// A quit takes the Live Activity with it: nothing would update it
    /// after (`ChatWidgetPublisher.endActivitiesForQuit`).
    func applicationWillTerminate(_: UIApplication) {
        ChatWidgetPublisher.endActivitiesForQuit()
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The watch fires once, and may fire with no scene active: at launch,
    /// in the background, or on resume before the scene activates. The
    /// notice then waits for the next activation instead of being lost.
    private static func presentWhenActive(_ alert: UIAlertController, in application: UIApplication) {
        let active = application.connectedScenes.first { $0.activationState == .foregroundActive }
        guard let scene = active as? UIWindowScene else {
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    presentWhenActive(alert, in: application)
                }
            }
            return
        }
        // In front of whatever the scene shows: a root already presenting a
        // sheet or another alert would drop it.
        guard var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(alert, animated: true)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions,
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = AppAccent.windowTint
        window.rootViewController = RootInterfaceController()
        window.makeKeyAndVisible()
        self.window = window
        // A cold launch by Open in Apelin or an `apelin://` link: the URL
        // comes with the scene. Opened on the next turn, once the root is on
        // screen to present from.
        DispatchQueue.main.async { [weak self] in self?.openURLs(connectionOptions.urlContexts, in: scene) }
    }

    /// Open in Apelin, or an `apelin://` link, while the app runs.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let scene = scene as? UIWindowScene else { return }
        openURLs(contexts, in: scene)
    }

    /// An `apelin://` link goes to its conversation or project
    /// (`ApelinLinkRouter`); a transfer file is imported by its page; any
    /// other file was opened with Apelin from Filza, Fila, Files or a share
    /// sheet, and becomes an attachment on a conversation (`SampleInbox`).
    /// One link or transfer at a time: a second sheet could not be presented
    /// over the first.
    private func openURLs(_ contexts: Set<UIOpenURLContext>, in scene: UIWindowScene) {
        var samples: [URL] = []
        var showedTransfer = false
        for context in contexts {
            let url = context.url
            if ApelinLinkRouter.open(url, in: scene) {
                continue
            }
            if TransferKind(fileName: url.lastPathComponent) != nil {
                // one page at a time: a second could not be presented over
                // the first
                if !showedTransfer {
                    showedTransfer = true
                    TransferOpener.open(url, in: scene)
                }
                continue
            }
            samples.append(url)
        }
        guard !samples.isEmpty else { return }
        receive(samples, in: scene)
    }

    /// Copies each file out of its opener's shelf first (`SampleInbox`), then
    /// hands the copies to the conversation page, where they join the shown
    /// conversation's composer. The copy runs off the main thread: a share
    /// can be tens of megabytes, and the open call has already returned.
    private func receive(_ urls: [URL], in scene: UIWindowScene) {
        guard let root = Self.rootInterface(in: scene) else { return }
        let folder = DataFolder.app.root
        Task { @MainActor in
            var staged: [StagedSample] = []
            var problems: [String] = []
            for url in urls {
                do {
                    let sample = try await Task.detached(priority: .userInitiated) {
                        try SampleInbox.stage(url, in: folder)
                    }.value
                    staged.append(sample)
                } catch {
                    problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !staged.isEmpty {
                root.receiveSamples(staged)
            }
            if !problems.isEmpty {
                root.presentNotice(title: "Unable to Import File", message: problems.joined(separator: "\n"))
            }
        }
    }

    /// The page that shows the conversations, whichever window carries it.
    private static func rootInterface(in scene: UIWindowScene) -> RootInterfaceController? {
        let scenes = [scene] + UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.lazy.flatMap(\.windows).compactMap { $0.rootViewController as? RootInterfaceController }.first
    }
}
