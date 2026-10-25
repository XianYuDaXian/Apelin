import ApelinProtocol
import ListViewKit
import SnapKit
import SPIndicator
import UIKit

/// The conversation page, the detail column's root while one is picked.
/// There is one, made once: picking another conversation hands it that
/// conversation (`use(_:)`), which rolls the title on the bar to the new
/// name, replaces the message list and restores that conversation’s draft.
/// Each conversation gets a fresh list and its own scrolling state.
///
/// The messages fill the page; the composer sits at its foot, on the
/// keyboard when it is up, no wider than 750 pt and centred, and the list
/// scrolls clear of it.
final class ChatController: UIViewController {
    /// The conversation shown, nil until the first is picked.
    private(set) var chat: ChatSummary?

    var runtime: ChatRuntime!
    private let titleView = ChatTitleView()
    private var messageList = ListView<ChatMessage>()
    private let composer = ComposerView()
    /// Behind the composer and down past the page's edge, so the list does
    /// not show beside or under it, with a hairline along its top.
    private let composerBackground = UIView()
    private let composerSeparator = UIView()
    private let topBlur = ChatTopBlurView()
    private let latestMessageButton = UIButton(type: .system)
    private weak var reasoningPage: ChatReasoningController?
    /// Builds the rows again once a running turn has gone quiet.
    private let quietWatch = ChatQuietWatch()

    /// The shown conversation's rows as last applied.
    private var messages: [ChatMessage] = []
    /// The message the shown conversation's latest turn started with; a
    /// different one starts a new turn.
    private var turnMessage: UUID?
    /// The turn whose output the list follows (`TurnFollowing`): nil once
    /// a fast reply has brought its message to the top of the visible area,
    /// or the reader dragged, until the next turn.
    private var followedTurn: UUID?
    /// How fast the followed turn's reply streams.
    private var turnPace = TurnFollowing.Pace()
    /// The request the composer shows in place of the input, and the
    /// conversation its Stop stops. Each change to either lays the whole
    /// window out on the composer's spring, so the composer is told only of
    /// a change, never again on every streamed batch.
    private var shownApproval: ChatMessage?
    /// A root request whose owner check is on screen: a second tap on
    /// Approve does not ask again.
    private var checkingOwner: UUID?
    private var stoppableChat: UUID?
    /// While `use(_:)` swaps another conversation in: nothing animates, and
    /// the list's opening scroll waits for its rows.
    private var isSwitchingChat = false
    private var needsInitialScroll = false
    /// Whether the reader was at the latest message when the page last
    /// changed width — the sidebar opening or closing. The rows wrap again
    /// and the content's height changes under the list, so the list is put
    /// back at its end, and kept there as the rows above are measured again,
    /// until the reader drags it.
    private var holdsLatestMessage = false
    private var lastLayoutWidth: CGFloat = 0
    private var modelLoader: Task<Void, Never>?
    private var selectionCheck: Task<Void, Never>?
    private var attachmentImport: ComposerAttachmentImport?
    /// A retry is on its way to the session; another tap waits for it.
    private var isRetrying = false
    private var modelButton: UIButton {
        composer.modelBar.button
    }

    private var attachmentHeightLimit: CGFloat {
        (view.window?.bounds.height ?? view.bounds.height) * 0.3
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        navigationItem.titleView = titleView
        navigationItem.largeTitleDisplayMode = .never
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: nil)
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak more] completion in
            guard let self, let more, let chat else { completion([]); return }
            ChatActions.menu(
                for: chat,
                runtime: runtime,
                from: self,
                anchor: more,
                onPrepareDistribution: { [weak self] prompt in self?.sendPrompt(prompt) },
                completion: completion,
            )
        }])
        more.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItem = more
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .pageBackground

        replaceMessageList()
        view.addSubview(topBlur)

        composerBackground.backgroundColor = .pageBackground
        composerSeparator.backgroundColor = .separator
        composerBackground.addSubview(composerSeparator)
        composerSeparator.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview()
            make.height.equalTo(1 / max(traitCollection.displayScale, 1))
        }
        view.addSubview(composerBackground)

        composer.delegate = self
        composer.approvalSection.onDecision = { [weak self] request, decision in
            guard let self, let chat else { return }
            Task { await self.decide(request, decision, in: chat.id) }
        }
        composer.modelBar.onEffortChanged = { ComposerModelPreferences.effort = $0 }
        composer.modelBar.onTierChanged = { ComposerModelPreferences.tier = $0 }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateModelSelection),
            name: .composerModelSelectionChanged,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(enabledModelsChanged),
            name: .enabledModelsChanged,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(withdrawNotifications),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )
        updateModelSelection()
        modelButton.showsMenuAsPrimaryAction = true
        modelButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            loadModelMenu(completion: completion)
        }])
        view.addSubview(composer)
        composer.snp.makeConstraints { make in
            if #available(iOS 17.0, *) {
                // Above a keyboard, the gap the bands keep between
                // themselves; without one, the safe area's own edge.
                view.keyboardLayoutGuide.usesBottomSafeArea = false
                make.bottom.lessThanOrEqualTo(view.keyboardLayoutGuide.snp.top).offset(-composer.spacing)
                make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide)
                make.bottom.equalTo(view.safeAreaLayoutGuide).priority(.high)
            } else {
                make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
            }
            make.centerX.equalToSuperview()
            make.width.lessThanOrEqualTo(750)
            make.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide)
            make.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide)
            make.width.equalToSuperview().priority(.low)
        }
        composerBackground.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            // past the bottom, for the keyboard's bounce
            make.bottom.equalToSuperview().offset(128)
            make.top.equalTo(composer.snp.top).offset(-4)
        }

        var latestConfiguration: UIButton.Configuration = if #available(iOS 26, *) {
            .glass()
        } else {
            .gray()
        }
        latestConfiguration.image = UIImage(systemName: "chevron.down")
        latestConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 17,
            weight: .semibold,
        )
        latestConfiguration.baseForegroundColor = .label
        latestConfiguration.cornerStyle = .capsule
        latestMessageButton.configuration = latestConfiguration
        latestMessageButton.accessibilityLabel = String(localized: "Scroll to latest message")
        latestMessageButton.isHidden = true
        latestMessageButton.alpha = 0
        latestMessageButton.addAction(UIAction { [weak self] _ in
            self?.revealLatestMessage()
        }, for: .touchUpInside)
        view.addSubview(latestMessageButton)
        latestMessageButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(composerBackground.snp.top).offset(-8)
            make.size.equalTo(44)
        }
    }

    private func replaceMessageList() {
        let contentInset = messageList.contentInset
        let indicatorInset = messageList.verticalScrollIndicatorInsets
        messageList.delegate = nil
        messageList.layer.mask = nil
        messageList.removeFromSuperview()
        messageList = ListView<ChatMessage>()
        messageList.frame = view.bounds
        messageList.contentInset = contentInset
        messageList.verticalScrollIndicatorInsets = indicatorInset
        messageList.backgroundColor = .clear
        messageList.keyboardDismissMode = .interactive
        messageList.delegate = self
        messageList.rows {
            ListRow(ChatActivityRow.self)
                .when { $0.role.isActivity }
                .height { message, context in ChatActivityRow.height(for: message, width: context.width) }
                .configure { [weak self] row, message, _ in
                    row.show(message)
                    row.onToggle = { [weak self] in
                        guard let self else { return }
                        if case .thinking = message.role {
                            let page = ChatReasoningController(message: message)
                            reasoningPage = page
                            presentPageAsFormSheet(page)
                        }
                    }
                }
            ListRow(ChatMessageRow.self)
                .height { [weak self] message, context in
                    ChatMessageRow.height(
                        for: message,
                        width: context.width,
                        maximumAttachmentHeight: self?.attachmentHeightLimit ?? 0,
                    )
                }
                .configure { [weak self] row, message, _ in
                    let chatID = self?.chat?.id
                    row.attachmentHeightLimit = self?.attachmentHeightLimit ?? 0
                    row.show(message, isStreaming: self?.chat?.isWorking == true)
                    row.onRetry = { [weak self] in self?.retryLastAnswer() }
                    row.onAttachmentLayoutChanged = { [weak self] in
                        guard let self, chat?.id == chatID else { return }
                        messageList.reconfigureRow(with: message.id)
                        messageList.invalidateLayout(forRowWith: message.id)
                    }
                    row.onPreview = { [weak self] item in self?.onComposerPreviewAttachment(item) }
                    row.onPreviewImages = { [weak self] images, selectedID in
                        do {
                            try self?.present(
                                ComposerAttachmentPreview(attachments: images, selectedID: selectedID),
                                animated: true,
                            )
                        } catch {
                            self?.presentNotice(title: "Unable to Preview Attachment", message: error.readableMessage)
                        }
                    }
                }
        }
        view.insertSubview(messageList, at: 0)
        // The composer is another overlay; explicitly identify the list
        // whose scroll position drives the navigation bar's edge treatment.
        setContentScrollView(messageList, for: .top)
        if #available(iOS 26, *) {
            messageList.topEdgeEffect.isHidden = true
        }
        messageList.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // read before the list takes the new width
        let width = view.bounds.width
        guard width != lastLayoutWidth else { return }
        if lastLayoutWidth > 0, !needsInitialScroll, distanceFromLatestMessage <= 2 {
            holdsLatestMessage = true
        }
        lastLayoutWidth = width
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateMessageListInsets()
        // Not while `use(_:)` is still swapping the conversation in:
        // restoring its draft lays the window out before its rows are in the
        // list, and a pass then would find the new list empty, take that for
        // its end, and leave the page where the estimated heights put the
        // end — a long chat's middle. `use(_:)` asks for the pass after.
        if needsInitialScroll, !isSwitchingChat, view.window != nil, messageList.bounds.width > 0,
           messageList.bounds.height > 0
        {
            needsInitialScroll = false
            // The list measures newly visible rows during layout. Settle
            // those measurements at the end too, before the page is revealed.
            // Each advancing pass measures another row. A clamp or an
            // asynchronous attachment must not keep the main thread here;
            // leave the request pending for its next real layout instead.
            for _ in 0 ... messageList.content.count {
                let previousOffset = messageList.contentOffset.y
                let previousEnd = messageList.maximumContentOffset.y
                messageList.scrollToBottom(animated: false)
                messageList.layoutIfNeeded()
                if abs(messageList.contentOffset.y - messageList.maximumContentOffset.y) <= 0.5 {
                    break
                }
                if abs(messageList.contentOffset.y - previousOffset) <= 0.5,
                   abs(messageList.maximumContentOffset.y - previousEnd) <= 0.5
                {
                    break
                }
            }
            needsInitialScroll = abs(messageList.contentOffset.y - messageList.maximumContentOffset.y) > 0.5
        }
        if holdsLatestMessage {
            messageList.layoutIfNeeded()
            holdLatestMessage()
        }
        updateLatestMessageButton()
        topBlur.frame = CGRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: min(view.bounds.height, view.safeAreaInsets.top + 20),
        )
    }

    /// Shows `chat`. The same conversation again only takes its new name;
    /// another one also swaps the messages and the draft.
    func use(_ chat: ChatSummary) {
        loadViewIfNeeded()
        let previous = self.chat
        self.chat = chat
        ConversationNotices.shared.withdraw(session: runtime.records[chat.id]?.sessionID)
        updateModelSelection()
        ensureModelSelection()
        title = chat.displayTitle
        // rolled only on screen; a page coming back shows its name at once
        titleView.setTitle(chat.displayTitle, animated: previous != nil && view.window != nil)
        guard previous?.id != chat.id else { return }
        isSwitchingChat = true
        needsInitialScroll = true
        holdsLatestMessage = false
        defer { isSwitchingChat = false }
        replaceMessageList()

        if let previous {
            runtime.saveDraft(composer.draft, for: previous.id)
        }
        let draft = runtime.records[chat.id]?.draft ?? ComposerDraft()
        composer.restore(draft: draft)
        messages = runtime.transcript(chat.id).messages
        // A turn still running is followed again, its pace measured afresh.
        turnMessage = TurnFollowing.turnMessage(in: messages)
        followedTurn = runtime.records[chat.id]?.summary.isWorking == true ? turnMessage : nil
        turnPace = TurnFollowing.Pace()
        showTranscript(messages)
        refreshRuntime()
        messageList.scrollToBottom(animated: false)
        updateLatestMessageButton()
        // the opening pass, now that the rows are in (`viewDidLayoutSubviews`)
        view.setNeedsLayout()
    }

    /// Back in front with this conversation on screen: its banners have
    /// said what they had to.
    @objc private func withdrawNotifications() {
        guard let chat, view.window != nil else { return }
        ConversationNotices.shared.withdraw(session: runtime.records[chat.id]?.sessionID)
    }

    func refreshRuntime() {
        guard let chat else { return }
        if let summary = runtime.records[chat.id]?.summary {
            self.chat = summary
            if title != summary.displayTitle {
                // a rename, or the agent's title: the back button's too
                title = summary.displayTitle
            }
            titleView.setTitle(summary.displayTitle, animated: view.window != nil)
            let transcript = runtime.transcript(chat.id)
            updateMessages(transcript.messages)
            quietWatch.wake(at: transcript.quietDeadline) { [weak self] in self?.refreshRuntime() }
            if summary.isWorking != chat.isWorking {
                // the session stopped (or came back) with no event that redraws the request
                showApproval(summary.isWorking ? messages.first { $0.role.needsApproval } : nil)
            }
            let stoppable = summary.isWorking ? chat.id : nil
            if stoppable != stoppableChat {
                stoppableChat = stoppable
                composer.modelBar.setOutputCancellation(summary.isWorking ? { [weak self] in
                    guard let self else { return }
                    Task {
                        do { try await self.runtime.stop(chat.id) }
                        catch { self.presentNotice(title: "Unable to Stop", message: error.readableMessage) }
                    }
                } : nil)
            }
        }
    }

    /// Sends the reader's decision. Approving a command as root first asks
    /// for Face ID, Touch ID or the passcode (`DeviceOwnerCheck`); when that
    /// does not pass, nothing is sent and the request goes on waiting.
    private func decide(_ request: ChatMessage, _ decision: ApprovalDecision, in chatID: UUID) async {
        var ownerVerified: Bool?
        if decision == .approve, request.runsAsRoot {
            guard checkingOwner == nil else { return }
            checkingOwner = request.id
            let confirmed = await DeviceOwnerCheck.confirm(
                reason: String(localized: "Approve a command that runs as root on this device."),
            )
            checkingOwner = nil
            guard confirmed else {
                SPIndicator.present(
                    title: String(localized: "Not Approved"),
                    message: String(localized: "The request is still waiting."),
                    preset: .error,
                    haptic: .error,
                )
                return
            }
            ownerVerified = true
        }
        do {
            try await runtime.approve(request.id, in: chatID, decision: decision, ownerVerified: ownerVerified)
        } catch {
            presentNotice(title: "Unable to Send Decision", message: error.readableMessage)
        }
    }

    private func showApproval(_ request: ChatMessage?) {
        guard request != shownApproval else { return }
        shownApproval = request
        composer.showApproval(request)
    }

    /// A new user message starts a turn, whose output the list then follows
    /// (`followTurn`), timing its reply as it streams.
    private func updateMessages(_ items: [ChatMessage]) {
        guard messages != items else { return }
        messages = items
        let message = TurnFollowing.turnMessage(in: items)
        if message != turnMessage {
            turnMessage = message
            followedTurn = message
            turnPace = TurnFollowing.Pace()
        }
        if let followedTurn {
            turnPace.observe(tokens: TurnFollowing.replyTokens(in: items, after: followedTurn), at: CACurrentMediaTime())
        }
        showTranscript(items)
        followTurn()
        updateLatestMessageButton()
    }

    /// Moves the list with the followed turn's output: to its end while the
    /// reply streams no faster than a reader keeps up with. A faster one is
    /// followed until the turn's message reaches the top of the visible
    /// area, under the bar's blur, and the list then holds still for the
    /// rest of the turn.
    private func followTurn() {
        guard let followed = followedTurn, !messageList.isTracking, !messageList.isDecelerating else { return }
        let animated = !isSwitchingChat && !needsInitialScroll && !UIAccessibility.isReduceMotionEnabled
        let move = TurnFollowing.move(
            pace: turnPace,
            offset: messageList.contentOffset.y,
            latest: messageList.maximumContentOffset.y,
            messageTop: messageList.rectForRow(with: followed).minY,
            topInset: max(messageList.adjustedContentInset.top, topBlur.frame.maxY),
        )
        switch move {
        case .latest:
            messageList.scrollToBottom(animated: animated)
        case let .stop(offset):
            followedTurn = nil
            messageList.setContentOffset(CGPoint(x: messageList.contentOffset.x, y: offset), animated: animated)
        }
    }

    /// Shows the newest content, once: the turn is not followed again.
    private func revealLatestMessage() {
        messageList.scrollToBottom(animated: !UIAccessibility.isReduceMotionEnabled)
        updateLatestMessageButton()
    }

    private func showTranscript(_ items: [ChatMessage]) {
        if let page = reasoningPage, let message = items.first(where: { $0.id == page.messageID }) {
            page.show(message)
        }
        let visible = items.filter { !$0.role.isApproval }
        messageList.apply(visible, animated: !isSwitchingChat && !UIAccessibility.isReduceMotionEnabled)
        // a request its stopped session left can no longer be answered
        showApproval(chat?.isWorking == true ? items.first { $0.role.needsApproval } : nil)
    }

    @objc private func updateModelSelection() {
        let selection = ComposerModelSelection.current
        composer.modelBar.setModelName(selection?.model)
        composer.modelBar.setEfforts(selection?.supportedEfforts ?? [], selected: selection?.effort)
        composer.modelBar.setTiers(selection?.supportedTiers ?? [], selected: selection?.tier)
    }

    /// A model disabled in Settings stops being the one the next message uses.
    @objc private func enabledModelsChanged() {
        ensureModelSelection()
    }

    /// The list scrolls clear of the composer, and of the keyboard under it.
    private func updateMessageListInsets() {
        let covered = max(view.bounds.height - composerBackground.frame.minY, 0)
        let bottom = max(covered - view.safeAreaInsets.bottom, 0)
        if messageList.contentInset.bottom != bottom + 16 {
            // a reader at the latest message, or following a turn, stays there
            let keepsLatest = followedTurn != nil || distanceFromLatestMessage <= 2
            messageList.contentInset.bottom = bottom + 16
            if keepsLatest, !messageList.isTracking, !messageList.isDecelerating {
                if UIView.inheritedAnimationDuration > 0 {
                    // The composer is springing to a new height: the list
                    // rides the same animation. `scrollToBottom(animated:
                    // false)` would jump there ahead of it, since ListView
                    // keeps its own placements out of a caller's animation;
                    // the public setter is the one it leaves to the host.
                    messageList.contentOffset = messageList.maximumContentOffset
                } else {
                    // Opening and keyboard layout place the list immediately;
                    // only a new transcript update animates following output.
                    messageList.scrollToBottom(animated: false)
                }
            }
        }
        if messageList.verticalScrollIndicatorInsets.bottom != bottom {
            messageList.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    /// The menu re-reads enabled accounts each time, including after setup.
    private func loadModelMenu(completion: @escaping ([UIMenuElement]) -> Void) {
        guard let chat else { completion([]); return }
        modelLoader?.cancel()
        modelLoader = Task { [weak self] in
            guard let self else { completion([]); return }
            do {
                let accounts = try await EnabledModels.accounts(from: ApelinService.app.agentAccountList().accounts)
                guard !Task.isCancelled, self.chat?.id == chat.id else { completion([]); return }
                guard !accounts.isEmpty else {
                    completion([])
                    DispatchQueue.main.async { [weak self] in
                        guard let self, presentedViewController == nil else { return }
                        presentPageAsFormSheet(ModelProvidersController())
                    }
                    return
                }
                let selected = ComposerModelSelection.current
                completion(accounts.map { account in
                    UIMenu(title: account.account ?? account.provider.displayName, options: .displayInline,
                           children: (account.models ?? []).map { model in
                               let checked = account.provider == selected?.provider && model == selected?.model
                               return UIAction(title: model, state: checked ? .on : .off) { _ in
                                   ComposerModelSelection.current = Self.selection(of: model, in: account)
                               }
                           })
                })
            } catch {
                completion([])
                guard !Task.isCancelled, self.chat?.id == chat.id else { return }
                presentNotice(title: "Models Unavailable", message: error.readableMessage)
            }
        }
    }
}

extension ChatController {
    /// `model` of `account` with what the catalog says it offers. The
    /// reader's effort and speed are kept apart (`ComposerModelPreferences`),
    /// so picking a model that lacks them does not lose them.
    private static func selection(of model: String, in account: AgentAccount) -> ComposerModelSelection {
        ComposerModelSelection(
            provider: account.provider,
            model: model,
            supportedEfforts: (account.reasoningEfforts?[model] ?? []).filter { [.low, .high, .max].contains($0) },
            supportedTiers: account.serviceTiers?[model] ?? [],
        )
    }

    /// With no model picked, or one no longer enabled, the first enabled
    /// model is picked; with none enabled the bar keeps asking. A model
    /// still enabled takes the catalog's efforts and tiers again. A
    /// signed-in account whose sign-in did not read this time lists no
    /// models; its model is kept rather than swapped for another's.
    func ensureModelSelection() {
        selectionCheck?.cancel()
        selectionCheck = Task {
            guard let listed = try? await ApelinService.app.agentAccountList().accounts,
                  !Task.isCancelled
            else { return }
            let accounts = EnabledModels.accounts(from: listed)
            if let current = ComposerModelSelection.current {
                if let account = accounts.first(where: { account in
                    account.provider == current.provider && (account.models ?? []).contains(current.model)
                }) {
                    let refreshed = Self.selection(of: current.model, in: account)
                    if refreshed != current {
                        ComposerModelSelection.current = refreshed
                    }
                    return
                }
                if listed.contains(where: { $0.provider == current.provider && $0.signedIn && $0.models == nil }) {
                    return
                }
            }
            guard let account = accounts.first, let model = account.models?.first else { return }
            ComposerModelSelection.current = Self.selection(of: model, in: account)
        }
    }

    /// The runtime put `id`'s draft back, or emptied it: a message its run
    /// never took, a send that failed, or a returned one the host had taken.
    func restoreDraft(for id: UUID) {
        guard chat?.id == id, let draft = runtime.records[id]?.draft else { return }
        composer.restore(draft: draft)
    }

    /// `text` as the reader's next message, as if typed and sent; during a
    /// reply, the run takes it at its next step.
    func sendPrompt(_ text: String) {
        guard chat != nil else { return }
        onComposerSubmit(draft: ComposerDraft(text: text)) {}
    }

    /// Asks the session to drop its last reply and answer again; the list
    /// drops the old row when the session's `regenerated` event arrives.
    func retryLastAnswer() {
        guard let chat, !chat.isWorking, !isRetrying else { return }
        isRetrying = true
        let id = chat.id
        Task {
            defer { isRetrying = false }
            do {
                try await runtime.regenerate(id)
            } catch {
                presentNotice(title: "Unable to Try Again", message: error.readableMessage)
            }
        }
    }

    /// Files another app opened with Apelin (`SampleInbox`), for this
    /// conversation's composer. Each is read here, where its draft is, and
    /// its staged copy is removed once it is attached; one that cannot be
    /// attached stays where the notice names it.
    func receiveSamples(_ samples: [StagedSample]) {
        guard let chat, !samples.isEmpty else { return }
        let chatID = chat.id
        let draftID = composer.draft.id
        Task { @MainActor in
            var problems: [String] = []
            for sample in samples {
                do {
                    let attachment = try await Task.detached(priority: .userInitiated) {
                        try ComposerAttachmentImport.readAttachment(at: sample.url, name: sample.name)
                    }.value
                    if insert(attachment, in: chatID, draft: draftID) {
                        try? FileManager.default.removeItem(at: sample.url.deletingLastPathComponent())
                    }
                } catch {
                    problems.append("\(sample.name): \(error.readableMessage)\n\(sample.url.path)")
                }
            }
            if !problems.isEmpty {
                presentNotice(title: "Unable to Import File", message: problems.joined(separator: "\n"))
            }
        }
    }

    /// `attachment` joins `chatID`'s composer when it is the one on the page,
    /// else its saved draft, as a picker's does. False when neither took it,
    /// and the staged copy is kept.
    private func insert(_ attachment: ComposerAttachment, in chatID: UUID, draft draftID: UUID) -> Bool {
        if chat?.id == chatID, composer.draft.id == draftID {
            composer.insertAttachment(attachment)
            return true
        }
        if var draft = runtime.records[chatID]?.draft, draft.id == draftID {
            draft.attachments.append(attachment)
            runtime.saveDraft(draft, for: chatID)
            return true
        }
        return false
    }
}

extension ChatController: ComposerView.Delegate {
    func onComposerSubmit(draft: ComposerDraft, completion: @escaping @MainActor () -> Void) {
        guard let chat else {
            completion()
            return
        }
        ConversationNotices.shared.requestAuthorizationIfNeeded()
        // shown at once; the runtime puts the draft back if the send fails
        let sending = runtime.submit(draft, to: chat.id)
        // One a running turn takes later starts no turn yet: shown once.
        if let row = messages.last, row.id == draft.id, row.isQueued {
            revealLatestMessage()
        }
        Task {
            defer { completion() }
            do {
                try await sending.value
            } catch {
                presentNotice(title: "Unable to Send Message", message: error.readableMessage)
            }
        }
    }

    func onComposerBeginEditing() {
        ensureModelSelection()
    }

    func onComposerUpdateDraft(_ draft: ComposerDraft) {
        guard let chat else { return }
        runtime.saveDraft(draft, for: chat.id)
    }

    func onComposerCameraTapped() {
        importer()?.camera()
    }

    func onComposerPhotoTapped() {
        importer()?.photos()
    }

    func onComposerFileTapped() {
        importer()?.files()
    }

    func onComposerWebTapped() {
        importer()?.web()
    }

    func onComposerPasteAsAttachmentTapped() {
        importer()?.paste()
    }

    func onComposerPastedLongText(_ text: String) {
        importer()?.importText(text)
    }

    func onComposerPastedImage(_ image: UIImage) {
        importer()?.importImage(image)
    }

    func onComposerDropped(_ providers: [NSItemProvider]) {
        importer()?.drop(providers)
    }

    func onComposerPreviewAttachment(_ attachment: ComposerAttachment) {
        do { try present(ComposerAttachmentPreview(attachment: attachment), animated: true) }
        catch { presentNotice(title: "Unable to Preview Attachment", message: error.readableMessage) }
    }

    private func importer() -> ComposerAttachmentImport? {
        guard let chat, presentedViewController == nil else { return nil }
        let draftID = composer.draft.id
        let importer = ComposerAttachmentImport(presenter: self) { [weak self] item in
            guard let self else { return }
            if self.chat?.id == chat.id, composer.draft.id == draftID {
                composer.insertAttachment(item)
            } else if var draft = runtime.records[chat.id]?.draft, draft.id == draftID {
                draft.attachments.append(item)
                runtime.saveDraft(draft, for: chat.id)
            }
        }
        attachmentImport = importer
        return importer
    }
}

extension ChatController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_: UIScrollView) {
        holdsLatestMessage = false
        // The reader has the list: only the next turn is followed again.
        followedTurn = nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !scrollView.isTracking, !scrollView.isDecelerating {
            holdLatestMessage()
        }
        updateLatestMessageButton()
    }

    private func holdLatestMessage() {
        guard holdsLatestMessage, !messageList.isTracking, !messageList.isDecelerating,
              distanceFromLatestMessage > 0.5 else { return }
        if UIView.inheritedAnimationDuration > 0 {
            // inside the sidebar's animation, which ListView leaves to the
            // host when the offset is set directly
            messageList.contentOffset = messageList.maximumContentOffset
        } else {
            messageList.scrollToBottom(animated: false)
        }
    }

    private var distanceFromLatestMessage: CGFloat {
        max(0, messageList.maximumContentOffset.y - messageList.contentOffset.y)
    }

    private func updateLatestMessageButton() {
        let alpha: CGFloat = followedTurn == nil && distanceFromLatestMessage > 2 ? 1 : 0
        guard latestMessageButton.alpha != alpha else { return }
        if alpha > 0 {
            latestMessageButton.isHidden = false
        }
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
        ) {
            self.latestMessageButton.alpha = alpha
        } completion: { _ in
            self.latestMessageButton.isHidden = self.latestMessageButton.alpha == 0
        }
    }
}
