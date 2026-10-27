import UIKit

final class DKSettingsViewController: UITableViewController {

    private let aboutLinks: [(title: String, detail: String, url: String)] = [
        (DKL("作者"), "Junhong", "https://mjh.im/"),
        (DKL("反馈"), "pingme.pm/doleo", "https://pingme.pm/doleo"),
        (DKL("插件源"), "apt.mjh.im", "https://apt.mjh.im/"),
        (DKL("赏杯咖啡"), DKL("支付宝"), "alipays://platformapi/startapp?saId=10000007&qrcode=https%3A%2F%2Fqr.alipay.com%2Ffkx180736inoxop5mkbqh83%3F_s%3Dweb-other&launchKey=c7f8d186-3e05-4668-a7eb-8cf336c2108f-1780370320745"),
        (DKL("赏杯咖啡"), "Ko-fi", "https://ko-fi.com/manjunhong")
    ]
    private var settings = DKSettings.current
    private var usedSpace: String = DKL("计算中…")

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = DKL("设置")
        DispatchQueue.global(qos: .utility).async {
            let size = dkFormatSize(ArchiveStore.totalSize)
            DispatchQueue.main.async {
                self.usedSpace = size
                self.tableView.reloadData()
            }
        }
    }

    private func save() {
        DKSettings.current = settings
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [DKL("仓库"), DKL("存储"), DKL("关于")][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        return DKL("Sileo 下载后立刻留存原始 DEB，装完收进仓库；没留存到的按版本号从软件源重新下载。保留版本数为 0 表示不限。")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        [4, 3, aboutLinks.count][section]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            cell.textLabel?.text = DKL("自动保存旧版本")
            cell.accessoryView = makeSwitch(settings.autoBackup, #selector(toggleAutoBackup(_:)))
        case (0, 1):
            cell.textLabel?.text = DKL("自动保存安装的 DEB")
            cell.accessoryView = makeSwitch(settings.installBackup, #selector(toggleInstallBackup(_:)))
        case (0, 2):
            cell.textLabel?.text = DKL("下载时默认包含依赖")
            cell.accessoryView = makeSwitch(settings.includeDependencies, #selector(toggleDeps(_:)))
        case (0, 3):
            cell.textLabel?.text = DKL("每个包保留版本数")
            cell.detailTextLabel?.text = settings.keepVersions == 0 ? DKL("不限") : "\(settings.keepVersions)"
            let stepper = UIStepper()
            stepper.minimumValue = 0
            stepper.maximumValue = 20
            stepper.value = Double(settings.keepVersions)
            stepper.addTarget(self, action: #selector(changeKeep(_:)), for: .valueChanged)
            cell.accessoryView = stepper
        case (1, 0):
            cell.textLabel?.text = DKL("已用空间")
            cell.detailTextLabel?.text = usedSpace
        case (1, 1):
            cell.textLabel?.text = DKL("仓库位置")
            cell.detailTextLabel?.text = DKPaths.aptVisible(DKPaths.archiveDir)
            cell.detailTextLabel?.lineBreakMode = .byTruncatingHead
            cell.selectionStyle = .default
        case (1, 2):
            cell.textLabel?.text = DKL("自动备份日志")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        default:
            let link = aboutLinks[indexPath.row]
            cell.textLabel?.text = link.title
            cell.detailTextLabel?.text = link.detail
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (1, 1):
            DKUI.openRepository(from: self)
        case (1, 2):
            let log = (try? String(contentsOfFile: DKPaths.backupLog, encoding: .utf8)) ?? DKL("（暂无记录）")
            navigationController?.pushViewController(DKTextViewController(title: DKL("自动备份日志"), text: log), animated: true)
        case (2, _):
            guard let url = URL(string: aboutLinks[indexPath.row].url) else { return }
            UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                guard !opened, let self = self else { return }
                let alipay = url.scheme == "alipays"
                DKUI.alert(alipay ? DKL("无法打开支付宝") : DKL("无法打开链接"),
                           alipay ? DKL("请确认已安装支付宝。") : nil, on: self)
            }
        default:
            break
        }
    }

    private func makeSwitch(_ on: Bool, _ action: Selector) -> UISwitch {
        let s = UISwitch()
        s.isOn = on
        s.addTarget(self, action: action, for: .valueChanged)
        return s
    }

    @objc private func toggleAutoBackup(_ s: UISwitch) { settings.autoBackup = s.isOn; save() }
    @objc private func toggleInstallBackup(_ s: UISwitch) { settings.installBackup = s.isOn; save() }
    @objc private func toggleDeps(_ s: UISwitch) { settings.includeDependencies = s.isOn; save() }
    @objc private func changeKeep(_ s: UIStepper) {
        settings.keepVersions = Int(s.value)
        save()
        // 只改文字，不重建单元格，避免打断连续点按
        tableView.cellForRow(at: IndexPath(row: 3, section: 0))?.detailTextLabel?.text =
            settings.keepVersions == 0 ? DKL("不限") : "\(settings.keepVersions)"
    }
}
