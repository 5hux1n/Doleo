import UIKit

/// 单个包的全部仓库版本
final class DKPackageArchiveViewController: UITableViewController {

    private let package: String
    private let name: String
    private let sourceURL: String?
    private var items = [ArchiveItem]()
    private var installed: DpkgStatus.Installed?
    private var delisted = Set<String>()

    init(package: String, name: String, sourceURL: String? = nil) {
        self.package = package
        self.name = name
        self.sourceURL = sourceURL
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = name
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        let pkg = package
        DispatchQueue.global(qos: .userInitiated).async {
            let items = ArchiveStore.items(for: pkg)
            let installed = DpkgStatus.installed(pkg)
            let delisted = Set(items.filter { !RepoIndex.shared.isAvailable(package: pkg, version: $0.meta.version) }.map { $0.meta.version })
            DispatchQueue.main.async {
                self.items = items
                self.installed = installed
                self.delisted = delisted
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - 表格

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? package : DKL("仓库版本")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = DKL("已安装版本")
                cell.detailTextLabel?.text = installed.map { $0.version } ?? DKL("未安装")
                cell.selectionStyle = .none
            default:
                cell.textLabel?.text = DKL("从软件源下载其他版本")
                cell.textLabel?.textColor = view.tintColor
            }
            return cell
        }

        let item = items[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var title = item.meta.version
        if item.meta.version == installed?.version { title += "  " + DKUI.badge(DKL("已安装")) }
        if delisted.contains(item.meta.version) { title += "  " + DKUI.badge(DKL("已下架")) }
        cell.textLabel?.text = title
        let date = DateFormatter.localizedString(from: Date(timeIntervalSince1970: item.meta.savedAt), dateStyle: .short, timeStyle: .short)
        var detail = [item.originText, dkFormatSize(item.size), date]
        if item.meta.verified == true { detail.append(DKL("已校验")) }
        cell.detailTextLabel?.text = detail.joined(separator: " · ")
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            if indexPath.row == 1 {
                navigationController?.pushViewController(
                    DKVersionPickerViewController(package: package, displayName: name, focusVersion: nil, sourceURL: sourceURL), animated: true)
            }
            return
        }
        showActions(for: items[indexPath.row], cell: tableView.cellForRow(at: indexPath))
    }

    private func showActions(for item: ArchiveItem, cell: UIView?) {
        let sheet = UIAlertController(title: "\(name) \(item.meta.version)", message: item.fileName, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: DKL("安装此版本"), style: .default) { [weak self] _ in
            self?.install(item)
        })
        sheet.addAction(UIAlertAction(title: DKL("导出"), style: .default) { [weak self] _ in
            guard let self = self else { return }
            DKUI.share(URL(fileURLWithPath: item.debPath), from: self, sourceView: cell)
        })
        sheet.addAction(UIAlertAction(title: DKL("查看控制信息"), style: .default) { [weak self] _ in
            let text = item.control?.raw ?? DKL("（没有保存控制信息）")
            let meta = (try? JSONEncoder.dk.encode(item.meta)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self?.navigationController?.pushViewController(
                DKTextViewController(title: item.meta.version, text: text + DKL("\n\n— 元数据 —\n") + meta), animated: true)
        })
        sheet.addAction(UIAlertAction(title: DKL("删除"), style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            DKUI.confirm(DKL("删除此仓库文件？"), item.fileName, action: DKL("删除"), destructive: true, on: self) {
                ArchiveStore.delete(item)
                DispatchQueue.global(qos: .utility).async { try? ArchiveStore.rebuildLocalIndex() }
                self.reload()
            }
        })
        sheet.addAction(UIAlertAction(title: DKL("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell ?? view
        present(sheet, animated: true)
    }

    /// 复制一份临时文件交给 Sileo，由 Sileo 走自己的安装流程（会正常处理依赖和队列）
    private func install(_ item: ArchiveItem) {
        do {
            let url = try ArchiveStore.prepareForInstall(item)
            DKUI.dismissAll { DKUI.openInSileo(url) }
        } catch {
            DKUI.alert(DKL("无法准备安装文件"), error.localizedDescription, on: self)
        }
    }
}

/// 简单的只读文本页
final class DKTextViewController: UIViewController {
    private let text: String

    init(title: String, text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let tv = UITextView(frame: view.bounds)
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.text = text
        tv.backgroundColor = .systemBackground
        view.addSubview(tv)
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain,
                                                            target: self, action: #selector(copyText))
    }

    @objc private func copyText() {
        UIPasteboard.general.string = text
    }
}
