#!/usr/bin/env bash
# 用 Safari 同引擎（WKWebView）打开面板，验证「浏览器到底能不能打开」。
#   - 默认不做任何证书豁免：证书不被信任 ⇒ 直接失败（这正是浏览器的行为）
#   - 鉴权页（面板本体 /wg/*）必须带凭据测：**不带凭据的 WKWebView 收到 401 后只会一直等（-1001 超时）**，
#     那是测试工具的假阴性，不代表浏览器打不开。
#
# 用法：
#   KELP_PANEL_USER=… KELP_PANEL_PASS=… bash check-panel-in-browser.sh https://47.116.73.216:18080/
#   bash check-panel-in-browser.sh https://47.116.73.216:18080/dl/          # 公开页，无需凭据
set -uo pipefail
URL="${1:-https://47.116.73.216:18080/}"
NEED_AUTH="${2:-auto}"

cat > /tmp/kelp_wkcheck.swift <<'SWIFT'
import Cocoa
import WebKit

final class Delegate: NSObject, WKNavigationDelegate {
    private var finished = false
    private let user = ProcessInfo.processInfo.environment["KELP_PANEL_USER"] ?? ""
    private let pass = ProcessInfo.processInfo.environment["KELP_PANEL_PASS"] ?? ""

    func webView(_ w: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let m = challenge.protectionSpace.authenticationMethod
        if m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodDefault {
            if user.isEmpty {
                print("   ⚠️ 收到 401 质询但没有凭据 —— 浏览器此时会弹登录框；本例将无法继续（属测试假阴性）")
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .none))
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        guard !finished else { return }; finished = true
        print("✅ 浏览器可加载：\(w.url?.absoluteString ?? "-")")
        print("   标题: \(w.title ?? "-")")
        w.evaluateJavaScript("document.body ? document.body.innerText.replace(/\\s+/g,' ').slice(0,100) : ''") { r, _ in
            print("   正文: \((r as? String ?? ""))")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        guard !finished else { return }; finished = true
        let ns = e as NSError
        print("❌ 浏览器会打不开：\(e.localizedDescription)（domain=\(ns.domain) code=\(ns.code)）")
        if ns.code == -1001, user.isEmpty { print("   ↳ 提示：若这是鉴权页，属无凭据的假阴性，请带 KELP_PANEL_USER/PASS 重测") }
        exit(2)
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        guard !finished else { return }; finished = true
        print("❌ 加载失败: \(e.localizedDescription)")
        exit(3)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: WKWebViewConfiguration())
let d = Delegate()
w.navigationDelegate = d
guard let url = URL(string: CommandLine.arguments[1]) else { print("URL 非法"); exit(9) }
w.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("⏱ 超时：既没成功也没报错（浏览器会一直转圈）"); exit(4) }
app.run()
SWIFT
swiftc -O -o /tmp/kelp_wkcheck /tmp/kelp_wkcheck.swift 2>/dev/null || { echo "编译失败（需要 Xcode Command Line Tools 的 swiftc）"; exit 9; }
/tmp/kelp_wkcheck "$URL"
