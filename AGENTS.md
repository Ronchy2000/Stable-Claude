# AGENTS.md

这是一个“AI 执行远程 Claude Workspace”项目。任何 coding agent 在执行服务器操作前，必须先完整阅读本文件和 README.md。

> [!IMPORTANT]
> 任何命令、安装、配置、重启或登录操作之前，都必须先完整阅读 README.md 和本文件。不能只读取 Prompt、摘要或单个脚本后直接执行。

> [!NOTE]
> 如果 README.md、用户当前指令和现场状态出现冲突，以更严格的安全边界为准；需要扩大范围时先暂停并询问用户。

## 项目目标

在已有 Ubuntu ARM64 服务器上增加一个可回滚的工作区：

- 远程 Chromium 访问官方 Claude.ai，使用画面串流；
- code-server 提供浏览器终端，运行服务器上的官方 Claude Code；
- Cloudflare Access + 独立 Cloudflare Tunnel 是唯一公网入口；
- Claude 网页和 Claude Code 不经过 Anthropic API relay、CPA、CLIProxyAPI、New API 或 LibreChat。

## 默认部署模式

默认是 existing-user：

- 使用当前 SSH 登录的非 root 用户运行 Chromium、code-server、项目和 Claude Code；
- 不创建新 Linux 用户，不修改现有用户组，不改变原有服务 owner；
- 工作区运行数据放在 /srv/claude-workspace；
- root 管理的配置和 systemd 文件放在 /opt/claude-workspace、/etc/claude-workspace；
- Chromium 使用独立 Docker bridge network；
- Web 服务只监听 127.0.0.1；
- Tunnel 单元名为 cloudflared-claude-workspace.service；
- Chromium、code-server、Tunnel 使用独立 systemd 单元和资源上限。

只允许新增 /opt/claude-workspace、/srv/claude-workspace、名为 claude-workspace 的 Docker network、名为 claude-workspace-chromium 的容器，以及约定的三个 systemd 单元。不得为了方便使用不带 claude-workspace 标识的全局名称。

只有用户明确要求 dedicated-user 模式时，才创建 claude-ws 等专用账号、分离 HOME、ACL 或 nftables egress guard。多账户模式不是默认路径。

## 绝对安全边界

1. 先运行 scripts/check.sh preflight，再做任何写操作。
2. 在启动工作区前记录现有 Docker 容器、network、监听端口、Caddy/Nginx、systemd、磁盘和内存状态。
3. 不执行全局 docker compose down、docker system prune、ufw reset、nft flush ruleset、iptables flush、系统级大范围升级。
4. 不修改旧服务的 compose、volume、network、端口、Caddy/Nginx、sshd、Docker daemon、数据库或 systemd 单元。
5. 不把工作区加入 host network、旧业务 network 或 Docker socket。
6. 不绑定 0.0.0.0 或公网端口。默认 3010/8080；端口冲突时选择未占用的回环端口并报告。
7. 不使用 latest 镜像。Chromium 必须使用官方 ARM64 镜像的固定 tag + digest；code-server、cloudflared 和 Claude Code 使用官方 ARM64 发布物并记录版本/校验和。
8. 生产配置、密码、Tunnel credentials、浏览器 Profile、OAuth 状态、Cookie、API Key 和日志必须在仓库外、最小权限保存。
9. 不在命令输出、截图、聊天、Issue、Git 或 CI 日志中显示秘密。需要密码或 OAuth 时，让用户在自己的终端/浏览器完成。
10. 不把本地机场、代理变量、ANTHROPIC_BASE_URL 或第三方 relay 配到服务器的 Claude Code。
11. 不复制其他设备的 Claude Profile、Cookie、~/.claude、~/.claude.json 或 OAuth Token。
12. 不为健康检查发送真实模型请求；使用本地 health、systemd、Tunnel ready 和监听检查。

## 必须停止并报告的情况

- 当前 SSH 用户是 root，且没有用户指定的非 root 运行账号；
- 3010/8080 和候选备用端口都被占用；
- 发现已有同名工作区目录、容器、network、systemd 或 Tunnel 的来源不明；
- 旧服务在部署前后状态、启动时间、重启计数、端口、网络或配置发生变化；
- 发现现有防火墙规则无法安全增量添加工作区规则；
- 需要删除数据、volume、Profile、OAuth、Tunnel credentials 或修改旧服务；
- 需要把生产密钥粘贴给 agent；
- Cloudflare Access、Tunnel 授权、官方 Claude 登录需要人工确认；
- 资源停止线不足，或部署会触发无关的 apt 大范围升级。

停止时给出证据和下一步选项，不要猜测修复，也不要为了继续而绕过检查。

## 推荐执行顺序

1. 只读预检：执行 scripts/check.sh preflight。
2. 生成旧服务基线和可恢复备份；备份中不输出秘密正文。
3. 确认非 root 运行账号、可用端口和磁盘预算。
4. 在仓库外生成 compose、code-server 和 systemd 配置；先做 config/语法检查。
5. 创建独立 bridge、Chromium 和 code-server；确认回环监听和旧服务零漂移。
6. 在 Cloudflare 控制台创建两个默认拒绝、邮箱/身份组 + MFA 的 Access 应用。
7. 创建独立 locally-managed Tunnel，仅路由到工作区回环端口；不用 Caddy，不创建源站 A/AAAA。
8. 让用户完成远程 Chromium 的官方网页登录和远程 Claude Code OAuth。
9. 用 scripts/check.sh verify、服务状态、端口、network、Tunnel ready 和旧服务基线做最终验收。
10. 输出访问地址占位符、实际端口、服务状态、备份位置和回滚命令；不输出秘密。

## 服务实现要求

- Chromium 仅挂载 /srv/claude-workspace/browser；关闭分享、协作、文件传输、远程命令、麦克风等不需要的功能。
- code-server 只打开 /srv/claude-workspace/projects，使用密码认证、disable telemetry、回环监听和 tmux。
- Claude Code 运行时清除 ANTHROPIC_API_KEY、ANTHROPIC_BASE_URL、ANTHROPIC_AUTH_TOKEN、CLAUDE_CODE_OAUTH_TOKEN、HTTP_PROXY、HTTPS_PROXY、ALL_PROXY 等环境变量。
- Tunnel 使用 credentials-file，不把长期 Token 放在 ExecStart 或 shell history。
- systemd 停止/回滚工作区时只能操作名称以 claude-workspace 或 code-server-claude-workspace、cloudflared-claude-workspace 开头的单元。
- 如果需要宿主机 egress 限制，必须先说明规则会影响哪些 UID/bridge，并只创建独立表；绝不 flush 现有防火墙。

## dedicated-user 模式

只有用户明确要求时才启用：

- 创建无 sudo、docker、lxd、adm 或业务附加组的 claude-ws；
- 登录 HOME 与运行 HOME 分离，阻断 SSH key 写入；
- 只对旧服务父目录做 named-user ACL，先演练再应用；
- 只为工作区添加按 UID/bridge 的出站限制；
- 不递归修改旧服务 owner/mode，不让旧业务依赖工作区守卫；
- 每一步都提供单独回滚和反向验证。

## 代码仓库纪律

- 仓库中只放公开说明、检查脚本和不含生产值的示例。
- 不新增真实域名、IP、邮箱、Tunnel UUID、SSH 路径、生产 digest、备份路径或账号标识。
- 使用 apply_patch 编辑文件；脚本必须通过 bash -n。
- 修改后运行 git diff --check，并扫描工作树和 Git 历史。
- 不自动 commit、push、修改 GitHub 可见性或创建发布，除非用户明确要求。
