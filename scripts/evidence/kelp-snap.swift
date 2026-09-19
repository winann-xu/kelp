import Cocoa
import WebKit

// 离屏渲染面板页面并截图：swift kelp-snap.swift <url> <user> <pass> <out.png> [宽] [高]
let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: snap <url> <user> <pass> <out.png> [w] [h]"); exit(2) }
let url = URL(string: args[1])!
let user = args[2], pass = args[3], out = args[4]
let width = args.count > 5 ? Double(args[5])! : 1180
let height = args.count > 6 ? Double(args[6])! : 1000

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Delegate: NSObject, WKNavigationDelegate {
    let user: String, pass: String, out: String
    var done = false
    init(user: String, pass: String, out: String) { self.user = user; self.pass = pass; self.out = out }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        // 面板已启用自签证书：仅对本项目地址放行服务器信任，其余保持默认校验
        let trustedHosts = ["47.116.73.216", "127.0.0.1", "localhost"]
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           trustedHosts.contains(space.host), let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
            completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .none))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("load failed: \(error.localizedDescription)")
        self.done = true
        NSApp.terminate(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等 JS 拉取数据并渲染
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: webView.frame.width, height: webView.frame.height)
            webView.takeSnapshot(with: cfg) { image, error in
                if let image = image,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: self.out))
                    print("snapshot saved: \(self.out) \(Int(image.size.width))x\(Int(image.size.height))")
                } else {
                    print("snapshot failed: \(error?.localizedDescription ?? "unknown")")
                }
                self.done = true
                NSApp.terminate(nil)
            }
        }
    }
}

let delegate = Delegate(user: user, pass: pass, out: out)
let config = WKWebViewConfiguration()
let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
webView.navigationDelegate = delegate

let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = webView
window.orderBack(nil)   // 不进前台，避免打扰
webView.load(URLRequest(url: url))

DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    if !delegate.done { print("timeout"); exit(1) }
}
app.run()
