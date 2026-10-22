# DSWebAPI

DeepSeek 网页端 → OpenAI 兼容 API 的 iOS 客户端。

## 开发规则

- 本地没有 macOS，**编译和测试只走 CI**（`ios-ci-workflows` v1.1.0）。
  改完代码 `git push`，读 Build & Test 报告再修，不要在本地假装测过。
- 工程用 XcodeGen 生成：`xcodegen generate`（`project.yml` 是唯一真相源，`.xcodeproj` 不入库）。
- 新功能必须带测试：逻辑测试写在 `DSWebAPITests/`，能用逻辑测的别写成 UI 测试。
- 不在代码、日志、workflow 里写明文密钥；用户的 DeepSeek token 只进钥匙串。
- 有意改了界面要重录快照，并在 PR 里写清改了哪些页面。

## 目录

```
DSWebAPI/
  Core/      HttpServer（手写 HTTP 服务）、BridgeServer（路由 + 协议翻译）、AppStore、LocalAPIClient
  Upstream/  DeepSeekWebClient（上游协议）、SSEParser、UpstreamEventParser、OpenAIEnvelope
  Security/  KeychainStore、CredentialExtractor、LoginWebView（内嵌网页登录抓 token）
  Views/     ChatView（原生聊天框）、ApiView（接口页）、SettingsView
  Resources/ chat.html（内置网页聊天框）
```

## 注意

- DeepSeek 网页端接口没有公开文档，解析层要**容错**（`UpstreamEventParser`）。
  协议变了先在「设置 → 记录上游原始事件」里看原始 SSE，再改解析器。
- HTTP 服务基于 Network.framework 手写：`Content-Length` 解析、`Connection: close`、逐块写出。
