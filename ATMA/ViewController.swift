import UIKit
import WebKit
import SafariServices
import AVFoundation

class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private var webView: WKWebView!
    private var progressView: UIProgressView!
    private var offlineView: UIView!
    private let refreshControl = UIRefreshControl()

    private let bgColor = UIColor(red: 0.09, green: 0.094, blue: 0.106, alpha: 1) // #17181B

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        setupAudioSession()
        setupWebView()
        setupProgress()
        setupOffline()
        loadRoot()
    }

    // MARK: - Audio session (voice recording + loud playback, incl. Bluetooth)
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .default mode (not .voiceChat) avoids AGC ducking that made TTS quiet.
            // .defaultToSpeaker routes to the loud speaker when no headset is connected.
            try session.setCategory(.playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true, options: [])
        } catch {
            print("AudioSession setup error: \(error)")
        }
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
    }
}
