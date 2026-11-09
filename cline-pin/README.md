# cline-pin

把 Zed 里 `cline-pass/*` 的请求钉到指定上游（默认 DeepSeek 官方）。

## 为什么必须用反代

`cline-pass/deepseek-v4.1-flash-1017` 是个 VMC（virtual model config），默认落在**免费的私有 contributor 池**（`openai-compatible-private`, `cost: 0`）。实测结论：

- 只写 `providerOptions.gateway.only` **没用**，私有池会忽略它直接接走请求。
- 真正把私有池排除掉的是 `providerOptions.gateway.has` —— 私有池没有任何能力声明，所以任何 `has` 都会让它落选，之后 `only` 才在公开池里生效。
- `has` 的取值必须是 kebab-case：`reasoning` / `tool-use` / `vision` / `structured-output` / `implicit-caching` / `free`，写 `tool_use` 会 400。

而 Zed 的 `openai_compatible` provider 不支持 `extra_body`，MCP 和扩展也拦不到模型请求，所以只能在传输层注入。

## 文件

| 文件 | 作用 |
|---|---|
| `proxy.mjs` | 本地反代，注入 `only` / `has`，SSE 逐字节透传，并记录每次请求的 `finalProvider` |
| `check-upstream.mjs` | 主动验证落点。故意不带 `providerOptions`，用来证明注入是代理做的 |
| `start-cline-pin.cmd` | Windows 双击启动 |

## 用法

1) 启动代理（在本目录下执行；保持窗口开着，或挂到计划任务）

```
node proxy.mjs
```

2) 改 Zed 的全局 `settings.json`（Windows: `%APPDATA%\Zed\settings.json`）

```jsonc
"language_models": {
  "openai_compatible": {
    "cline": {
      "api_url": "http://127.0.0.1:8788/api/v1",   // 原来是 https://api.cline.bot/api/v1
      "available_models": [ /* 保持不变 */ ]
    }
  }
}
```

3) 验证

```
curl http://127.0.0.1:8788/_health
CLINE_KEY=sk-xxx CLINE_BASE=http://127.0.0.1:8788/api/v1 CLINE_EXPECT=deepseek \
  node check-upstream.mjs --count 3
```

Windows 的 `cmd` / PowerShell 不支持上面这种写法，用 `set CLINE_KEY=sk-xxx` 后再 `node check-upstream.mjs --count 3`，或 PowerShell 的 `$env:CLINE_KEY="sk-xxx"`。

`check-upstream` 会在 **请求体里不带 providerOptions** 的情况下发请求。如果 `final=` 是 `deepseek`，说明代理确实生效了。退出码 0 表示全部命中。

4) 日常确认

代理每处理一个请求会追加写入本目录的 `cline-pin.log`（超过 5MB 轮转为 `cline-pin.log.1`），但**不刷控制台**。控制台只在异常时出声：

```
POST /api/v1/chat/completions inject model=cline-pass/deepseek-v4.1-flash-1017 only=["deepseek"] has=["tool-use"]
POST /api/v1/chat/completions finalProvider=deepseek
```

出现 `<-- 未按预期钉住!` 就是漂了（这一行会同时出现在控制台和文件里）。`/_health` 里的 `stats.finalProviders` 可以直接给监控用。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CLINE_PIN_PORT` | `8788` | 监听端口 |
| `CLINE_PIN_HOST` | `127.0.0.1` | 只监听本机，不对外暴露 |
| `CLINE_PIN_API_KEY` | 空 | 选填。配了就用它强制覆盖请求里的 key，客户端没带也会补上；值为 `sk-xxx` 时自动加 `Bearer ` 前缀，写了 `Bearer sk-xxx` 则原样用。不设时读本目录的 `cline-pin.key` |
| `CLINE_PIN_ONLY` | `deepseek` | 逗号分隔，如 `deepseek,fireworks` |
| `CLINE_PIN_HAS` | 空 | 额外追加的 has，如 `vision,tool-use` |
| `CLINE_PIN_FALLBACK` | `0` | 置 1 时上游 4xx/5xx 会去掉注入重试一次（会退回免费私有池，等于放弃钉住） |
| `CLINE_PIN_QUIET` | `0` | 置 1 关闭逐请求日志（文件也不写；异常仍输出） |
| `CLINE_PIN_LOG` | 本目录 `cline-pin.log` | 日志文件路径；置 `off` 则只输出到控制台 |
| `CLINE_PIN_UPSTREAM` | `https://api.cline.bot` | 仅测试用，指到 mock 上游 |
| `CLINE_PIN_MODEL_FILTER` | `deepseek` | 只给 model 名包含这个子串的请求注入；置空则不限制 |

`has` 由请求体自动推导，至少会给一个：

- 有 `tools` → 加 `tool-use`
- 内容里有 `image_url` → 加 `vision`
- 有 `response_format` → 加 `structured-output`
- 都没有 → 加 `reasoning`

只对 model 名包含 `deepseek` 的请求注入（`CLINE_PIN_MODEL_FILTER`）。这样以后往同一个 `cline` provider 里加别的模型，不会被强行钉到 DeepSeek。

配了 `CLINE_PIN_API_KEY` 时，代理会在转发前把 `Authorization` 换成它（同时覆盖客户端发来的 `api-key` / `x-api-key`），不区分接口和模型，客户端带不带 key 都一样。启动 banner 的「强制 key」行和 `/_health` 里的 `pin.authOverride` 可以确认是否生效（都不会打印 key 本体）。

### key 放哪

**不要把 key 写进源码。** `proxy.mjs` 是进版本库的，写死的 key 等于公开——这个仓库就发生过一次，只能换 key 才能收场。

代理按这个顺序取 key：

1. 环境变量 `CLINE_PIN_API_KEY`
2. 本目录的 `cline-pin.key`（已在 `.gitignore` 里，不会进仓库）
3. 都没有 → 透传客户端自己带的 key

最省事的是第 2 种，写一行就行：

```
# D:\z7z8\cline-pin\cline-pin.key  （单行，不要加引号）
sk_xxxxxxxx
```

如果想用环境变量，`start-cline-pin.cmd` 里加一行 `set CLINE_PIN_API_KEY=sk_xxx` 也可以，但那个文件同样进版本库，**别把真 key 写进去**。

## 代价

- 钉住后**按量计费**，`is_byok: false`，走系统凭据。实测短请求 0.000006~0.000024 USD/次。免费私有池是 `cost: 0`，两者只能二选一。
- 响应里 `fallbacksAvailable: []`，DeepSeek 官方挂了就是报错，**不会**静默切到 fireworks/togetherai。需要可用性优先就开 `CLINE_PIN_FALLBACK=1`。
- 判定落点只能看 `provider_metadata.gateway.routing.finalProvider`，响应里的 `model` 恒为 `vmc/deepseek-v4p1-flash-1017-contributor-fallbacks`，跟实际上游无关。

## 回滚

```
# 设置
cp "$APPDATA/Zed/settings.json.bak-cline-pin" "$APPDATA/Zed/settings.json"
# 或手动把 api_url 改回 https://api.cline.bot/api/v1，然后重启 Zed
```

停代理：关掉那个命令行窗口，或

```
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { $_.CommandLine -like '*cline-pin*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
```

## 排错

- **代理没起**：Zed 里会直接连接失败（不是超时）。先 `curl http://127.0.0.1:8788/_health`。
- **端口占用**：换 `CLINE_PIN_PORT`，同时改 `api_url`。
- **401**：key 失效，直连同一个 key 也会 401，与代理无关。
- **没钉住**：看 `inject` 日志里的 `has` 是否为空——为空说明请求体里既没 tools 也没图片，理论上代理会补 `reasoning`；若仍是空，检查是否有别的进程在动请求体。
- **改了设置没生效**：Zed 需要重新加载设置/重启窗口，`api_url` 不会热迁移已在进行的流。
