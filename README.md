# Antigravity Login Skill

**退出 Antigravity → 给新进程设置代理 → 重新启动。**

一个可免费使用的 Windows 登录排障 Skill，附带 PowerShell 启动脚本。适用于浏览器能访问 Google、系统代理已开启，但 Antigravity 后台请求仍然超时的情况。

启动器给 Antigravity 及其子进程传入临时代理环境，默认使用 `http://127.0.0.1:7890`。不需要为了执行这套流程先开启 TUN。端口必须与实际代理软件一致，代理也必须能够访问目标服务。

## 这个项目能解决什么

部分应用后台不会沿用浏览器或 Windows 系统代理。启动前传入 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`，可以让支持这些变量的后台通过指定代理连接。`NO_PROXY` 保留本地回调通道。

这是一种经过实际使用验证的排障方法，不是所有版本、网络或账号都适用的通用登录保证。`account is ineligible`、所在地不支持等资格错误，需要检查账号本身。Google 登录网页上的“身份验证成功”也不等于客户端已经进入可用状态。

## 直接使用脚本

需要 Windows、Windows PowerShell 5.1 或 PowerShell 7，以及已经连接的 HTTP 代理。脚本不安装或提供代理服务。

先保存工作，再在本仓库目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\antigravity-login\scripts\Start-AntigravityWithProxy.ps1" -Restart
```

若你的代理端口不是 `7890`，明确指定它：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\antigravity-login\scripts\Start-AntigravityWithProxy.ps1" -ProxyUrl "http://127.0.0.1:7897" -Restart
```

自定义安装位置可加 `-AppPath "D:\Apps\Antigravity\Antigravity.exe"`。`7897` 只是示例，请使用你确认可用的端口。

`-Restart` 请求应用正常退出；如果应用没有退出，脚本会停止，提示你保存并手动关闭。它不会强行结束应用、改 Windows 系统代理、开启 TUN，或清除账号数据。

启动后，在 Google 页面选中自己的账号并完成授权，再回到 Antigravity 确认主界面。密码和验证码留在 Google 页面输入。

### 输出

脚本输出单个 JSON，便于 agent 判断：

- `status: started_with_proxy`：已启动进程，包含 PID；**不代表已登录**。
- `status: error`：启动前置条件或正常退出失败，包含错误代码和说明。

未传 `-Restart` 而应用已运行时会停止，防止旧实例沿用原来的环境。

## 安装到 Codex

克隆或下载本仓库后，将 **`antigravity-login` 文件夹整体**复制到 Codex 的 skills 目录。

```powershell
$skillsDirectory = if ($env:CODEX_HOME) {
    Join-Path $env:CODEX_HOME 'skills'
} else {
    Join-Path $env:USERPROFILE '.codex\skills'
}
$skillDestination = Join-Path $skillsDirectory 'antigravity-login'
if (Test-Path -LiteralPath $skillDestination) {
    throw 'Skill 已存在；请先比较内容，再决定是否更新。'
}
New-Item -ItemType Directory -Path $skillsDirectory -Force | Out-Null
Copy-Item -LiteralPath '.\antigravity-login' -Destination $skillsDirectory -Recurse
```

在能发现该 Skill 的 Codex 聊天中输入：

```text
$antigravity-login 帮我检查 Antigravity 登录问题，确认代理后正常退出并通过代理重新启动。
```

如果当前聊天尚未列出新技能，可新开聊天或重新启动客户端后尝试。支持 `SKILL.md` 的其他 agent 可以读取该文件及相对目录内的脚本；运行脚本仍需要 Windows。没有系统执行权限的 agent 可以按技能给出操作指导。

## 账号地区与订阅

系统代理、账号关联国家和订阅资格是分别检查的。遇到地区提示时，使用目标账号登录 [Google 服务条款](https://policies.google.com/terms)，并对照 [Antigravity 官方 FAQ](https://antigravity.google/docs/faq)。具体处理见 [账号资格说明](antigravity-login/references/account-eligibility.md)。

## 反馈与维护

反馈时提供 Windows / PowerShell / Antigravity 版本、代理端口、脱敏错误和客户端当前状态。不要上传密码、验证码、Cookies、访问令牌或 OAuth 回调链接。

修改启动器后运行隔离测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tests\Run-Tests.ps1"
```

本项目独立维护，与 Google 没有关联或官方背书。

## 许可

MIT。免费使用、修改和分享；再分发时保留许可及版权声明。见 [LICENSE](LICENSE)。
