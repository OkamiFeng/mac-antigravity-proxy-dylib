# Antigravity-Proxy for macOS

<p align="center">
  <img src="icon.png" width="160" alt="Antigravity-Proxy icon">
</p>

专为 macOS 上的 Antigravity 准备：在不打开 Clash TUN 的情况下，让 Antigravity 尽量走本机代理。

本项目整体思路参考 Windows 项目 [yuaotian/antigravity-proxy](https://github.com/yuaotian/antigravity-proxy)：通过注入组件拦截网络连接，让 Antigravity 相关流量透明转发到本机代理。区别是 Windows 版使用 DLL 注入，macOS 版使用 `DYLD_INSERT_LIBRARIES` 注入 dylib。

---

## 目录 / Table of Contents

- [项目介绍 / Introduction](#项目介绍--introduction)
- [快速开始 / Quick Start](#快速开始--quick-start)
- [自定义图标 / Custom Icon](#自定义图标--custom-icon)
- [更新 Antigravity / Update](#更新-antigravity--update)
- [停止后台进程 / Stop](#停止后台进程--stop)
- [工作原理 / How It Works](#工作原理--how-it-works)
- [本地构建 / Build](#本地构建--build)
- [本地测试 / Test](#本地测试--test)
- [故障排查 / Troubleshooting](#故障排查--troubleshooting)
- [限制 / Limitations](#限制--limitations)
- [许可证 / License](#许可证--license)

---

## 项目介绍 / Introduction

Release 里发布的是一个很小的 `Antigravity-Proxy.app` Builder App。它**不包含** Google 原版 `Antigravity.app`。

运行时它会在用户本机做这些事：

1. 检查代理端口是否可连接。
2. 从 `/Applications/Antigravity.app` 复制一份原版 Antigravity。
3. 在 `~/Library/Application Support/Antigravity Proxy/Runtime/` 里生成 runtime 代理版。
4. 注入代理 dylib、写入代理环境变量、替换图标、重签名。
5. 启动生成出来的代理版 Antigravity。

原版 `/Applications/Antigravity.app` 不会被修改。

适用场景：

- Antigravity 不读取 macOS system proxy。
- Clash Verge 开启 system proxy 后，Antigravity 仍然无法登录或无法连接。
- 不想长期打开 TUN，只想让 Antigravity 走本机代理。

如果你已经使用 Clash TUN、Surge 增强模式、Proxifier 或其他全局/按进程代理方案，并且 Antigravity 工作正常，就不需要这个工具。

---

## 快速开始 / Quick Start

### Step 1: 安装原版 Antigravity

请先确认原版 Antigravity 已安装在：

```text
/Applications/Antigravity.app
```

### Step 2: 下载 Antigravity-Proxy.app

到本仓库 [Releases](https://github.com/OkamiFeng/mac-antigravity-proxy-dylib/releases) 下载 `Antigravity-Proxy.app` 或 DMG。

这个 App 是 Builder App，不内置 Google Antigravity，所以体积很小。

### Step 3: 第一次打开并配置端口

第一次双击 `Antigravity-Proxy.app` 会显示端口配置界面。

#### 情况 A：你的 Clash 端口是 7890

如果你使用 Clash Verge 默认 mixed port `7890`：

- Host：`127.0.0.1`
- SOCKS5 端口：`7890`
- 环境变量协议：`http`
- 环境变量端口：`7890`

直接保存并启动即可。

#### 情况 B：你的 Clash 端口不是 7890

如果你使用的是其他 mixed port，例如 `7893`：

- Host：`127.0.0.1`
- SOCKS5 端口：`7893`
- 环境变量协议：`http`
- 环境变量端口：`7893`

如果你使用的是独立 SOCKS5 端口，例如 `7891`：

- Host：`127.0.0.1`
- SOCKS5 端口：`7891`
- 环境变量协议：`socks5`
- 环境变量端口：`7891`

### Step 4: 以后直接双击

配置保存后，以后直接双击 `Antigravity-Proxy.app`。

每次启动时它会：

- 检查配置的代理端口是否可连接。
- 如果端口可用，自动从本机原版 Antigravity 生成 runtime 代理版并启动。
- 如果端口不可用，重新显示配置界面。

你也可以把 `Antigravity-Proxy.app` 放到 `/Applications` 里使用。

---

## 自定义图标 / Custom Icon

仓库里的 `icon.png` 是 Builder App 和生成出来的 runtime 代理版使用的图标。

如果你想换成自己的图标：

1. 用新的 PNG 图片替换仓库根目录的 `icon.png`。
2. 重新构建：

```bash
./build.sh
```

脚本会自动把 `icon.png` 转成 `.icns`，并写入 Builder App。运行时 Builder App 还会把同一个图标写入 runtime 代理版、内层 Antigravity 副本、Electron Helper 和内层 `app.asar`。

如果 macOS 仍显示旧图标，可能是图标缓存，可以退出 Antigravity 后运行：

```bash
killall Dock
```

---

## 更新 Antigravity / Update

Antigravity 更新后，不需要重新下载 Builder App。

推荐流程：

1. 先用原版 `/Applications/Antigravity.app` 完成更新。
2. 退出 Antigravity。
3. 再双击 `Antigravity-Proxy.app`。

Builder App 会从本机已更新的原版 Antigravity 重新生成 runtime 代理版。

---

## 停止后台进程 / Stop

正常关闭 Antigravity 窗口后，runtime launcher 会自动退出后台进程。

如果遇到残留进程，可以在源码目录运行：

```bash
./stop-antigravity-proxy.sh
```

如果你只使用 Release 下载的 Builder App，通常从菜单栏退出 Antigravity 即可。

---

## 工作原理 / How It Works

Builder App 自身只包含：

- `AntigravityProxyBuilder`：SwiftUI 配置界面和 runtime 生成器。
- `AntigravityProxyLauncher`：runtime 代理版的入口。
- `libantigravity_proxy.dylib`：网络 hook 动态库。
- `icon.png` / `.icns`：代理版图标。

运行时生成的 runtime 代理版位于：

```text
~/Library/Application Support/Antigravity Proxy/Runtime/Antigravity-Proxy.app
```

runtime 生成步骤：

- 从 `/Applications/Antigravity.app` 复制一份 Antigravity。
- 放入 `libantigravity_proxy.dylib`。
- 放入 `AntigravityProxyLauncher` 作为 runtime App 的入口。
- 对内层 Antigravity 副本做 ad-hoc 重签名，添加允许 `DYLD_INSERT_LIBRARIES` 的 entitlement。
- 写入 `proxy.env`，启动时自动设置代理环境变量。
- 替换外层、内层和 Electron Helper 的图标。
- Patch 内层 `app.asar` 里的根目录 `icon.png`，避免 Dock 图标加载后切回原版图标。

注入库主要拦截：

- `getaddrinfo()`：给域名分配 `198.18.0.0/15` 范围内的 FakeIP，并保存 FakeIP 到域名的映射。
- `connect()`：遇到 FakeIP 时连接本机 SOCKS5 代理，并用 SOCKS5 domain CONNECT 请求原始域名；其他 TCP 目标按 IP CONNECT 转发。

`language_server` 这类 Go 子进程可能不走 libc hook，所以 launcher 同时设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 等环境变量。

### 为什么不直接注入原版 App

macOS 上的 Antigravity 原版 App 开启了 hardened runtime，并且没有允许动态库注入所需的 entitlement。直接对 `/Applications/Antigravity.app` 使用 `DYLD_INSERT_LIBRARIES` 通常会被系统拦截。

所以本项目不修改原版 App，而是在用户本机生成一份 runtime 代理版。

---

## 本地构建 / Build

需要 Xcode Command Line Tools：

```bash
xcode-select --install
```

构建：

```bash
./build.sh
```

产物：

```text
build/Antigravity-Proxy.app
build/libantigravity_proxy.dylib
build/AntigravityProxyLauncher
build/test_client
```

`build/Antigravity-Proxy.app` 是可发布的小型 Builder App，不包含原版 Antigravity。

源码里仍保留 `prepare-app-copy.sh`，它用于开发/调试时手动生成完整 runtime 副本；普通用户不需要运行它。

---

## 本地测试 / Test

这个测试不依赖 Antigravity，只验证 FakeIP 和 SOCKS5 CONNECT 是否工作：

```bash
./build.sh
./tests/socks5_capture.py 18081
```

另开一个终端：

```bash
AG_PROXY=socks5://127.0.0.1:18081 \
AG_PROXY_LOG=1 \
DYLD_INSERT_LIBRARIES="$PWD/build/libantigravity_proxy.dylib" \
./build/test_client login.example.test 443
```

成功时，SOCKS5 测试服务会输出：

```text
captured login.example.test:443
```

---

## 故障排查 / Troubleshooting

### 打开后显示端口配置界面

说明 Builder App 没有连上配置的代理端口。请确认：

- Clash Verge 或其他代理软件正在运行。
- 端口配置和 Clash 设置一致。
- 如果是 Clash Verge 默认 mixed port，通常填写 `127.0.0.1:7890`，环境变量协议用 `http`。

### GUI 仍显示需要登录

先看 Clash 日志中这些域名是否走代理：

- `accounts.google.com`
- `oauth2.googleapis.com`
- `www.googleapis.com`
- `daily-cloudcode-pa.googleapis.com`
- `generativelanguage.googleapis.com`

如果看到 `language_server` 仍然直连，可以查看：

```bash
tail -n 120 ~/Library/Logs/Antigravity/language_server.log
```

如果日志里出现 `dial tcp ... i/o timeout`，通常说明 Go 子进程没有拿到代理环境变量。重新打开 Builder App，把环境变量协议和端口改成 Clash mixed port 对应的 HTTP 代理，例如 `http://127.0.0.1:7890`。

### 原版 Antigravity 打不开

不要同时运行原版和代理版。Antigravity / Electron 可能会使用同一个用户数据目录和单实例锁；如果代理版已经在运行，双击原版可能只是激活现有进程。

处理方式：

1. 完全退出 Antigravity。
2. 如果要用 TUN，打开原版 `/Applications/Antigravity.app`。
3. 如果不用 TUN，打开 `Antigravity-Proxy.app`。

---

## 限制 / Limitations

- 只处理 TCP `connect()`，不处理 UDP/QUIC。
- dylib hook 目前只支持 SOCKS5 代理。
- 代理地址建议使用数字 IP，例如 `127.0.0.1`。
- 如果 Antigravity 使用 Network.framework、内置 DNS、DoH 或不经过 libc socket API 的路径，可能绕过 hook。
- 首次启动需要复制完整 Antigravity，可能需要等待一段时间。
- Builder App 目前是 ad-hoc signed；公开分发时建议进一步做 Developer ID 签名和 notarization。

---

## 许可证 / License

MIT License。详见 [LICENSE](LICENSE)。
