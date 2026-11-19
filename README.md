# Linux 系统与网络故障排查实训笔记
> 基于 Ubuntu 22.04 QEMU 隔离虚拟机与 Ubuntu 24.04 VMware 虚拟机两套环境完成实操复现，记录各类运维故障的现象、排查思路、根因分析、踩坑复盘与可复用脚本。
> 核心排障理念：**先量化，再动手；拒绝盲目试错式排错**。磁盘类故障优先用 `df -h` + `df -i` 双命令定性；服务类故障固定走「status → journalctl → 手工验证」三步法；「连不上」类故障先用客户端现象（`refused` / `timeout` / `denied`）分层，再回服务端取证据定因。

## 📚 项目进度
| 分册 | 主题 | 状态 |
|---|---|---|
| 分册一 | 磁盘与文件系统类故障 | ✅ 已完成 |
| 分册二 | systemd 服务与端口排障 | ✅ 已完成 |
| 分册三 | 权限与认证排障 | ✅ 已完成 |
| 分册四 | 网络分层故障排查 | 🚧 待完成 |

### 分册一覆盖故障
1. 磁盘容量耗尽
2. 日志暴涨占用磁盘
3. inode 资源耗尽（磁盘有空间但无法新建文件）
4. 文件删除后进程持有句柄，空间不释放（df 与 du 统计不一致）

[👉 阅读分册一：磁盘与文件系统排障笔记](./handbook/01-磁盘与文件系统排障.md)

### 分册二覆盖故障
1. nginx 配置语法错导致服务起不来（`ExecStartPre` 阶段失败）
2. 端口被占用导致服务起不来（`EADDRINUSE`，语法校验却能通过）
3. 端口占用溯源（从端口反查进程、用户、启动时间、真实二进制）
4. 自建 unit 验证 unit 层的字段陷阱

[👉 阅读分册二：systemd 服务与端口排障笔记](./handbook/02-systemd服务与端口排障.md)

### 分册三覆盖故障
1. 网站根目录权限收紧导致 403（断在目录的 `x` 位，不是文件）
2. SSH 连不上之一：`stop ssh` 之后 22 端口仍在（`ssh.socket` 持有监听套接字）
3. SSH 连不上之二：改了 `Port` 却不生效（systemd 抢在 sshd 前面接连接）
4. SSH 连不上之三：防火墙 `DROP` 导致 `timeout`（与 `refused` 的方向完全相反）
5. SSH 连不上之四：`AllowUsers` 认证策略，以及「为什么没复现出 denied」
6. 改 SSH 配置前的保险绳：控制台 + `at` 定时回滚 + 第二会话的可靠性排序

[👉 阅读分册三：权限与认证排障笔记](./handbook/03-权限与认证排障.md)

## 📂 仓库目录结构
linux-troubleshooting-notes
├── README.md                 # 项目总览（本文件）
├── handbook/                 # 各分册学习笔记
├── scripts/                  # 可复用排障、巡检脚本
│   ├── baseline-check.sh       # 系统基线采集比对脚本（分册一）
│   ├── service-triage.sh       # 服务三步法一键采集（分册二）
│   ├── port-owner-trace.sh     # 端口占用四步溯源（分册二）
│   ├── nginx-safe-reload.sh    # 校验通过才 reload，失败自动回滚（分册二）
│   ├── unit-audit.sh           # systemd unit 静态体检（分册二）
│   ├── perm-denied-triage.sh   # Permission denied 六因一次性排查（分册三）
│   ├── web-403-fix.sh          # 网站 403 定向修复，全程禁用 777（分册三）
│   ├── ssh-triage.sh           # SSH 连不上分层判定（分册三）
│   ├── ssh-change-lifeline.sh  # 改 SSH 前的保险绳与自动回滚（分册三）
│   └── ssh-socket-mode.sh      # socket 激活 / 常驻模式切换（分册三）
└── images/                   # 实验关键截图证据


## 🛠 实验环境
- 分册一、二：QEMU，qcow2 镜像，Ubuntu 22.04.5 LTS，根磁盘 22G LVM，仅主机隔离网络
- 分册三：VMware Workstation 17.6.3（VMnet8 NAT），Ubuntu 24.04.4 LTS，nginx 1.24.0 + OpenSSH 9.6p1，主机名 ubuntu24
- 分册三多一项前置条件：支持剪贴板的图形控制台。四种 SSH 造法都会切断当前连接，必须在能直接操作虚拟机的窗口里注入。

## 💡 核心方法论

### 磁盘故障
1. **第一步同时执行 `df -h /` 与 `df -i /`**，区分是磁盘块耗尽还是 inode 耗尽。
2. 排障五步法：观察量化输出 → 提出假设 → 命令验证证伪 → 定位根因 → 落地监控预防。
3. 正在写入的日志文件清理：使用 `truncate -s 0`，禁止直接 rm，避免句柄泄漏。
4. 大批量文件删除：禁止直接通配符 `rm file_*`，优先使用 `find ... -delete`，规避参数列表过长报错。
5. df 空间占用异常不变时，使用 `sudo lsof +L1` 检查已删除仍被进程打开的文件。

### 服务与端口故障
1. **服务三步法，顺序不可交换**：`systemctl status` 给分类（起没起来）→ `journalctl` 给位置（哪个文件哪一行）→ 手工验证给归因（配置/端口/权限）。
2. 退出码都是 `1/FAILURE` 时，看 `Process:` 行的**条数**：1 条说明挂在 `ExecStartPre`（配置错），2 条说明主程序已执行后失败（端口/权限）。
3. **`nginx -t` 通过只是划掉了「语法」这一整类**，不代表服务能起——端口能否绑定、运行用户能否读文件、证书是否配对，它一律不查。
4. 认 errno 数字不认文字：`98` 永远是 `EADDRINUSE`，即使 nginx 把它显示成 `Unknown error`。
5. `reload` 依赖 master 进程存活；服务已是 `failed` 时必须 `restart`，否则没有对象可发 HUP。
6. 端口结论必须带齐四要素：进程名、运行用户、启动时间、`/proc/<PID>/exe`（内核维护，可识破改名伪装）。
7. 收工判据是 `curl -I` 返回 200，不是「障碍已清除」。

### 权限与认证故障
1. **客户端现象只说明卡在哪一层，不说明为什么**：`refused`（立即返回）= 端口无人监听 → 查服务；`timeout`（卡十几秒）= 包被静默丢弃 → 查网络；`Permission denied` = 认证策略 → 查 `sshd -T`。
2. **端口状态查 `ss`，不查 `systemctl status`**：`status` 描述 unit 状态，`ss` 描述监听事实，两者可以完全不一致。
3. **看 `users` 字段与 backlog，不看进程名**：`("systemd",pid=1)` + backlog 4096 = socket 激活；`("sshd",pid=N)` + backlog 128 = 常驻。此时 `stop ssh` 关不掉端口，`Port` 改了也不生效。
4. **403 先复现身份，不先改权限**：`sudo -u www-data cat <file>` 一条命令定生死，能读就转查 ACL/AppArmor，不能读就是 DAC 问题。`chmod 777` 只掩盖问题。
5. **`namei -l` 从上往下读，停在第一个缺位层级**：末行写着「文件权限不够」时，问题往往在上一级目录。
6. **`EACCES` 有六种来源，只有两种体现在 `ls -l` 上**：目录 `x` 位、属主、ACL、`chattr` 属性、AppArmor、挂载选项。
7. **报错文本指向哪里就查哪里**：`Missing privilege separation directory: /run/sshd` 与 `sshd_config` 无关，别被「刚改过配置」的时序带偏。
8. **删规则按内容删，不按序号删**：`iptables -D INPUT 1` 不幂等，第二次执行必报 `Index of deletion too big`。
9. **改 SSH 之前，保险绳要验证过再依赖**：控制台 > `at` 定时回滚 > 第二会话，可靠性就是这个顺序；`atq` 里有任务不等于它会执行。

## 📜 脚本说明

### 分册一
- [`baseline-check.sh`](./scripts/baseline-check.sh)：基线巡检脚本，输出磁盘、inode、已删除句柄、日志目录占用，快速发现系统指标漂移。

### 分册二
- [`service-triage.sh`](./scripts/service-triage.sh)：服务三步法一键采集，按 `Process:` 行条数自动给出「配置错 / 资源错」的初步结论。
- [`port-owner-trace.sh`](./scripts/port-owner-trace.sh)：端口占用四步溯源，一次输出进程名、运行用户、启动时间、真实二进制，并用 `ss`/`lsof`/`fuser` 三方交叉验证。
- [`nginx-safe-reload.sh`](./scripts/nginx-safe-reload.sh)：变更封装，`nginx -t` 失败即中止且线上配置不动；reload 后强制 HTTP 健康检查，失败自动回滚到备份。
- [`unit-audit.sh`](./scripts/unit-audit.sh)：systemd unit 静态体检，逐项验证 `User`/`ExecStart`/`WorkingDirectory`/`Type`/`Restart`，提前命中 `217/USER`、`203/EXEC`、`200/CHDIR`。

### 分册三
- [`perm-denied-triage.sh`](./scripts/perm-denied-triage.sh)：`Permission denied` 六因一次性排查，按命中概率输出目录 `x` 位、属主、ACL、`chattr` 属性、AppArmor、挂载选项，第一个 `[HIT]` 即根因。
- [`web-403-fix.sh`](./scripts/web-403-fix.sh)：网站 403 定向修复，先用服务身份复现、再用 `namei` 定位断点层级，只补回该有的位，验证非 200 自动回滚，全程不出现 `777`。
- [`ssh-triage.sh`](./scripts/ssh-triage.sh)：SSH 连不上分层判定，按 `refused`/`timeout`/`denied` 三选一路由到对应证据链（监听者身份、防火墙计数、认证策略）。
- [`ssh-change-lifeline.sh`](./scripts/ssh-change-lifeline.sh)：改 `sshd_config` 的保险绳，备份 → 语法闸门 → `at` 定时回滚 → 重启 → 验监听，失败自动回滚。
- [`ssh-socket-mode.sh`](./scripts/ssh-socket-mode.sh)：在 socket 激活与常驻模式之间切换，含 `/run/sshd` 补建与切换后验证；改 `Port` 前必须先切常驻。

使用方式（统一以仓库根目录为工作目录）：
```bash
# 赋予执行权限
chmod +x scripts/*.sh

# 分册一：基线巡检
./scripts/baseline-check.sh

# 分册二：服务三步法采集（以 nginx 为例）
sudo ./scripts/service-triage.sh nginx

# 分册二：端口占用溯源
sudo ./scripts/port-owner-trace.sh 80

# 分册二：unit 静态体检
sudo ./scripts/unit-audit.sh nginx

# 分册二：安全变更（校验通过才 reload，失败自动回滚）
sudo ./scripts/nginx-safe-reload.sh /etc/nginx/nginx.conf http://127.0.0.1/

# 分册三：403 六因排查（第二个参数传服务运行身份）
sudo ./scripts/perm-denied-triage.sh /var/www/html/index.html www-data

# 分册三：网站 403 定向修复
sudo ./scripts/web-403-fix.sh /var/www/html http://127.0.0.1/

# 分册三：SSH 连不上分层判定（先按客户端现象选分支）
sudo ./scripts/ssh-triage.sh refused
sudo ./scripts/ssh-triage.sh timeout

# 分册三：改 SSH 配置前的保险绳
sudo ./scripts/ssh-change-lifeline.sh check
sudo ./scripts/ssh-change-lifeline.sh apply

# 分册三：切常驻模式后 Port 才生效
sudo ./scripts/ssh-socket-mode.sh status
sudo ./scripts/ssh-socket-mode.sh standalone
```
