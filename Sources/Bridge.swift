import UIKit
import ObjectiveC

/// Logos 钩子（Tweak.x）通过 ObjC 运行时调用这里的方法，不需要桥接头文件。
@objc(DKBridge)
final class DKBridge: NSObject {

    private static var buttonKey: UInt8 = 0

    /// 复用 Sileo 安装按钮所在的横向布局，入口随详情页一起滚动。
    @objc(installPackageButton:)
    static func installPackageButton(_ controller: UIViewController) {
        guard let ivar = class_getInstanceVariable(type(of: controller), "downloadButton"),
              let install = object_getIvar(controller, ivar) as? UIButton,
              let stack = install.superview as? UIStackView,
              let index = stack.arrangedSubviews.firstIndex(of: install) else { return }
        if let button = objc_getAssociatedObject(install, &buttonKey) as? UIButton {
            button.tintColor = DKUI.entryTint
            return
        }

        let button = UIButton(type: .system)
        button.setImage(DKUI.entryIcon, for: .normal)
        button.tintColor = DKUI.entryTint
        button.accessibilityLabel = DKL("Doleo 仓库")
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIAction(title: DKL("仅下载"), image: DKUI.entryIcon) { [weak controller] _ in
                guard let controller = controller else { return }
                guard let info = SileoReflection.packageInfo(from: controller) else {
                    DKUI.alert(DKL("无法读取软件包"), DKL("当前 Sileo 版本的包信息暂不兼容。"), on: controller)
                    return
                }
                DKUI.presentWrapped(DKVersionPickerViewController(package: info.id, displayName: info.name,
                                                                 focusVersion: info.version, sourceURL: info.sourceURL), from: controller)
            },
            UIAction(title: DKL("仓库"), image: UIImage(systemName: "archivebox")) { [weak controller] _ in
                guard let controller = controller else { return }
                DKUI.presentWrapped(DKLibraryViewController(), from: controller)
            }
        ])
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        stack.insertArrangedSubview(button, at: index)
        objc_setAssociatedObject(install, &buttonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc(installLibraryButton:)
    static func installLibraryButton(_ controller: UIViewController) {
        var items = controller.navigationItem.rightBarButtonItems ?? []
        let identifier = "im.mjh.doleo.library"
        guard !items.contains(where: { $0.accessibilityIdentifier == identifier }),
              let wishlist = items.firstIndex(where: { $0.action == NSSelectorFromString("showWishlist:") }) else { return }
        let button = UIBarButtonItem(title: "Doleo", image: nil, primaryAction: UIAction { [weak controller] _ in
            guard let controller = controller else { return }
            DKUI.presentWrapped(DKLibraryViewController(), from: controller)
        }, menu: nil)
        button.accessibilityIdentifier = identifier
        button.tintColor = DKUI.entryTint
        // UIKit 的右侧按钮数组按从右到左排列。
        items.insert(button, at: wishlist + 1)
        controller.navigationItem.rightBarButtonItems = items
    }

    @objc(shouldObservePaymentRequest:)
    static func shouldObservePaymentRequest(_ request: URLRequest) -> Bool {
        DKPayments.shouldObserve(request)
    }

    @objc(observePaymentRequest:data:response:error:)
    static func observePaymentRequest(_ request: URLRequest, data: Data?, response: URLResponse?, error: NSError?) {
        DKPayments.shared.observe(request, data: data, response: response, error: error)
    }

    @objc(didLaunch)
    static func didLaunch() {
        DKPaths.ensureDirectories()
        DKSettings.migrateLegacyOnce()
        DispatchQueue.global(qos: .utility).async {
            ArchiveStore.cleanTmp()
            try? ArchiveStore.rebuildLocalIndex()
        }
        // Sileo 下载的 DEB 一落进 APT 缓存就留存一份（装完 Sileo 会 apt-get clean）
        DKCapture.start()
        // Sileo 跑完一个安装队列会发这个通知（PackageListManager.installChange），装完立刻补存
        NotificationCenter.default.addObserver(forName: Notification.Name("SileoInstallChanged"),
                                               object: nil, queue: nil) { _ in
            DKBackup.start(force: true)
        }
        DKBackup.start()
    }

    /// 回到前台时补一次：覆盖用 Zebra、apt 命令行或 Filza 装的包
    @objc(didBecomeActive)
    static func didBecomeActive() {
        DKBackup.start()
    }
}

/// 从 Sileo 的包详情页读取包信息。
/// Sileo 的 Package 是纯 Swift 类（不继承 NSObject），ObjC 侧无法发消息，
/// Sileo 正式构建关闭了 Mirror 元数据，按运行时 ivar 偏移读取已知的 Swift 字符串字段。
enum SileoReflection {

    struct PackageInfo {
        let id: String
        let version: String?
        let name: String
        let sourceURL: String?
    }

    static func packageInfo(from controller: UIViewController) -> PackageInfo? {
        guard let object = packageObject(from: controller) else { return nil }
        func string(_ label: String, optional: Bool = false) -> String? {
            guard let cls = object_getClass(object),
                  let ivar = class_getInstanceVariable(cls, label) else { return nil }
            let address = Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar))
            // shortcut: 字段类型按 Sileo.Package 定义，宿主更改字段类型时需适配。
            return optional ? address.load(as: String?.self) : address.load(as: String.self)
        }
        // 本地 deb 打开的页面里 package 字段是文件路径，packageID 才是真正的包名
        var id = string("packageID") ?? string("package") ?? ""
        if id.contains("/") { id = string("packageID") ?? "" }
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return PackageInfo(id: id, version: string("version"), name: string("name", optional: true) ?? id,
                           sourceURL: string("sourceFile", optional: true).flatMap { SourcesParser.urls(in: $0).first })
    }

    private static func packageObject(from controller: UIViewController) -> AnyObject? {
        var cls: AnyClass? = type(of: controller)
        while let c = cls {
            if let ivar = class_getInstanceVariable(c, "package") {
                return object_getIvar(controller, ivar) as AnyObject?
            }
            cls = class_getSuperclass(c)
        }
        return nil
    }
}

// MARK: - UI 工具

enum DKUI {

    static let entryTint = UIColor(red: 47.0 / 255, green: 128.0 / 255, blue: 237.0 / 255, alpha: 1)

    static var entryIcon: UIImage? {
        UIImage(contentsOfFile: DKPaths.rooted("/usr/share/doleo/entry.png"))?.withRenderingMode(.alwaysTemplate)
    }


    static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.windows.first { $0.isKeyWindow } ?? UIApplication.shared.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// Doleo 弹出的第一层导航控制器，用于一次性关闭全部弹窗
    private static weak var rootNav: UINavigationController?

    static func presentWrapped(_ vc: UIViewController, from presenter: UIViewController) {
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        if rootNav?.presentingViewController == nil { rootNav = nav }
        presenter.present(nav, animated: true)
    }

    static func openRepository(from controller: UIViewController) {
        let path = DKPaths.archiveDir
        guard let filza = DKPaths.fileManagerURL(scheme: "filza", path: path),
              let fila = DKPaths.fileManagerURL(scheme: "fila", path: path) else { return }
        UIApplication.shared.open(filza, options: [:]) { opened in
            guard !opened else { return }
            UIApplication.shared.open(fila, options: [:]) { opened in
                guard !opened else { return }
                UIPasteboard.general.string = path
                alert(DKL("已复制路径"), path, on: controller)
            }
        }
    }

    static func alert(_ title: String, _ message: String?, on vc: UIViewController) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: DKL("好"), style: .cancel))
        vc.present(a, animated: true)
    }

    static func confirm(_ title: String, _ message: String?, action: String, destructive: Bool = false,
                        on vc: UIViewController, handler: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: DKL("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in handler() })
        vc.present(a, animated: true)
    }

    /// 让 Sileo 打开一个 URL（file:// 的 deb 会进入 Sileo 自己的安装页面；sileo://package/ID 打开包详情）
    static func openInSileo(_ url: URL) {
        let app = UIApplication.shared
        _ = app.delegate?.application?(app, open: url, options: [:])
    }

    /// 关闭 Doleo 的所有弹窗后再执行
    static func dismissAll(then: @escaping () -> Void) {
        if let presenter = rootNav?.presentingViewController {
            presenter.dismiss(animated: true) {
                // 给 Sileo 一点时间恢复界面再执行后续操作
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: then)
            }
        } else {
            then()
        }
    }

    static func share(_ fileURL: URL, from vc: UIViewController, sourceView: UIView?) {
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView ?? vc.view
        vc.present(activity, animated: true)
    }

    static func badge(_ text: String) -> String { "［\(text)］" }
}

/// 下载进度弹窗 + 下载流程
final class DKDownloadFlow {

    private let downloader = DKDownloader()
    private weak var host: UIViewController?
    private var alert: UIAlertController?
    private static var running = [DKDownloadFlow]()   // 下载期间保持引用

    init(host: UIViewController) {
        self.host = host
    }

    func run(_ entries: [RepoEntry], unresolved: [String] = [], completion: (() -> Void)? = nil) {
        guard let host = host else { return }
        guard DKPaths.isDataDirWritable else {
            DKUI.alert(DKL("仓库目录不可写"), DKL("请重新安装 Doleo 以创建目录：\n%@", DKPaths.archiveDir), on: host)
            return
        }
        DKDownloadFlow.running.append(self)
        let a = UIAlertController(title: DKL("正在下载"), message: DKL("准备中…"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: DKL("取消"), style: .cancel) { [weak self] _ in self?.downloader.cancel() })
        alert = a
        host.present(a, animated: true)

        downloader.download(entries, progress: { [weak self] p in
            self?.alert?.message = "(\(p.index)/\(p.total)) \(p.name)\n\(Int(p.fraction * 100))%"
        }, completion: { [weak self] results in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async { try? ArchiveStore.rebuildLocalIndex() }
            self.alert?.dismiss(animated: true) {
                self.showSummary(results, unresolved: unresolved)
                completion?()
                DKDownloadFlow.running.removeAll { $0 === self }
            }
        })
    }

    private func showSummary(_ results: [DKDownloadResult], unresolved: [String]) {
        guard let host = host else { return }
        let ok = results.filter { $0.error == nil && !$0.skipped }
        let skipped = results.filter { $0.skipped }
        let failed = results.filter { $0.error != nil }
        var lines = [String]()
        if !ok.isEmpty { lines.append(DKL("已入库 %d 个：", ok.count) + ok.map { "\($0.entry.name) \($0.entry.version)" }.joined(separator: "、")) }
        if !skipped.isEmpty { lines.append(DKL("已存在，跳过 %d 个", skipped.count)) }
        for f in failed { lines.append(DKL("失败：%@ %@\n%@", f.entry.name, f.entry.version, f.error?.localizedDescription ?? "")) }
        if !unresolved.isEmpty { lines.append(DKL("以下依赖在源中找不到（可能是系统自带或虚拟包）：") + unresolved.joined(separator: "、")) }
        if downloader.isCancelled { lines.append(DKL("已取消")) }
        DKUI.alert(failed.isEmpty ? DKL("下载完成") : DKL("部分失败"), lines.joined(separator: "\n\n"), on: host)
    }
}
