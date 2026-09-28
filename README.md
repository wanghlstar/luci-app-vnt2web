# luci-app-vnt2web

OpenWrt LuCI 界面，用于管理 [VNT2](https://github.com/vnt-dev/vnt) 的 `vnt2_web` 客户端。采用经典 LuCI CBI（Lua）风格，与系统原生界面一致。

- 上游项目：[weicaixian86/luci-app-vnt2](https://github.com/weicaixian86/luci-app-vnt2)（本 fork 在其基础上修复了大量安全与功能问题）
- 界面风格参考：[lmq8267/luci-app-vnt](https://github.com/lmq8267/luci-app-vnt)
- VNT 官网：[rustvnt.com](https://rustvnt.com/)

## 功能特性

- **vnt2_web 客户端管理**：启用/停用、快速重启、监听地址与端口、WAN 访问控制、日志级别
- **配置生成**：从 UCI 自动导出运行时 TOML（`/etc/config/vnt2.toml`），无需手写配置文件
- **程序自动下载**：缺二进制时自动从多镜像（gh-proxy / GitHub / Gitee / GitLab / Cloudflare R2 / 自定义）下载匹配架构的发行包，支持指定版本号，失败自动回退到已上传的程序
- **后台上传**：网页上传 `vnt2_web` 二进制或 `.tar.gz` / `.tar.xz` 压缩包，由后台 worker 校验（ELF 魔数、架构比对、解压路径安全）后原子安装到 `/usr/bin/`
- **版本检查**：后台定时查询上游最新 Release，状态页显示本地/最新版本
- **日志查看**：Web 运行日志、下载/安装日志，支持自动刷新与清除
- **网络与防火墙自动化**：自动创建 VNT2 网络区域、转发规则、IP 转发开关、Web 端口放行
- **四个后台 worker**：重启队列、上传处理、版本检查、缺程序下载，全部防抖合并 + 失败重试，不阻塞 LuCI 与开机流程

## 界面与菜单

安装后位于 **VPN → VNT2**，包含三个页面：

| 页面 | 说明 |
|------|------|
| 基本设置 | 运行状态（版本/时长/PID/CPU/内存/监听地址/访问地址/下载状态）、启用开关、快速重启、监听配置、WAN 访问、上传程序 |
| Web 日志 | `/tmp/vnt2-web.log` 实时查看（5 秒轮询、自动刷新、清除） |
| 下载日志 | `/tmp/vnt2-download.log` 下载与安装记录 |

基本设置内部分为三个页签：**基本设置** / **高级设置**（镜像源、下载版本、仓库、程序路径、备注账号密码、启动参数）/ **上传程序**。

## 安装

### 方式一：Release 安装（推荐）

到 [Releases](https://github.com/wanghlstar/luci-app-vnt2web/releases) 下载对应包：

```bash
# OpenWrt 24.10 及更早（opkg）
opkg install luci-app-vnt2web_<版本>_all.ipk

# OpenWrt 25.12（apk）
apk add --allow-untrusted luci-app-vnt2web-<版本>.apk
```

### 方式二：直接拷贝文件（快速体验）

```bash
# 在路由器上执行（假设源码已解压到 /tmp/luci-app-vnt2）
cp -a /tmp/luci-app-vnt2/luci-app-vnt2web/luasrc/controller/vnt2.lua /usr/lib/lua/luci/controller/
cp -a /tmp/luci-app-vnt2/luci-app-vnt2web/luasrc/model/cbi/*.lua     /usr/lib/lua/luci/model/cbi/
cp -a /tmp/luci-app-vnt2/luci-app-vnt2web/luasrc/model/vnt2_*.lua   /usr/lib/lua/luci/model/
cp -a /tmp/luci-app-vnt2/luci-app-vnt2web/luasrc/view/vnt2          /usr/lib/lua/luci/view/
cp -a /tmp/luci-app-vnt2/luci-app-vnt2web/root/etc/*  /etc/
cp -a /tmp/luci-app-vnt2/luci-app-vnt2web/root/usr/libexec/vnt2 /usr/libexec/
chmod +x /etc/init.d/vnt2* /usr/libexec/vnt2/*
rm -rf /tmp/luci-*    # 清 LuCI 缓存
```

### 方式三：SDK 编译

```bash
# 下载对应架构的 OpenWrt SDK 后
cp -a luci-app-vnt2web package/
make defconfig
make package/luci-app-vnt2web/compile V=s -j$(nproc)
# 产物在 bin/packages/<arch>/luci/ 下
```

## 配置说明

### UCI 选项（`/etc/config/vnt2`，section `vnt2_web`）

| 选项 | 默认 | 说明 |
|------|------|------|
| `enabled` | `0` | 启用 vnt2_web |
| `vnt2_web_bin` | `/usr/bin/vnt2_web` | 程序路径 |
| `web_host` | `0.0.0.0` | Web 监听地址 |
| `web_port` | `19099` | Web 监听端口（1-65535） |
| `web_wan` | `0` | 是否放行 WAN 访问 Web 面板 |
| `web_user` / `web_pass` | `admin` / 空 | 备注用（原生 vnt2_web 未接管认证） |
| `log_level` | `info` | 日志级别（error/warn/info/debug/trace） |
| `auto_download` | `1` | 缺程序时自动下载 |
| `download_mirror` | `auto` | 镜像源：auto/gh-proxy/github/gitee/gitlab/cloudflare/custom |
| `custom_download_mirror` | 空 | 自定义镜像前缀（选择 custom 时生效） |
| `download_tag` | `latest` | 下载版本，`latest` 或指定 Release 标签 |
| `download_repo` | `vnt-dev/vnt` | 下载仓库 |

### 文件路径

| 路径 | 用途 |
|------|------|
| `/etc/config/vnt2` | UCI 配置 |
| `/etc/config/vnt2.toml` | 运行时 TOML（由 UCI 自动导出，权限 0600） |
| `/etc/vnt_config/` | vnt2_web 数据目录（Web 界面创建的实例配置，原 `/vnt_config` 会自动迁移至此） |
| `/usr/bin/vnt2_web` | 程序安装位置 |
| `/tmp/vnt2-web.log` | Web 运行日志 |
| `/tmp/vnt2-download.log` | 下载/安装日志 |

## 使用流程

1. 进入 **VPN → VNT2 → 基本设置**，勾选**启用**
2. 程序不存在时会自动从镜像源下载（也可在**上传程序**页手动上传）
3. 配置网络参数：编辑 `/etc/config/vnt2` 中 `vnt2_web` 段的 `network_code`、`server`、`device_name` 等键（随 UCI 导出为 TOML），保存并应用
4. 点击**打开 Web 页面**进入 vnt2_web 自带界面（默认 `http://路由器IP:19099/`）创建/管理实例
5. 运行状态、日志分别在状态页和两个日志页查看

## 自动构建（GitHub Actions）

仓库内置 `.github/workflows/build.yml`：

| 触发方式 | 行为 |
|----------|------|
| 推送 `main` 分支 | 构建 x86_64 的 ipk（24.10）+ apk（25.12），上传为 Actions artifacts，不发 Release |
| 推送 `v*` tag | 构建并自动发布 Release（tag 即版本号） |
| 手动触发 | Actions → Build workflow → Run workflow，可指定 tag 与说明 |

CI 仅构建 **x86_64**；其他架构请用方式三在对应 SDK 中编译。

## 运行环境

- OpenWrt **24.10** 或 **25.12**（21.02 及更早不支持）
- 依赖：`luci-base`、`luci-compat`、`kmod-tun`、`curl`、`ca-bundle`、`unzip`
- 架构：CI 提供 x86_64，其他架构需自行编译

## 目录结构

```
luci-app-vnt2web/
├── Makefile                  # 包定义与安装钩子
├── luasrc/
│   ├── controller/vnt2.lua   # 菜单与 JSON 端点（状态/日志/版本检查）
│   ├── model/cbi/            # CBI 配置表单与日志页
│   ├── model/vnt2_toml.lua   # UCI → TOML 导出/读取
│   ├── model/vnt2_text.lua   # 日志读取与乱码修复
│   └── view/vnt2/            # 视图模板（状态页/上传/日志）
└── root/
    ├── etc/config/vnt2       # UCI 默认配置
    ├── etc/init.d/           # 主服务 + 4 个 worker 服务
    └── usr/libexec/vnt2/     # worker 脚本（重启/上传/版本/下载）
tests/                        # 源码校验与各组件测试套件
```

## 常见问题

**Q：页面提示缺少二进制文件？**
A：进入基本设置等待自动下载，或在上传程序页上传；下载日志页可查看失败原因（镜像源可在高级设置切换）。

**Q：Web 界面创建的配置存在哪里？**
A：`/etc/vnt_config/` 目录。旧版曾在根目录 `/vnt_config`，升级时会自动迁移。

**Q：修改了 UCI 但服务没重启？**
A：保存并应用后由后台 worker 在约 15 秒内合并执行重启（连续操作只会重启一次）。

**Q：如何只重启不修改配置？**
A：基本设置页的**重启**按钮可快速重启。

## 致谢

- [vnt-dev/vnt](https://github.com/vnt-dev/vnt) — VNT 本体
- [weicaixian86/luci-app-vnt2](https://github.com/weicaixian86/luci-app-vnt2) — Lua 版上游
- [lmq8267/luci-app-vnt](https://github.com/lmq8267/luci-app-vnt) — 界面风格参考

## 免责声明

本项目为第三方 LuCI 界面，与 VNT 官方无关。自动下载功能会从第三方镜像获取二进制，请自行评估风险。
