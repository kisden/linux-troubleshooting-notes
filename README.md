# Linux 系统与网络故障排查实训笔记
> 基于 Ubuntu 22.04 QEMU 隔离虚拟机完成实操复现，记录各类运维故障的现象、排查思路、根因分析、踩坑复盘与可复用脚本。
> 核心排障理念：**先量化，再动手；拒绝盲目试错式排错**。磁盘类故障优先用 `df -h` + `df -i` 双命令定性，服务类故障固定走「status → journalctl → 手工验证」三步法。

## 📚 项目进度
| 分册 | 主题 | 状态 |
|---|---|---|
| 分册一 | 磁盘与文件系统类故障 | ✅ 已完成 |
| 分册二 | systemd 服务与端口排障 | ✅ 已完成 |
| 分册三 | 权限与认证排障 | 🚧 待完成 |
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

## 📂 仓库目录结构
linux-troubleshooting-notes
├── README.md                 # 项目总览（本文件）
├── handbook/                 # 各分册学习笔记
├── scripts/                  # 可复用排障、巡检脚本
│   ├── baseline-check.sh     # 系统基线采集比对脚本（分册一）
│   ├── service-triage.sh     # 服务三步法一键采集（分册二）
│   ├── port-owner-trace.sh   # 端口占用四步溯源（分册二）
│   ├── nginx-safe-reload.sh  # 校验通过才 reload，失败自动回滚（分册二）
│   └── unit-audit.sh         # systemd unit 静态体检（分册二）
└── images/                   # 实验关键截图证据


## 🛠 实验环境
- 虚拟化平台：QEMU，qcow2 镜像，支持快照与回滚
- 操作系统：Ubuntu 22.04.5 LTS
- 根磁盘：22G LVM 分区
- 网络：仅主机隔离环境，NAT 网卡用于软件包安装

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

## 📜 脚本说明

### 分册一
- [`baseline-check.sh`](./scripts/baseline-check.sh)：基线巡检脚本，输出磁盘、inode、已删除句柄、日志目录占用，快速发现系统指标漂移。

### 分册二
- [`service-triage.sh`](./scripts/service-triage.sh)：服务三步法一键采集，按 `Process:` 行条数自动给出「配置错 / 资源错」的初步结论。
- [`port-owner-trace.sh`](./scripts/port-owner-trace.sh)：端口占用四步溯源，一次输出进程名、运行用户、启动时间、真实二进制，并用 `ss`/`lsof`/`fuser` 三方交叉验证。
- [`nginx-safe-reload.sh`](./scripts/nginx-safe-reload.sh)：变更封装，`nginx -t` 失败即中止且线上配置不动；reload 后强制 HTTP 健康检查，失败自动回滚到备份。
- [`unit-audit.sh`](./scripts/unit-audit.sh)：systemd unit 静态体检，逐项验证 `User`/`ExecStart`/`WorkingDirectory`/`Type`/`Restart`，提前命中 `217/USER`、`203/EXEC`、`200/CHDIR`。

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
```
