import io, os, sys

ROOT = "/var/minis/shared/DSWebAPI/DSWebAPI"

def patch(path, pairs):
    p = os.path.join(ROOT, path)
    src = io.open(p, encoding="utf-8").read()
    for old, new in pairs:
        if old not in src:
            print("MISS  %s :: %s" % (path, old[:70].replace("\n", "\\n")))
            sys.exit(1)
        src = src.replace(old, new, 1)
    io.open(p, "w", encoding="utf-8").write(src)
    print("OK    %s (%d edits)" % (path, len(pairs)))

# 1) OpenAIEnvelope: String + Substring 编译错误 + finish_reason 的 Optional 嵌套坑
patch("Upstream/OpenAIEnvelope.swift", [
    ('init(model: String, id: String = "chatcmpl-" + UUID().uuidString.prefix(24), created: Int = Int(Date().timeIntervalSince1970)) {',
     'init(model: String, id: String = "chatcmpl-" + String(UUID().uuidString.prefix(24)), created: Int = Int(Date().timeIntervalSince1970)) {'),
    ('''        let payload: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishReason as Any? ?? NSNull()
            ]]
        ]''',
     '''        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let reason = finishReason {
            choice["finish_reason"] = reason
        } else {
            choice["finish_reason"] = NSNull()
        }
        let payload: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [choice]
        ]'''),
])

# 2) NetworkInfo: CChar 不能直接和字符串比较
patch("Core/NetworkInfo.swift", [
    ('''            guard interface.ifa_name.pointee == "en0" || interface.ifa_name.pointee == "en1" else { continue }''',
     '''            let interfaceName = String(cString: interface.ifa_name)
            guard interfaceName == "en0" || interfaceName == "en1" else { continue }'''),
    ('''            if interface.ifa_name.pointee == "en0" { return value }''',
     '''            if interfaceName == "en0" { return value }'''),
])

# 3) RootView: UIPasteboard 需要 UIKit
patch("Views/RootView.swift", [
    ("import SwiftUI\n", "import SwiftUI\nimport UIKit\n"),
])

# 4) ChatModels: 去掉没用到的 OpenAIChatRequest（BridgeServer 自己解析 JSON）
p = os.path.join(ROOT, "Models/ChatModels.swift")
src = io.open(p, encoding="utf-8").read()
marker = "// MARK: - OpenAI 兼容的请求体"
if marker in src:
    src = src[:src.index(marker)].rstrip() + "\n"
    io.open(p, "w", encoding="utf-8").write(src)
    print("OK    Models/ChatModels.swift (removed unused request model)")
else:
    print("SKIP  Models/ChatModels.swift")

# 5) SettingsView: 版本号读取加括号
patch("Views/SettingsView.swift", [
    ('Text("版本 \\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")',
     'Text("版本 \\((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0")")'),
])

# 6) BridgeServer: 同样加括号
patch("Core/BridgeServer.swift", [
    ('"version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",',
     '"version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0",'),
])
