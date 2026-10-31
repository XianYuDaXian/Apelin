import Dog
import UIKit

/// Settings ▸ Logs: Dog's journal, one file a launch (`JournalFiles`), the
/// running launch's first, then the earlier ones newest first. A row opens
/// that launch's log (`LogViewerController`, Irisin's log page); an earlier
/// one can be deleted. Irisin's page reads only the running launch; this
/// one lists every launch Dog keeps, since the launch that went wrong is
/// usually an earlier one.
final class LogsController: TableController {
    private enum Section: Hashable {
        case current
        case earlier
    }

    private struct Row: Equatable {
        let file: JournalFile
        let isCurrent: Bool
    }

    private lazy var dataSource = TableDataSource<Section, URL, Row>(
        tableView: tableView,
        identifier: { $0.file.url },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private var loader: Task<Void, Never>?

    /// Where Dog writes: its own answer once it is open, else the data
    /// folder's `Journal/` (`AppJournal`).
    private static var directory: URL {
        Dog.shared.currentLogFileDirLocation ?? AppJournal.directory
    }

    /// A launch as its row and its page name it: when it began, else the
    /// file's name.
    static func title(of file: JournalFile) -> String {
        file.started?.formatted(date: .numeric, time: .shortened) ?? file.name
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Logs")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case .current: String(localized: "This Launch")
            case .earlier: String(localized: "Earlier Launches")
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .current: nil
            case .earlier: String(localized: "Apelin keeps the logs of its last 100 launches.")
            }
        }
    }

    /// Read on every appearance: the running launch's file grows.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        loader?.cancel()
        dataSource.beginLoad()
        let directory = Self.directory
        let current = Dog.shared.currentLogFileLocation?.lastPathComponent
        loader = Task { [weak self] in
            let files = await Task.detached { JournalFiles.list(in: directory) }.value
            guard let self, !Task.isCancelled else { return }
            let rows = files.map { Row(file: $0, isCurrent: $0.name == current) }
            let earlier = rows.filter { !$0.isCurrent }
            var sections: [(Section, [Row])] = []
            if let running = rows.first(where: \.isCurrent) {
                sections.append((.current, [running]))
            }
            if !earlier.isEmpty {
                sections.append((.earlier, earlier))
            }
            dataSource.update(sections, reconfigure: true)
            tableView.backgroundView = rows.isEmpty ? EmptyStateView(
                symbolName: "doc.text",
                title: String(localized: "No Logs"),
                text: String(localized: "Logs appear here when Apelin starts."),
            ) : nil
        }
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "journal")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "journal")
        var content = UIListContentConfiguration.valueCell()
        content.text = Self.title(of: row.file)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        navigationController?.pushViewController(
            LogViewerController(file: row.file, isCurrent: row.isCurrent),
            animated: true,
        )
    }

    /// Dog is still writing the running launch's file, so only an earlier
    /// one is deleted.
    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        dataSource.value(at: indexPath)?.isCurrent == false ? .delete : .none
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let row = dataSource.value(at: indexPath), !row.isCurrent else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, complete in
            let url = row.file.url
            Task { [weak self] in
                do {
                    try await Task.detached { try FileManager.default.removeItem(at: url) }.value
                    complete(true)
                } catch {
                    complete(false)
                    self?.presentNotice(title: "Unable to Delete Log", message: error.readableMessage)
                }
                self?.load()
            }
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
