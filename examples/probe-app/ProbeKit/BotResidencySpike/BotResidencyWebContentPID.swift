// SPDX-License-Identifier: MIT
#if BOT_RESIDENCY_SPIKE

import WebKit

public enum BotResidencyWebContentPID {
    public static func read(from webView: WKWebView) -> Int? {
        let key = "_webContentProcessIdentifier"
        let selector = NSSelectorFromString(key)
        guard webView.responds(to: selector),
              let value = webView.value(forKey: key) as? NSNumber else {
            return nil
        }
        let pid = value.intValue
        return pid > 0 ? Int(pid) : nil
    }
}
#endif
