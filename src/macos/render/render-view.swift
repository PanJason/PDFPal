import SwiftUI
import WebKit

struct RenderView: NSViewRepresentable {
    let result: RenderResult
    let baseURL: URL?
    var allowsScrolling: Bool = true
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onContentHeightChange = onContentHeightChange

        guard context.coordinator.lastHTML != result.html || context.coordinator.lastBaseURL != baseURL else {
            if onContentHeightChange != nil {
                context.coordinator.measureContentHeight(in: webView)
            }
            return
        }

        context.coordinator.lastHTML = result.html
        context.coordinator.lastBaseURL = baseURL
        webView.loadHTMLString(result.html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""
        var lastBaseURL: URL?
        var onContentHeightChange: ((CGFloat) -> Void)?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measureContentHeight(in: webView)
        }

        func measureContentHeight(in webView: WKWebView) {
            guard let onContentHeightChange else { return }
            webView.evaluateJavaScript(
                "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);"
            ) { value, _ in
                guard let value else { return }
                let height: CGFloat?
                if let number = value as? NSNumber {
                    height = CGFloat(truncating: number)
                } else if let doubleValue = value as? Double {
                    height = CGFloat(doubleValue)
                } else {
                    height = nil
                }
                guard let height, height > 0 else { return }
                DispatchQueue.main.async {
                    onContentHeightChange(height)
                }
            }
        }
    }
}
