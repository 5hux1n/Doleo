import Foundation

/// Reuse Sileo's active store requests in memory; never persist account credentials.
final class DKPayments {
    static let shared = DKPayments()
    static let didChange = Notification.Name("im.mjh.doleo.purchasesChanged")
    private let lock = NSLock()
    private var endpoints = [String: URL]()
    private var templates = [String: URLRequest]()
    private var purchases = [String: Bool]()

    private func key(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func infoEndpoint(_ request: URLRequest) -> URL? {
        guard request.httpMethod == "POST", let url = request.url, url.scheme == "https" else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 4, parts[parts.count - 3] == "package", parts.last == "info" else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func shouldObserve(_ request: URLRequest) -> Bool {
        request.url?.scheme == "https" && (request.url?.lastPathComponent == "payment_endpoint" || infoEndpoint(request) != nil)
    }

    func observe(_ request: URLRequest, data: Data?, response: URLResponse?, error: Error?) {
        guard let url = request.url else { return }
        let status = (response as? HTTPURLResponse)?.statusCode
        let success = error == nil && status.map { (200..<300).contains($0) } == true
        if url.lastPathComponent == "payment_endpoint" {
            guard success, let data = data, let text = String(data: data, encoding: .utf8),
                  let endpoint = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), endpoint.scheme == "https" else { return }
            lock.lock()
            endpoints[key(url.deletingLastPathComponent())] = endpoint
            lock.unlock()
            return
        }
        guard let endpoint = Self.infoEndpoint(request) else { return }
        let store = key(endpoint)
        let package = url.deletingLastPathComponent().lastPathComponent
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        lock.lock()
        let previous = purchases[store + "|" + package]
        let invalidated = status == 401 || status == 403 || (json?["invalidate"] as? Bool) == true
        if success, !invalidated, let json = json, json["error"] == nil, (json["success"] as? Bool) != false,
           let purchased = json["purchased"] as? NSNumber {
            templates[store] = request
            purchases[store + "|" + package] = purchased.boolValue
        } else {
            purchases[store + "|" + package] = nil
            if invalidated {
                templates[store] = nil
                purchases = purchases.filter { !$0.key.hasPrefix(store + "|") }
            }
        }
        let changed = invalidated || previous != purchases[store + "|" + package]
        lock.unlock()
        if changed {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }

    func isPurchased(_ entry: RepoEntry) -> Bool? {
        guard let repo = URL(string: entry.baseURL) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let endpoint = endpoints[key(repo)] else { return nil }
        return purchases[key(endpoint) + "|" + entry.package]
    }

    func resolve(_ entry: RepoEntry, taskStarted: @escaping (URLSessionTask) -> Void,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.resolve(entry, taskStarted: taskStarted, completion: completion) }
            return
        }
        guard entry.isCommercial else {
            if let url = entry.downloadURL { completion(.success(url)) }
            else { completion(.failure(DKError.message(DKL("索引中没有下载地址")))) }
            return
        }
        guard let repo = URL(string: entry.baseURL), repo.scheme == "https", !entry.package.contains("/"), !entry.package.isEmpty else {
            completion(.failure(DKError.message(DKL("无法读取软件包"))))
            return
        }
        lock.lock()
        let endpoint = endpoints[key(repo)]
        lock.unlock()
        if let endpoint = endpoint {
            authorize(entry, endpoint: endpoint, taskStarted: taskStarted, completion: completion)
        } else {
            let request = URLRequest(url: repo.appendingPathComponent("payment_endpoint"))
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                self.observe(request, data: data, response: response, error: error)
                DispatchQueue.main.async {
                    self.lock.lock()
                    let endpoint = self.endpoints[self.key(repo)]
                    self.lock.unlock()
                    guard let endpoint = endpoint else {
                        completion(.failure(error ?? DKError.message(DKL("无法取得软件源的商店地址"))))
                        return
                    }
                    self.authorize(entry, endpoint: endpoint, taskStarted: taskStarted, completion: completion)
                }
            }
            taskStarted(task)
            task.resume()
        }
    }

    private func authorize(_ entry: RepoEntry, endpoint: URL, taskStarted: @escaping (URLSessionTask) -> Void,
                           completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        let template = templates[key(endpoint)]
        lock.unlock()
        guard var request = template, let data = request.httpBody,
              var body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            completion(.failure(DKError.message(DKL("请先在 Sileo 中登录该源账户并打开此插件详情页"))))
            return
        }
        request.url = endpoint.appendingPathComponent("package").appendingPathComponent(entry.package).appendingPathComponent("info")
        send(request, taskStarted: taskStarted) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let info):
                guard let purchased = info["purchased"] as? NSNumber else {
                    completion(.failure(DKError.message(DKL("商店返回了无效的授权信息"))))
                    return
                }
                guard purchased.boolValue else {
                    completion(.failure(DKError.message(DKL("此插件尚未购买，请先在 Sileo 中购买"))))
                    return
                }
                body["version"] = entry.version
                body["repo"] = entry.baseURL
                body["architecture"] = entry.architecture
                request.url = endpoint.appendingPathComponent("package").appendingPathComponent(entry.package).appendingPathComponent("authorize_download")
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    request.setValue(nil, forHTTPHeaderField: "Content-Length")
                }
                catch { completion(.failure(error)); return }
                self.send(request, taskStarted: taskStarted) { result in
                    completion(result.flatMap { json in
                        guard let text = json["url"] as? String, let url = URL(string: text), url.scheme == "https" else {
                            return .failure(DKError.message(DKL("商店返回了无效的下载地址")))
                        }
                        return .success(url)
                    })
                }
            }
        }
    }

    private func send(_ request: URLRequest, taskStarted: @escaping (URLSessionTask) -> Void,
                      completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            self.observe(request, data: data, response: response, error: error)
            let result: Result<[String: Any], Error> = Result {
                if let error = error { throw error }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw DKError.message(DKL("商店授权失败，请在 Sileo 中确认登录状态"))
                }
                guard let data = data, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw DKError.message(DKL("商店返回了无效的授权信息"))
                }
                if let message = json["error"] as? String { throw DKError.message(message) }
                guard (json["success"] as? Bool) != false else {
                    throw DKError.message(DKL("商店授权失败，请在 Sileo 中确认登录状态"))
                }
                return json
            }
            DispatchQueue.main.async { completion(result) }
        }
        taskStarted(task)
        task.resume()
    }
}
