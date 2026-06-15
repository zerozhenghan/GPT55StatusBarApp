# GPT55StatusBarApp

独立 macOS 菜单栏 App，不依赖 SwiftBar。

## 构建

```bash
./build.sh
```

构建产物会输出到 `build/GPT55StatusBarApp.app`。

## 功能

- 菜单栏显示 `GPT-5.5`
- 每 60 秒请求一次 `https://status.input.im/api/status`
- 只监控 `gpt-5.5`
- 下拉面板显示深色毛玻璃状态面板、60 段状态条、打开状态页、手动刷新
- 可选读取 `https://ai.input.im/v1/usage` 显示余额和用量字段

## 用量配置

如果要显示余额和用量，在下面路径创建配置文件：

```text
~/Library/Application Support/GPT55StatusBarApp/config.json
```

示例：

```json
{
  "name": "Codex",
  "base_url": "https://ai.input.im",
  "api_key": "你的 API Key"
}
```

也可以用环境变量启动：

```bash
INPUT_IM_API_KEY="你的 API Key" INPUT_IM_BASE_URL="https://ai.input.im" open build/GPT55StatusBarApp.app
```
