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

## 给别人部署时配置密钥

App 默认可以直接查询 `GPT-5.5` 状态；如果要显示余额、今日、本周、本月和有效期，需要额外配置 `https://ai.input.im` 的 API Key。

不要把 API Key 提交到 GitHub。

### 方式一：使用 `账号配置.env`

在 App 同级目录，或者项目根目录放一个 `账号配置.env`：

```env
INPUT_IM_API_KEY=你的 API Key
INPUT_IM_BASE_URL=https://ai.input.im
INPUT_IM_ACCOUNT_NAME=Codex
```

也支持只写一行 Key：

```env
你的 API Key
```

### 方式二：使用环境变量

```bash
INPUT_IM_API_KEY="你的 API Key" \
INPUT_IM_BASE_URL="https://ai.input.im" \
INPUT_IM_ACCOUNT_NAME="Codex" \
open build/GPT55StatusBarApp.app
```

### 方式三：使用配置文件

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

### 可显示的数据

当前会读取：

- `remaining`：余额
- `subscription.daily_usage_usd`：今日用量
- `subscription.weekly_usage_usd`：本周用量
- `subscription.monthly_usage_usd`：本月用量
- `subscription.expires_at`：订阅有效期

读取优先级：环境变量 > `账号配置.env` > `config.json`。
