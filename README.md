# GPT55StatusBarApp

独立 macOS 菜单栏 App，不依赖 SwiftBar。

## 构建

```bash
./build.sh
```

构建产物会输出到 `build/GPT55StatusBarApp.app`。

## 功能

- 菜单栏显示 `GPT5.5`
- 每 60 秒请求一次 `https://status.input.im/api/status`
- 只监控 `gpt-5.5`
- 下拉面板显示状态、30 段条状物、打开状态页、手动刷新
