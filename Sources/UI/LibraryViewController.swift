import UIKit

/// 仓库首页：按包分组
final class DKLibraryViewController: UITableViewController, UISearchResultsUpdating {

    private var all = [ArchivePackage]()
    private var shown = [ArchivePackage]()
    private var installedVersions = [String: String]()
    private let search = UISearchController(searchResultsController: nil)

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = DKL("Doleo 仓库")
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        }
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(openSettings)),
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain, target: self, action: #selector(showMore(_:)))
        ]
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = DKL("搜索包名")
        navigationItem.searchController = search
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(reload), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let packages = ArchiveStore.scan()
            var installed = [String: String]()
            for p in packages {
                if let v = DpkgStatus.installed(p.package)?.version { installed[p.package] = v }
            }
            DispatchQueue.main.async {
                self.all = packages
                self.installedVersions = installed
                self.applyFilter()
                self.refreshControl?.endRefreshing()
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) { applyFilter() }

    private func applyFilter() {
        let q = search.searchBar.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        shown = q.isEmpty ? all : all.filter { $0.package.lowercased().contains(q) || $0.name.lowercased().contains(q) }
        tableView.reloadData()
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func openSettings() {
        navigationController?.pushViewController(DKSettingsViewController(), animated: true)
    }

    @objc private func showMore(_ sender: UIBarButtonItem) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: DKL("重建本地源索引"), style: .default) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ArchiveStore.rebuildLocalIndex() }
                DispatchQueue.main.async {
                    switch result {
                    case .success: DKUI.alert(DKL("索引已更新"), DKL("本地源条目：\n%@", ArchiveStore.localSourceLine), on: self)
                    case .failure(let e): DKUI.alert(DKL("失败"), e.localizedDescription, on: self)
                    }
                }
            }
        })
        sheet.addAction(UIAlertAction(title: DKL("复制本地源条目"), style: .default) { [weak self] _ in
            UIPasteboard.general.string = ArchiveStore.localSourceLine
            if let self = self {
                DKUI.alert(DKL("已复制"), ArchiveStore.localSourceLine, on: self)
            }
        })
        sheet.addAction(UIAlertAction(title: DKL("打开仓库目录"), style: .default) { [weak self] _ in
            guard let self = self else { return }
            DKUI.openRepository(from: self)
        })
        sheet.addAction(UIAlertAction(title: DKL("取消"), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = sender
        present(sheet, animated: true)
    }

    // MARK: - 表格

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let total = all.reduce(0) { $0 + $1.totalSize }
        let count = all.reduce(0) { $0 + $1.items.count }
        return DKL("%d 个包 · %d 个版本 · %@", all.count, count, dkFormatSize(total))
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if all.isEmpty {
            return DKL("仓库还没有软件包。")
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let pkg = shown[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = pkg.name
        var detail = [DKL("%d 个版本", pkg.items.count), dkFormatSize(pkg.totalSize)]
        if let v = installedVersions[pkg.package] { detail.append(DKL("已安装 %@", v)) }
        cell.detailTextLabel?.text = [pkg.sourceSubtitle, detail.joined(separator: " · ")].compactMap { $0 }.joined(separator: "\n")
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let pkg = shown[indexPath.row]
        navigationController?.pushViewController(DKPackageArchiveViewController(package: pkg.package, name: pkg.name), animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let pkg = shown[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: DKL("全部删除")) { [weak self] _, _, done in
            guard let self = self else { done(false); return }
            DKUI.confirm(DKL("删除 %@ 的全部仓库文件？", pkg.name), DKL("共 %d 个版本，删除后无法恢复。", pkg.items.count), action: DKL("删除"),
                         destructive: true, on: self) {
                pkg.items.forEach(ArchiveStore.delete)
                DispatchQueue.global(qos: .utility).async { try? ArchiveStore.rebuildLocalIndex() }
                self.reload()
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
