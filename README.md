# DeepSeek 转 API（DSWebAPI）

> 把 **DeepSeek 网页版的对话框**，变成一个任何客户端都能调的 **OpenAI 兼容 API**。

iOS App 在本机跑一个 HTTP 服务，把网页端内部接口翻译成标准 OpenAI 协议：

```
你的客户端（Cherry Studio / LobeChat / OpenAI SDK / curl / 浏览器）
        │  POST http://<你的iPhone>:8787/v1/chat/completions
        ▼
   DSWebAPI（iPhone 上的 HTTP 服务）
        │  POST https://chat.deepseek.com/api/v0/chat/completions
        │  Authorization: Bearer <网页端 access token>
        ▼
   DeepSeek 网页端
```

## 三个界面，同一条链路

| 位置 | 说明 |
| --- | --- |
| **App 内「聊天」页** | 原生聊天框。它发出的每一句话都先请求本机 `127.0.0.1` 的 `/v1/chat/completions`，再转发给 DeepSeek —— 等于随时在自测这条链路 |
| **App 内「接口」页** | 展示本机 / 局域网接入地址、curl 示例、OpenAI SDK 示例，一键复制 |
| **浏览器里的网页聊天框** | App 内置一个网页聊天页（`http://<iPhone>:8787/`），同一个 Wi-Fi 下用电脑打开就像在用 DeepSeek 网页版，但它调用的是上面这个 API |

## 提供的接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/` | 内置网页聊天框 |
| GET | `/health` | 健康检查（返回是否有凭证、当前模型等） |
| GET | `/v1/models` | 模型列表：`deepseek-chat` / `deepseek-reasoner` / `deepseek-coder` |
| POST | `/v1/chat/completions` | 聊天补全，支持 `stream: true`（SSE）与普通模式 |

请求体就是标准 OpenAI 格式：

```json
{
  "model": "deepseek-chat",
  "stream": true,
  "messages": [{ "role": "user", "content": "你好" }]
}
```

## 怎么用

1. 装好 App，打开「设置 → 在 App 内登录并自动抓取」，在弹出的网页里登录 DeepSeek。
   App 会自己从网页的 localStorage / Cookie 里把 access token 抠出来，存进钥匙串。
   （也可以手动粘贴 access token 或 session cookie）
2. 回到「接口」页点「启动」，服务默认监听 `8787` 端口。
3. 「接口」页复制接入地址：
   - 本机：`http://127.0.0.1:8787/v1`
   - 局域网：`http://192.168.x.x:8787/v1`
4. 在任何支持 OpenAI 协议的软件里把 Base URL 填成上面的地址即可。

> 同一个 Wi-Fi 下用电脑访问手机上的服务，需要电脑和手机在同一网段，且 App 保持前台或开启「后台保活」。

## 安全

- access token / session cookie 只存在 iOS 钥匙串（Keychain），不写 UserDefaults、不上传任何第三方。
- 可以给本地 API 设置一个 `本地 API Key`，之后所有请求都要带 `Authorization: Bearer <key>`，避免同网段别人白用。
- 本机地址 `127.0.0.1` 只有本机能访问；局域网地址请在公共 Wi-Fi 下慎用。

## 工程

- SwiftUI + XcodeGen，无第三方依赖（HTTP 服务基于 Network.framework 手写）
- 单元测试覆盖 SSE 解析、上游事件翻译、凭证提取、请求构造
- CI：Build & Test / Unsigned IPA（`ios-ci-workflows` v1.1.0）

## 免责声明

本项目调用的是 DeepSeek 网页端内部接口，属于非公开协议，随时可能变化，也随时可能失效。
仅供学习研究使用，请遵守 DeepSeek 的服务条款，不要用于批量压测或商业转售。
