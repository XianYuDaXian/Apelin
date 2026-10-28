import AlertController
import ApelinProtocol
import UIKit

/// Saves one provider's enabled models only when the user confirms.
final class ModelActivationController: TableController, UISearchResultsUpdating {
    private let account: AgentAccount
    private var selected: Set<String>
    private var shown: [String]
    private var models: [String]
    private var custom: Set<String>
    private var hidden: Set<String>
    private var reasoningEfforts: [String: [AgentReasoningEffort]]
    private var contextWindows: [String: Int]
    private var loader: Task<Void, Never>?
    private var saving = false
    private var verification: TaskHandle?
    private let search = UISearchController(searchResultsController: nil)

    init(account: AgentAccount) {
        self.account = account
        let available = account.models ?? []
        let enabled = EnabledModels.ids(for: account.provider)
        custom = Set(EnabledModels.customIDs(for: account.provider))
        hidden = account.isAPIKeyAccount ? EnabledModels.hiddenIDs(for: account.provider) : []
        reasoningEfforts = EnabledModels.reasoningEffortOverrides(for: account.provider)
        contextWindows = EnabledModels.contextWindowOverrides(for: account.provider)
        selected = account.isAPIKeyAccount ? enabled.subtracting(hidden) : enabled.intersection(available)
        models = account.isAPIKeyAccount
            ? Array(Set(available).union(custom).union(selected).subtracting(hidden)).sorted()
            : available
        shown = models
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(account:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Enable Models")
        navigationItem.largeTitleDisplayMode = .never
        let menu = usesAPIKey
            ? UIMenu(children: [UIAction(title: String(localized: "Save Without Verification")) { [weak self] _ in
                self?.save(verify: false)
            }])
            : nil
        let save = UIBarButtonItem(
            title: String(localized: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() },
            menu: menu,
        )
        if usesAPIKey {
            let add = UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                primaryAction: UIAction { [weak self] _ in self?.addCustomModel() },
            )
            add.accessibilityLabel = String(localized: "Add Custom Model")
            navigationItem.rightBarButtonItems = [save, add]
        } else {
            navigationItem.rightBarButtonItem = save
        }
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Models")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.register(ModelActivationCell.self, forCellReuseIdentifier: "model")
        updateRows()
    }

    private struct ModelRow: Equatable {
        let id: String
        let selected: Bool
        let efforts: [AgentReasoningEffort]
        let contextWindow: Int?
    }

    private func efforts(for model: String) -> [AgentReasoningEffort] {
        reasoningEfforts[model] ?? account.reasoningEfforts?[model] ?? []
    }

    private lazy var dataSource = TableDataSource<Int, String, ModelRow>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, indexPath, row in
        self?.cell(in: table, at: indexPath, row: row)
    }

    private func updateRows() {
        dataSource.headerTitle = { [weak self] _ in self.map { $0.account.account ?? $0.account.provider.displayName } }
        dataSource.footerTitle = { _ in String(localized: "Choose the models to show in the chat model picker. You can change this later in Model Providers.") }
        dataSource.allowsEditing = usesAPIKey
        dataSource.update([(0, shown.map {
            ModelRow(
                id: $0,
                selected: selected.contains($0),
                efforts: efforts(for: $0),
                contextWindow: contextWindows[$0],
            )
        })], reconfigure: true)
    }

    private var usesAPIKey: Bool {
        account.isAPIKeyAccount
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard usesAPIKey, loader == nil else { return }
        dataSource.beginLoad()
        loader = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await ProviderProgress.run(title: "Fetching Models", from: self) {
                    try await ApelinService.app.agentModelList(provider: self.account.provider).models
                }
                models = Array(Set(fetched).union(custom).union(selected).subtracting(hidden)).sorted()
                updateSearchResults(for: search)
            } catch {
                presentNotice(title: "Unable to Fetch Models", message: error.readableMessage)
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        shown = models.filter { query.isEmpty || $0.localizedStandardContains(query) }
        updateRows()
    }

    private func cell(in tableView: UITableView, at indexPath: IndexPath, row: ModelRow) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "model", for: indexPath) as! ModelActivationCell
        let model = row.id
        let summary = Self.summary(for: row)
        var content = cell.defaultContentConfiguration()
        content.text = model
        content.textProperties.numberOfLines = 0
        let configuration = usesAPIKey ? settingsButton(for: model, summary: summary) : nil
        if usesAPIKey {
            content.secondaryText = summary
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: row.selected ? "checkmark.circle.fill" : "circle")
        }
        cell.contentConfiguration = content
        cell.accessoryView = configuration
        cell.accessoryType = !usesAPIKey && row.selected ? .checkmark : .none
        cell.configureAccessibility(
            model: model,
            summary: usesAPIKey ? summary : nil,
            selected: row.selected,
            configuration: configuration,
        ) { [weak self] in self?.toggleModel(model) }
        return cell
    }

    private static func summary(for row: ModelRow) -> String {
        let context = row.contextWindow.map(title(forContextWindow:)) ?? String(localized: "Default")
        let efforts = row.efforts.isEmpty ? String(localized: "None") : row.efforts.map(title(for:)).joined(separator: " · ")
        return "\(context) · \(efforts)"
    }

    private func settingsButton(for model: String, summary: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.accessibilityLabel = String(localized: "Model Settings")
        button.accessibilityValue = summary
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(title: String(localized: "Model Settings"), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                completion([contextMenu(for: model), effortMenu(for: model)])
            },
        ])
        return button
    }

    private func contextMenu(for model: String) -> UIMenu {
        let chosen = contextWindows[model]
        let attributes: UIMenuElement.Attributes = saving ? .disabled : []
        let presets = Self.contextPresets.map { tokens in
            UIAction(
                title: Self.title(forContextWindow: tokens),
                attributes: attributes,
                state: chosen == tokens ? .on : .off,
            ) { [weak self] _ in
                self?.setContextWindow(tokens, for: model)
            }
        }
        let standard = UIAction(
            title: String(localized: "Default"),
            attributes: attributes,
            state: chosen == nil ? .on : .off,
        ) { [weak self] _ in
            self?.setContextWindow(nil, for: model)
        }
        let custom = UIAction(
            title: String(localized: "Custom…"),
            attributes: attributes,
            state: (chosen.map { !Self.contextPresets.contains($0) } ?? false) ? .on : .off,
        ) { [weak self] _ in
            self?.editContextWindow(for: model)
        }
        return UIMenu(
            title: String(localized: "Context Length"),
            children: [standard] + presets + [custom],
        )
    }

    private func effortMenu(for model: String) -> UIMenu {
        UIMenu(title: String(localized: "Reasoning Effort"), children: AgentReasoningEffort.allCases.map { effort in
            UIAction(
                title: Self.title(for: effort),
                attributes: saving ? .disabled : [],
                state: efforts(for: model).contains(effort) ? .on : .off,
            ) { [weak self] _ in
                guard let self, !saving else { return }
                var supported = Set(efforts(for: model))
                if !supported.insert(effort).inserted {
                    supported.remove(effort)
                }
                reasoningEfforts[model] = AgentReasoningEffort.allCases.filter { supported.contains($0) }
                updateRows()
            }
        })
    }

    private func setContextWindow(_ tokens: Int?, for model: String) {
        guard !saving else { return }
        if let tokens {
            contextWindows[model] = tokens
        } else {
            contextWindows.removeValue(forKey: model)
        }
        updateRows()
    }

    private func editContextWindow(for model: String) {
        guard !saving else { return }
        let alert = AlertInputViewController(
            title: "Context Length",
            message: "Enter a token count from 1 to 10,000,000.",
            placeholder: "Tokens",
            text: contextWindows[model].map(String.init) ?? "",
            doneButtonText: "Save",
        ) { [weak self] value in
            guard let self else { return }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.allSatisfy(\.isNumber),
                  let tokens = Int(text),
                  Self.contextWindowRange.contains(tokens)
            else {
                presentNotice(
                    title: "Invalid Context Length",
                    message: "Enter a token count from 1 to 10,000,000.",
                )
                return
            }
            contextWindows[model] = tokens
            updateRows()
        }
        present(alert, animated: true)
    }

    private static let contextPresets = [
        32_000, 64_000, 128_000, 200_000, 256_000, 400_000, 1_000_000,
    ]

    private static let contextWindowRange = 1...10_000_000

    private static func title(forContextWindow tokens: Int) -> String {
        if tokens.isMultiple(of: 1_000_000) {
            return "\(tokens / 1_000_000)M"
        }
        if tokens.isMultiple(of: 1_000) {
            return "\(tokens / 1_000)K"
        }
        return tokens.formatted()
    }

    private static func title(for effort: AgentReasoningEffort) -> String {
        switch effort {
        case .off: String(localized: "Off")
        case .minimal: String(localized: "Minimal")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra High")
        case .max: String(localized: "Maximum")
        }
    }

    private func toggleModel(_ model: String) {
        guard !saving else { return }
        if !selected.insert(model).inserted {
            selected.remove(model)
        }
        updateRows()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let model = dataSource.itemIdentifier(for: indexPath) else { return }
        toggleModel(model)
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard usesAPIKey, !saving, let model = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            guard let self, !saving, let row = shown.firstIndex(of: model) else { completion(false); return }
            selected.remove(model)
            custom.remove(model)
            hidden.insert(model)
            models.removeAll { $0 == model }
            shown.remove(at: row)
            completion(true)
            updateRows()
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func addCustomModel() {
        let alert = AlertInputViewController(
            title: "Add Custom Model",
            message: "Enter the model ID accepted by this provider.",
            placeholder: "Model ID",
            text: "",
            doneButtonText: "Add",
        ) { [weak self] value in
            guard let self else { return }
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 256, !id.contains(where: \.isWhitespace) else {
                presentNotice(
                    title: "Invalid Model ID",
                    message: String(localized: "Enter a model ID without spaces or line breaks."),
                )
                return
            }
            custom.insert(id)
            hidden.remove(id)
            models = Array(Set(models + [id])).sorted()
            selected.insert(id)
            updateSearchResults(for: search)
        }
        present(alert, animated: true)
    }

    private func save(verify: Bool = true) {
        guard !saving else { return }
        guard usesAPIKey && verify || account.provider == .githubCopilot,
              !selected.isEmpty
        else { finishSaving(); return }
        saving = true
        navigationController?.isModalInPresentation = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        Task { [weak self] in
            guard let self else { return }
            defer {
                saving = false
                verification = nil
                navigationController?.isModalInPresentation = false
                navigationItem.leftBarButtonItem?.isEnabled = true
                navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
            }
            do {
                try await ProviderProgress.run(
                    title: usesAPIKey ? "Verifying Models" : "Enabling Models",
                    message: "Waiting for a response from each selected model…",
                    from: self,
                    cancel: { [weak self] in
                        if let handle = self?.verification {
                            try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID)
                        }
                    },
                ) {
                    let handle = try await ApelinService.app.agentModelActivate(
                        provider: self.account.provider,
                        models: self.selected.sorted(),
                    )
                    self.verification = handle
                    if Task.isCancelled {
                        try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID)
                        throw CancellationError()
                    }
                    for try await event in ApelinService.app.events(of: handle) {
                        guard event.kind == TaskEvent.stateKind,
                              let state = event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)),
                              state.isTerminal
                        else { continue }
                        if state == .cancelled {
                            throw CancellationError()
                        }
                        guard state == .succeeded else {
                            throw ApelinError(
                                .unavailable,
                                event.payload?["message"]?.stringValue
                                    ?? String(localized: "Model verification failed."),
                            )
                        }
                        return
                    }
                    throw ApelinError(.unavailable, String(localized: "Model verification did not finish."))
                }
                finishSaving()
            } catch {
                if !(error is CancellationError) {
                    presentNotice(title: "Unable to Verify Models", message: error.readableMessage)
                }
            }
        }
    }

    private func finishSaving() {
        EnabledModels.save(
            selected,
            custom: custom,
            hidden: hidden,
            reasoningEfforts: reasoningEfforts,
            contextWindows: contextWindows,
            for: account.provider,
        )
        dismiss(animated: true)
    }
}

private final class ModelActivationCell: UITableViewCell {
    private final class ModelElement: UIAccessibilityElement {
        var activate: (() -> Void)?

        override func accessibilityActivate() -> Bool {
            guard let activate else { return false }
            activate()
            return true
        }
    }

    private lazy var modelElement = ModelElement(accessibilityContainer: self)

    func configureAccessibility(
        model: String,
        summary: String?,
        selected: Bool,
        configuration: UIButton?,
        activate: @escaping () -> Void,
    ) {
        isAccessibilityElement = false
        modelElement.accessibilityLabel = model
        modelElement.accessibilityValue = summary
        modelElement.accessibilityTraits = selected ? [.button, .selected] : [.button]
        modelElement.activate = activate
        if let configuration {
            accessibilityElements = [modelElement, configuration]
        } else {
            accessibilityElements = [modelElement]
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        modelElement.accessibilityFrameInContainerSpace = contentView.frame
    }
}
