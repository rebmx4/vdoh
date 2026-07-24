import UIKit
import WebKit
import SafariServices
import AVFoundation

class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AVAudioPlayerDelegate {

    private var webView: WKWebView!
    private var progressView: UIProgressView!
    private var offlineView: UIView!
    private let refreshControl = UIRefreshControl()

    private let bgColor = UIColor(red: 0.09, green: 0.094, blue: 0.106, alpha: 1) // #17181B

    // Нативный TTS: голос гипнолога играем в Swift (.playback = громко + правильный маршрут)
    private var ttsPlayer: AVAudioPlayer?
    private var ttsCompletionId: String?
    private let ttsBaseURL = "https://rynpro.ru/nlp"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        setupAudioSession()
        setupWebView()
        setupProgress()
        setupOffline()
        setupAudioDebug()
        loadRoot()
    }

    // MARK: - Audio session (voice recording + loud playback, incl. Bluetooth)
    private var audioRouteTimer: Timer?
    private let headphonePorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
        .airPlay, .carAudio, .usbAudio, .lineOut
    ]

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .default mode (not .voiceChat) avoids AGC ducking that made TTS quiet.
            try session.setCategory(.playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true, options: [])
            refreshAudioRoute()
        } catch {
            print("AudioSession setup error: \(error)")
        }
        // Наушники вкл/выкл на лету
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
        // Возврат в приложение — WebKit мог перенастроить сессию
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        // ГЛАВНАЯ СТРАХОВКА: WebKit при активном микрофоне сбрасывает вывод в тихий
        // разговорный динамик без уведомления. Раз в 2 сек ловим это и возвращаем громкий.
        audioRouteTimer?.invalidate()
        audioRouteTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tickAudioRoute()
        }
    }

    // Полный пересчёт: снимаем форс (иначе наушники прячутся из маршрута), честно смотрим
    // реальный выход, затем при отсутствии наушников возвращаем громкий динамик.
    private func refreshAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
        let hasHeadphones = session.currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
        if !hasHeadphones {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    // Лёгкая проверка по таймеру: если звук ушёл в тихий receiver — вернуть громкий динамик.
    // (Наушники система в receiver не отправляет, поэтому им это не мешает.)
    private func tickAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        let onReceiver = session.currentRoute.outputs.contains { $0.portType == .builtInReceiver }
        if onReceiver {
            try? session.overrideOutputAudioPort(.speaker)
        }
        updateAudioDebug()
    }

    @objc private func handleRouteChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshAudioRoute()
            self?.updateAudioDebug()
        }
    }

    // ── Аудио-диагностика на экране (временно, чтобы найти причину тихого звука) ──
    private var audioDebugLabel: UILabel?
    private func setupAudioDebug() {
        let l = UILabel()
        l.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        l.textColor = UIColor(white: 1, alpha: 0.6)
        l.numberOfLines = 2
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -1),
        ])
        audioDebugLabel = l
        updateAudioDebug()
    }
    private func updateAudioDebug() {
        let s = AVAudioSession.sharedInstance()
        let out = s.currentRoute.outputs.map { $0.portType.rawValue.replacingOccurrences(of: "AVAudioSessionPort", with: "") }.joined(separator: ",")
        let cat = s.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let tts = (ttsPlayer?.isPlaying == true) ? "PLAY" : "idle"
        let vol = String(format: "%.2f", s.outputVolume)
        DispatchQueue.main.async {
            self.audioDebugLabel?.text = "out:\(out) · cat:\(cat) · tts:\(tts) · vol:\(vol)"
        }
    }

    // MARK: - Native TTS (голос гипнолога — нативное воспроизведение, громко и с любым устройством)

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nativeTTS", let body = message.body as? [String: Any] else { return }
        let action = body["action"] as? String ?? "play"
        if action == "stop" {
            ttsPlayer?.stop(); ttsPlayer = nil; ttsCompletionId = nil
            return
        }
        guard let text = body["text"] as? String, let id = body["id"] as? String else { return }
        let voice = body["voice"] as? String ?? "ermil"
        playNativeTTS(text: text, voice: voice, id: id)
    }

    private func playNativeTTS(text: String, voice: String, id: String) {
        guard let url = URL(string: ttsBaseURL + "/api/tts") else { notifyTTSDone(id); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let payload: [String: Any] = ["text": text, "voice": voice, "emotion": "neutral", "speed": 1.0]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self, let data = data, err == nil, data.count > 200 else {
                DispatchQueue.main.async { self?.notifyTTSDone(id) }
                return
            }
            DispatchQueue.main.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    // .playback громко и сам маршрутизирует на динамик/наушники/Bluetooth/CarPlay
                    try? session.setCategory(.playback, mode: .spokenAudio,
                        options: [.allowBluetoothA2DP, .allowAirPlay])
                    try? session.setActive(true, options: [])
                    // Форсируем громкий динамик, если нет наушников/Bluetooth
                    let hp = session.currentRoute.outputs.contains { self.headphonePorts.contains($0.portType) }
                    if !hp { try? session.overrideOutputAudioPort(.speaker) }
                    self.updateAudioDebug()
                    self.ttsPlayer?.stop()
                    self.ttsPlayer = try AVAudioPlayer(data: data)
                    self.ttsPlayer?.delegate = self
                    self.ttsPlayer?.volume = 1.0
                    self.ttsCompletionId = id
                    if self.ttsPlayer?.play() != true { self.notifyTTSDone(id) }
                } catch {
                    print("Native TTS play error: \(error)")
                    self.notifyTTSDone(id)
                }
            }
        }.resume()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ttsCompletionId; ttsCompletionId = nil
        if let id = id { notifyTTSDone(id) }
    }

    private func notifyTTSDone(_ id: String) {
        let esc = id.replacingOccurrences(of: "'", with: "")
        webView?.evaluateJavaScript("window.__nativeTTSDone && window.__nativeTTSDone('\(esc)')",
                                    completionHandler: nil)
    }

    // MARK: - WebView

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        // Маркер для ios-compat.js (скрывает монетизацию, соц-логин, аналитику)
        ucc.addUserScript(WKUserScript(
            source: "window.__IS_IOS_APP = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        config.userContentController = ucc
        ucc.add(self, name: "nativeTTS")
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 14.0, *) {
            config.limitsNavigationsToAppBoundDomains = true
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = true
        webView.isOpaque = false
        webView.backgroundColor = bgColor
        // UA-маркер NLPiOS — его также ловит ios-compat.js
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 NLPiOS"
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        if pullToRefresh {
            refreshControl.tintColor = .lightGray
            refreshControl.addTarget(self, action: #selector(reloadWeb), for: .valueChanged)
            webView.scrollView.refreshControl = refreshControl
        }
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
    }

    private func setupProgress() {
        progressView = UIProgressView(progressViewStyle: .bar)
        progressView.progressTintColor = UIColor(red: 0.95, green: 0.82, blue: 0.48, alpha: 1) // gold
        progressView.trackTintColor = .clear
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    private func setupOffline() {
        offlineView = UIView()
        offlineView.backgroundColor = bgColor
        offlineView.isHidden = true
        offlineView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(offlineView)
        NSLayoutConstraint.activate([
            offlineView.topAnchor.constraint(equalTo: view.topAnchor),
            offlineView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            offlineView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            offlineView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let label = UILabel()
        label.text = "Нет подключения к интернету"
        label.textColor = .lightGray
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        let button = UIButton(type: .system)
        button.setTitle("Повторить", for: .normal)
        button.setTitleColor(UIColor(red: 0.95, green: 0.82, blue: 0.48, alpha: 1), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.addTarget(self, action: #selector(reloadWeb), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        offlineView.addSubview(label)
        offlineView.addSubview(button)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: offlineView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: offlineView.centerYAnchor, constant: -16),
            button.centerXAnchor.constraint(equalTo: offlineView.centerXAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
        ])
    }

    private func loadRoot() {
        offlineView.isHidden = true
        webView.load(URLRequest(url: rootUrl))
    }

    @objc private func reloadWeb() {
        offlineView.isHidden = true
        if webView.url != nil { webView.reload() } else { loadRoot() }
    }

    // MARK: - KVO progress

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(WKWebView.estimatedProgress) {
            let p = Float(webView.estimatedProgress)
            progressView.setProgress(p, animated: true)
            progressView.isHidden = p >= 1.0
            if p >= 1.0 { progressView.setProgress(0, animated: false) }
        }
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
        NotificationCenter.default.removeObserver(self)
        audioRouteTimer?.invalidate()
        ttsPlayer?.stop()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        offlineView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showOfflineIfNeeded(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOfflineIfNeeded(error)
    }

    private func showOfflineIfNeeded(_ error: Error) {
        refreshControl.endRefreshing()
        let code = (error as NSError).code
        if code == NSURLErrorNotConnectedToInternet || code == NSURLErrorTimedOut || code == NSURLErrorCannotConnectToHost {
            offlineView.isHidden = false
        }
    }

    // Keep rynpro.ru inside the app, open everything else in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "tel" || scheme == "mailto" {
            UIApplication.shared.open(url); decisionHandler(.cancel); return
        }
        if let host = url.host, allowedOrigins.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            decisionHandler(.allow); return
        }
        if scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    // Open target=_blank in the same web view
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // Grant getUserMedia (microphone) inside WKWebView — required for voice sessions.
    // Without this, the web layer's getUserMedia() is silently denied.
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
        // «Тихий голос»: WebKit при старте микрофона переводит вывод в тихий разговорный
        // динамик. Возвращаем громкий динамик сразу и ещё раз чуть позже (таймер добьёт).
        refreshAudioRoute()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshAudioRoute() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshAudioRoute() }
    }
}
