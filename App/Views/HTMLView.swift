import SwiftUI
import WebKit

/// Renders message content. Scripts never run; remote content loads only on request.
struct HTMLView: UIViewRepresentable {
    let html: String
    let allowRemoteContent: Bool
    @Binding var height: CGFloat

    /// Blocks every network load; data: URLs (inline images) still work.
    private static let blockRules = """
    [{"trigger": {"url-filter": "^(https?|wss?|ftp):"}, "action": {"type": "block"}}]
    """

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.isOpaque = false
        view.backgroundColor = .clear
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        let signature = "\(allowRemoteContent)|\(html.hashValue)"
        guard context.coordinator.loaded != signature else { return }
        context.coordinator.loaded = signature
        context.coordinator.load(html, allowRemote: allowRemoteContent, into: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLView
        var loaded: String?
        private var observation: NSKeyValueObservation?

        init(_ parent: HTMLView) {
            self.parent = parent
        }

        func observe(_ view: WKWebView) {
            observation = view.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, change in
                guard let self, let size = change.newValue, size.height > 0 else { return }
                DispatchQueue.main.async {
                    if abs(self.parent.height - size.height) > 0.5 { self.parent.height = size.height }
                }
            }
        }

        func load(_ html: String, allowRemote: Bool, into view: WKWebView) {
            let controller = view.configuration.userContentController
            controller.removeAllContentRuleLists()
            let policy = allowRemote ? "" :
                "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:\">"
            let page = "<head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\(policy)</head>" + html
            guard !allowRemote else {
                view.loadHTMLString(page, baseURL: nil)
                return
            }
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "block-remote", encodedContentRuleList: HTMLView.blockRules) { list, _ in
                // Without the rule list the CSP above still blocks remote loads.
                if let list { controller.add(list) }
                view.loadHTMLString(page, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                await UIApplication.shared.open(url)
            }
            return .cancel
        }
    }
}

enum MessageHTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let link = try! NSRegularExpression(pattern: #"https?://[^\s<>"]+[^\s<>".,;:!?)\]]"#)

    /// Plain text as a page: escaped, links clickable, quoted lines dimmed.
    static func page(plain: String) -> String {
        let lines = plain.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line -> String in
            var escaped = escape(line)
            let ns = escaped as NSString
            for match in link.matches(in: escaped, range: NSRange(location: 0, length: ns.length)).reversed() {
                let url = ns.substring(with: match.range)
                escaped = (escaped as NSString).replacingCharacters(in: match.range, with: "<a href=\"\(url)\">\(url)</a>")
            }
            return line.hasPrefix(">") ? "<span class=\"q\">\(escaped)</span>" : escaped
        }
        return """
        <meta name="color-scheme" content="light dark">
        <style>
        body { font: -apple-system-body; margin: 0; padding: 0 2px; white-space: pre-wrap; overflow-wrap: anywhere; }
        .q { color: GrayText; }
        </style>
        <body>\(lines.joined(separator: "\n"))</body>
        """
    }

    /// HTML mail with styles that keep it inside the screen width.
    static func page(html: String) -> String {
        """
        <style>
        html, body { margin: 0; padding: 0; overflow-wrap: anywhere; }
        body { font: -apple-system-body; background: #fff; color: #000; padding: 8px; }
        img, table { max-width: 100% !important; height: auto; }
        </style>
        \(html)
        """
    }

    /// Rough check whether the mail references anything on the network.
    static func hasRemoteContent(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("src=\"http") || lower.contains("src='http") || lower.contains("url(http")
            || lower.contains("url(\"http") || lower.contains("url('http") || lower.contains("src=http")
    }
}
