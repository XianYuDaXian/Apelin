import ApelinProtocol
import UIKit

/// 设置页只读写同一个 UserDefaults 键；提示词包在下次构造系统提示词时读取它。
private enum CodexOverlayToggle {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "agent.codexOverlayEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agent.codexOverlayEnabled") }
    }
}

/// The approval mode, and below it Ask Before Using the Screen, which holds
/// in every mode.
final class PermissionModeController: TableController {
    private let modes: [ApprovalMode] = [.confirm, .relaxed, .full]

    private enum Section: Hashable {
        case modes
        case screen
        case prompt
    }

    private enum RowID: Hashable {
        case mode(ApprovalMode)
        case asksBeforeScreen
        case codexOverlay
    }

    private struct Row: Equatable {
        let id: RowID
        let selected: Bool
    }

    private lazy var dataSource = TableDataSource<Section, RowID, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    @objc private dynamic func updateRows() {
        dataSource.footerTitle = { section in
            switch section {
            case .modes: AgentPermissions.explanation
            case .screen: String(localized: "While this is on, the agent asks you before it opens an app or a link, reads what is on the screen or acts on it, through Apelin’s screen tools or icli, in every permission mode. Before a screenshot it always asks in the conversation. Each chat follows a change when you send its next message.")
            case .prompt: "Codex 交付叠加层只改变回复的交付形态和占位符规则；关闭后恢复 Apelin 原有提示词。下一次发送消息时生效。"
            }
        }
        dataSource.update([
            (.modes, modes.map { Row(id: .mode($0), selected: $0 == AgentPermissions.mode) }),
            (.screen, [Row(id: .asksBeforeScreen, selected: AgentPermissions.asksBeforeScreen)]),
            (.prompt, [Row(id: .codexOverlay, selected: CodexOverlayToggle.enabled)]),
        ], reconfigure: true)
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
        title = String(localized: "Permission Mode")
        updateRows()
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row.id {
        case let .mode(mode):
            let cell = tableView.dequeueReusableCell(withIdentifier: "mode")
                ?? UITableViewCell(style: .default, reuseIdentifier: "mode")
            var content = cell.defaultContentConfiguration()
            content.text = AgentPermissions.title(for: mode)
            cell.contentConfiguration = content
            let selected = row.selected
            cell.accessoryType = selected ? .checkmark : .none
            cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
            return cell
        case .asksBeforeScreen:
            // The switch says on or off itself; the row's text names it.
            let cell = tableView.dequeueReusableCell(withIdentifier: "screen")
                ?? UITableViewCell(style: .default, reuseIdentifier: "screen")
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Ask Before Using the Screen")
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
            toggle.isOn = row.selected
            toggle.removeTarget(nil, action: nil, for: .valueChanged)
            toggle.addTarget(self, action: #selector(asksBeforeScreenChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        case .codexOverlay:
            let cell = tableView.dequeueReusableCell(withIdentifier: "codexOverlay")
                ?? UITableViewCell(style: .default, reuseIdentifier: "codexOverlay")
            var content = cell.defaultContentConfiguration()
            content.text = "Codex 交付叠加层"
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
            toggle.isOn = row.selected
            toggle.removeTarget(nil, action: nil, for: .valueChanged)
            toggle.addTarget(self, action: #selector(codexOverlayChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .mode = dataSource.value(at: indexPath)?.id {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .mode(mode) = dataSource.value(at: indexPath)?.id else { return }
        let current = AgentPermissions.mode
        guard mode != current else { return }
        switch mode {
        // Root without asking: confirmed in words, then by the device owner.
        // Leaving Full never asks.
        case .full:
            presentConfirmation(
                title: "Enable Full Mode?",
                message: "The agent can run commands as root without asking, with full control of this device. Each chat switches when you send its next message.",
                confirmTitle: "Enable Full Mode",
                destructive: true,
            ) { [weak self] in
                Task { @MainActor in
                    guard await DeviceOwnerCheck.confirm(
                        reason: String(localized: "Let the agent run commands as root without asking."),
                    ) else { return }
                    self?.save(mode)
                }
            }
        case .relaxed where current == .confirm:
            presentConfirmation(
                title: "Enable Relaxed Mode?",
                message: "The agent can run commands and make changes without asking, within the app’s permissions. Each chat switches when you send its next message.",
                confirmTitle: "Enable Relaxed Mode",
            ) { [weak self] in self?.save(mode) }
        default:
            save(mode)
        }
    }

    private func save(_ mode: ApprovalMode) {
        AgentPermissions.mode = mode
        updateRows()
    }

    @objc private dynamic func asksBeforeScreenChanged(_ toggle: UISwitch) {
        AgentPermissions.asksBeforeScreen = toggle.isOn
        updateRows()
    }

    @objc private dynamic func codexOverlayChanged(_ toggle: UISwitch) {
        CodexOverlayToggle.enabled = toggle.isOn
        updateRows()
    }
}
