import UIKit

/// 从软件源选择版本"仅下载"
final class DKVersionPickerViewController: UITableViewController {

    private let package: String
    private let displayName: String
    private let focusVersion: String?
    private let sourceURL: String?
    private var entries = [RepoEntry]()
    private var installed: DpkgStatus.Installed?
    private var archivedVersions = Set<String>()
    private var loading = true

    init(package: String, displayName: String, focusVersion: String?, sourceURL: String? = nil) {
        self.package = package
        self.displayName = displayName
        self.focusVersion = focusVersion
        self.sourceURL = sourceURL
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = displayName
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Doleo", style: .plain,
                                                            target: self, action: #selector(openLibrary))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "info")
        NotificationCenter.default.addObserver(self, selector: #selector(purchasesChanged), name: DKPayments.didChange, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !loading { refreshArchived(); tableView.reloadData() }
    }

    private func reload() {
        loading = true
        tableView.reloadData()
        let pkg = package
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = RepoIndex.shared.entries(for: pkg)
            let installed = DpkgStatus.installed(pkg)
            DispatchQueue.main.async {
                self.entries = entries
                self.installed = installed
                self.refreshArchived()
                self.loading = false
                self.tableView.reloadData()
            }
        }
    }

    private func refreshArchived() {
        archivedVersions = Set(ArchiveStore.items(for: package).map { $0.meta.version + "|" + $0.meta.architecture })
    }

    @objc private func purchasesChanged() { tableView.reloadData() }

    @objc private func close() { dismiss(animated: true) }

    @objc private func openLibrary() {
        navigationController?.pushViewController(DKPackageArchiveViewController(package: package, name: displayName, sourceURL: sourceURL), animated: true)
    }

    // MARK: - 表格

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? DKL("状态") : DKL("源中的可用版本")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        if loading { return nil }
        if entries.isEmpty { return DKL("软件源中找不到 %@，请刷新软件源。", package) }
        return nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 2 }
        return loading ? 1 : entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.selectionStyle = .none
            if indexPath.row == 0 {
                cell.textLabel?.text = DKL("已安装版本")
                cell.detailTextLabel?.text = installed.map { $0.version } ?? DKL("未安装")
            } else {
                cell.textLabel?.text = DKL("已入库版本")
                cell.detailTextLabel?.text = DKL("%d 个", archivedVersions.count)
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }
            return cell
        }

        if loading {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = DKL("正在读取软件源索引…")
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell
        }

        let entry = entries[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let otherSource = entry.isOtherSource(than: sourceURL)
        var title = entry.version
        if otherSource { title += "  " + DKUI.badge(DKL("其他源")) }
        if entry.version == installed?.version { title += "  " + DKUI.badge(DKL("已安装")) }
        if archivedVersions.contains(entry.version + "|" + entry.architecture) { title += "  " + DKUI.badge(DKL("已入库")) }
        if entry.isCommercial { title += "  " + DKUI.badge(DKPayments.shared.isPurchased(entry) == true ? DKL("已购") : DKL("付费")) }
        cell.textLabel?.text = title
        cell.textLabel?.font = entry.version == focusVersion ? .boldSystemFont(ofSize: 17) : .systemFont(ofSize: 17)
        var detail = [entry.baseURL, entry.architecture.replacingOccurrences(of: "iphoneos-", with: "")]
        if let size = entry.size { detail.append(dkFormatSize(size)) }
        if entry.sha256 == nil { detail.append(DKL("无 SHA256，无法校验")) }
        cell.detailTextLabel?.text = detail.joined(separator: " · ")
        cell.textLabel?.textColor = otherSource ? .systemOrange : .label
        cell.detailTextLabel?.textColor = otherSource ? .systemOrange : .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            if indexPath.row == 1 { openLibrary() }
            return
        }
        guard !loading, indexPath.row < entries.count else { return }
        let entry = entries[indexPath.row]
        let sheet = UIAlertController(title: "\(entry.name) \(entry.version)", message: entry.baseURL, preferredStyle: .actionSheet)
        let only = UIAlertAction(title: DKL("仅下载此版本"), style: .default) { [weak self] _ in
            self?.startDownload([entry], unresolved: [])
        }
        let withDeps = UIAlertAction(title: DKL("下载此版本及依赖"), style: .default) { [weak self] _ in
            self?.downloadWithDependencies(entry)
        }
        if DKSettings.current.includeDependencies {
            sheet.addAction(withDeps); sheet.addAction(only)
        } else {
            sheet.addAction(only); sheet.addAction(withDeps)
        }
        sheet.addAction(UIAlertAction(title: DKL("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(sheet, animated: true)
    }

    private func downloadWithDependencies(_ entry: RepoEntry) {
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = DKDownloader.resolveDependencies(of: entry)
            DispatchQueue.main.async {
                let names = resolved.entries.dropFirst().map { "\($0.name) \($0.version)" }
                let message = names.isEmpty ? DKL("没有需要额外下载的依赖。") : DKL("将一并下载：\n") + names.joined(separator: "\n")
                DKUI.confirm(DKL("下载依赖"), message, action: DKL("开始下载"), on: self) {
                    self.startDownload(resolved.entries, unresolved: resolved.unresolved)
                }
            }
        }
    }

    private func startDownload(_ entries: [RepoEntry], unresolved: [String]) {
        DKDownloadFlow(host: self).run(entries, unresolved: unresolved) { [weak self] in
            self?.refreshArchived()
            self?.tableView.reloadData()
        }
    }
}
