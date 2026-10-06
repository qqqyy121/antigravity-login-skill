---
name: antigravity-login
description: "Use when Google Antigravity on Windows cannot sign in, stays at Awaiting Authentication, or its backend times out despite a working browser or system proxy; also when an account switch needs a per-process proxy restart. 适用于 Antigravity／反重力登录失败、后台未走代理和代理启动。"
license: MIT
---

# Antigravity login

Restore an authorized login by identifying the failing stage and, when appropriate, restarting Antigravity with a proxy in its **launch environment**. The application and its child processes inherit that environment; this does not exclusively target an already-running backend.

## Identify the stage

| Observation | Next action |
| --- | --- |
| Backend timeout, connection failure or EOF; browser works | Inspect the actual proxy and backend connections. A system proxy can work for Chromium while a backend needs explicit environment variables. |
| `Awaiting Authentication...` | Check whether the user has completed the current Google login and callback. Preserve an active login attempt. |
| Browser says authentication succeeded | Check the client separately. OAuth success alone does not prove Antigravity eligibility or a completed login. |
| `account is ineligible` / `not currently available in your location` | Read [account eligibility](references/account-eligibility.md). If the proxy is working, investigate the account's region instead of rotating proxies. |

## Proxy restart on Windows

1. Identify the installed `Antigravity.exe` and the user's intended account. Inspect the current client state before interrupting it. Save unsaved work before closing.
2. Determine the actual local HTTP proxy URL. `http://127.0.0.1:7890` is a configurable default, not a universal port. Different proxy programs can use different ports. A running VPN application or open TCP port alone is insufficient evidence of HTTPS access.
3. Verify the chosen route without using account credentials, for example:

   ```powershell
   curl.exe --silent --show-error --max-time 15 --proxy http://127.0.0.1:7890 https://www.google.com/generate_204 -o NUL -w '%{http_code}'
   ```

   HTTP 204 demonstrates connectivity to that endpoint, not account eligibility. Do not disable TLS verification to make the probe pass.
4. Run the bundled launcher through PowerShell, using the resolved skill directory:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill-directory>\scripts\Start-AntigravityWithProxy.ps1" -ProxyUrl "http://127.0.0.1:7890" -Restart
   ```

   Supply `-AppPath` for another installation. `-Restart` requests normal shutdown of the exact application. If shutdown fails, stop and let the user close it; do not force-kill by name. Starting a second instance can reuse the old environment.
5. The launcher sets `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` for the new process and `NO_PROXY=localhost,127.0.0.1,::1` for local callbacks. It leaves the caller's environment and system settings intact. Its `started_with_proxy` result means only that the application was launched.
6. Let the user select their account and complete passwords/MFA in Google's UI. Inspect the client again. Where available, verify that this launch's backend connections use the selected proxy and the previously failing request recovers.

## Completion and stopping conditions

Report the observed client state, verified proxy route, and any remaining user action. Claim login success only after the client enters its authenticated main interface; only claim the intended account when its identity has been verified.

After one verified restart, a repeated error requires fresh diagnosis rather than repeated restarts. Preserve existing proxy software and rules; enabling TUN, changing global proxy settings, clearing account data and submitting region changes are separate actions, not prerequisites of this technique. Do not export cookies, OAuth URLs, passwords or tokens into logs or shared artifacts. Redact identifying details in diagnostics.

On other platforms, retain the same diagnosis and child-process environment principle; the bundled launcher is Windows-only.
