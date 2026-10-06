import SwiftUI
import WebKit

struct PreviewView: NSViewRepresentable {
    let controller: PreviewController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}

/// Avoids the retain cycle WKUserContentController creates with its handlers.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

struct PreviewOptions: Equatable {
    var font: String
    var fontSize: Double
    var width: Double
}

@MainActor
final class PreviewController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    weak var model: WindowModel?

    private var ready = false
    private var pendingRender: (markdown: String, base: String)?
    private var lastRendered: (markdown: String, base: String)?
    private var options: PreviewOptions?
    private var printJob: PrintJob?

    static var resourceDirectory: URL? {
        Bundle.main.url(forResource: "preview", withExtension: nil)
    }

    override init() {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        content.add(WeakMessageHandler(self), name: "inkwell")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        load()
    }

    private func load() {
        ready = false
        guard let url = Self.resourceDirectory?.appendingPathComponent("index.html") else { return }
        // Read access to the whole disk lets documents show images stored next to them.
        webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    // MARK: Rendering

    func render(_ markdown: String, base: String) {
        guard ready else {
            pendingRender = (markdown, base)
            return
        }
        if let last = lastRendered, last.markdown == markdown, last.base == base { return }
        lastRendered = (markdown, base)
        webView.callAsyncJavaScript("Inkwell.render(md, base)", arguments: ["md": markdown, "base": base],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func setOptions(_ new: PreviewOptions) {
        options = new
        guard ready else { return }
        webView.callAsyncJavaScript("Inkwell.setOptions(o)",
                                    arguments: ["o": ["font": new.font, "fontSize": new.fontSize, "width": new.width]],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func syncScroll(topLine: Double, totalLines: Int, headingLines: [Int], atBottom: Bool) {
        guard ready else { return }
        webView.callAsyncJavaScript("Inkwell.syncScroll(top, total, headings, bottom)",
                                    arguments: ["top": topLine, "total": totalLines, "headings": headingLines, "bottom": atBottom],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func scrollToHeading(index: Int, line: Int, total: Int) {
        guard ready else { return }
        webView.callAsyncJavaScript("Inkwell.scrollToHeading(i, line, total)",
                                    arguments: ["i": index, "line": line, "total": total],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func renderedHTML() async -> String? {
        guard ready else { return nil }
        return try? await webView.callAsyncJavaScript("return Inkwell.html()", contentWorld: .page) as? String
    }

    // MARK: WebKit

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            lastRendered = nil
            if let options { setOptions(options) }
            if let pending = pendingRender {
                pendingRender = nil
                render(pending.markdown, base: pending.base)
            } else if let model {
                render(model.text, base: model.baseURL)
            }
        case "copy":
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(body["text"] as? String ?? "", forType: .string)
        case "open":
            if let href = body["href"] as? String { open(href) }
        case "task":
            if let index = body["index"] as? Int { model?.toggleTask(index: index) }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL, let dir = Self.resourceDirectory, url.path.hasPrefix(dir.path) {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated { open(url.absoluteString) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        lastRendered = nil
        if let model { pendingRender = (model.text, model.baseURL) }
        load()
    }

    private func open(_ href: String) {
        guard let url = URL(string: href) ?? href.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else {
            return
        }
        if url.isFileURL {
            let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "txt"]
            var fileURL = url
            fileURL = URL(fileURLWithPath: url.path)  // drop any #fragment
            if markdownExtensions.contains(fileURL.pathExtension.lowercased()) {
                NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in }
            } else {
                // Never launch arbitrary local files from a document link; show them in Finder instead.
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        } else if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Export

    static func standaloneHTML(body: String, title: String, forPrint: Bool) -> String {
        let dir = resourceDirectory
        func read(_ path: String) -> String {
            guard let dir else { return "" }
            return (try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        let css = read("style.css")
        let light = read("vendor/hljs-light.css")
        let dark = read("vendor/hljs-dark.css")
        let codeCSS = forPrint ? light : "\(light)\n@media (prefers-color-scheme: dark) {\n\(dark)\n}"
        var katex = ""
        if body.contains("class=\"katex") {
            if forPrint, let dir {
                katex = "<link rel=\"stylesheet\" href=\"\(dir.appendingPathComponent("vendor/katex/katex.min.css").absoluteString)\">"
            } else {
                katex = "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.css\">"
            }
        }
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let printOverrides = forPrint
            ? "<style>:root { color-scheme: light; } body { padding: 0; } .markdown-body { max-width: none; }</style>"
            : ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        \(katex)
        <style>
        \(codeCSS)
        \(css)
        </style>
        \(printOverrides)
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    func print(body: String, title: String, window: NSWindow?, saveTo url: URL?) {
        let html = Self.standaloneHTML(body: body, title: title, forPrint: true)
        printJob = PrintJob(html: html, window: window, saveURL: url) { [weak self] in
            self?.printJob = nil
        }
    }
}

/// Renders standalone HTML in an offscreen web view and runs a paginated print operation
/// (to the printer, or straight to a PDF file).
@MainActor
private final class PrintJob: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let hostWindow: NSWindow
    private weak var window: NSWindow?
    private let saveURL: URL?
    private let tempFile: URL
    private let completion: () -> Void

    init(html: String, window: NSWindow?, saveURL: URL?, completion: @escaping () -> Void) {
        let frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        let config = WKWebViewConfiguration()
        config.preferences.shouldPrintBackgrounds = true
        webView = WKWebView(frame: frame, configuration: config)
        webView.appearance = NSAppearance(named: .aqua)
        // WebKit only paints content that lives in a window, so host it in an invisible one.
        hostWindow = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.alphaValue = 0
        hostWindow.ignoresMouseEvents = true
        hostWindow.contentView = webView
        hostWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        hostWindow.orderBack(nil)
        self.window = window
        self.saveURL = saveURL
        self.completion = completion
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkwell-print-\(UUID().uuidString).html")
        super.init()
        webView.navigationDelegate = self
        do {
            try html.write(to: tempFile, atomically: true, encoding: .utf8)
            webView.loadFileURL(tempFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } catch {
            finish()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give fonts and images a moment to settle before paginating.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.run() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }

    private func run() {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 48
        info.bottomMargin = 48
        info.leftMargin = 54
        info.rightMargin = 54
        if let saveURL {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = saveURL
        }
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = saveURL == nil
        op.showsProgressPanel = true
        op.view?.frame = webView.bounds
        // The asynchronous, window-attached path is required: a synchronous run() yields blank pages.
        let host = (saveURL == nil ? window : nil) ?? hostWindow
        op.runModal(for: host, delegate: self,
                    didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finish()
    }

    private func finish() {
        try? FileManager.default.removeItem(at: tempFile)
        hostWindow.orderOut(nil)
        completion()
    }
}
