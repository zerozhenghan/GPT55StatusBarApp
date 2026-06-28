# GPT55StatusBarApp

独立 macOS 菜单栏 App，不依赖 SwiftBar。

## 构建

```bash
./build.sh
```

构建产物会输出到 `build/GPT55StatusBarApp.app`。

## 功能

- 菜单栏默认显示主站点今日消耗，也可以通过配置切换为余额、耗时、状态或模型名
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

多站点示例：

```env
# 原站点
INPUT_IM_ACCOUNT_NAME=Codex
INPUT_IM_BASE_URL=https://ai.input.im
INPUT_IM_API_KEY=你的原站点 Key

# Lucen
LUCEN_ACCOUNT_NAME=Lucen
LUCEN_BASE_URL=https://lucen.cc
LUCEN_API_KEY=你的 Lucen Key
```

如果只写一行 Key，会默认当作 Lucen Key：

```env
你的 API Key
```

### 菜单栏显示设置

菜单栏默认显示第一个可用站点的今日消耗，只显示具体数值和单位：

```env
MENU_BAR_DISPLAY=today_cost
```

如果要改成余额：

```env
MENU_BAR_DISPLAY=balance
```

可选值：

- `today_cost`：今日消耗，例如 `$11.41`
- `balance`：余额，例如 `$20.00`
- `average_duration`：平均耗时，例如 `耗时 46.0s`
- `status`：GPT-5.5 服务状态，例如 `状态 在线`
- `model`：模型名，例如 `GPT-5.5`
- `site_name`：站点名，例如 `Lucen`

如果有多个站点，可以指定菜单栏使用哪个站点：

```env
MENU_BAR_SITE=Lucen
MENU_BAR_DISPLAY=today_cost
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
