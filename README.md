# Linux 系统与网络故障排查实训笔记

> 基于 Ubuntu 22.04 QEMU 隔离虚拟机与 Ubuntu 24.04 VMware 虚拟机两套环境完成实操复现，记录各类运维故障的现象、排查思路、根因分析、踩坑复盘与可复用脚本。
> 核心排障理念：**先量化，再动手；拒绝盲目试错式排错**。磁盘类故障优先用 `df -h` + `df -i` 双命令定性；服务类故障固定走「status → journalctl → 手工验证」三步法；「连不上」类故障先用 `curl -v` 的断点定层（DNS / TCP / TLS / HTTP），再进层内取证；「系统活着但服务消失」类故障先看退出码（137/143），再下到内核日志（`dmesg`）与 `/proc` 取证。
> 分册六另加一层验收：自建故障注入器 + 限时盲盒，不看答案排障，用**首次假设命中率**与**定位层级**衡量能力，而不是「修好了几个」。

## 📚 项目进度

| 分册 | 主题 | 状态 |
|---|---|---|
| 分册一 | 磁盘与文件系统类故障 | ✅ 已完成 |
| 分册二 | systemd 服务与端口排障 | ✅ 已完成 |
| 分册三 | 权限与认证排障 | ✅ 已完成 |
| 分册四 | 网络协议排障（DNS / TCP / TLS / HTTP） | ✅ 已完成 |
| 分册五 | 资源与调度排障（OOM / 时间同步） | ✅ 已完成 |
| 分册六 | 盲盒对抗与复盘（自建注入器 · 6 类题库） | ✅ 已完成 |

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

### 分册四覆盖故障

1. DNS 解析失败（`resolv.conf` 换成静态文件，存根被摘掉）
2. hosts 写错（`dig` 看着正常，应用却打到本机）
3. 防火墙误拦（`DROP` 导致外部 `timeout`，本机却 200）
4. 证书过期（自签 + 时间跳跃，两个错误叠在一起）
5. 附：四层决策树、`dig` 与 `getent` 的路径差异、`ss` 队列语义、`tcpdump` 判据

[👉 阅读分册四：网络协议排障笔记](./handbook/04-网络协议排障.md)

### 分册五覆盖故障
1. 内存耗尽触发 OOM Killer（`cgroup` 限额安全复现，`dmesg` + `anon-rss` 双判据）
2. 系统时间不同步（注入 2516 天漂移 → 观测证书 / 日志 / 同步链三层影响面）
3. 附：`free` 五字段判读、`oom_score` 挑人逻辑、cgroup OOM 与全局 OOM 的证据差异、VSZ 与 RSS、时间三层同步链、`curl -k` 的假阴性

[👉 阅读分册五：资源与调度排障笔记](./handbook/05-资源与调度排障.md)

### 分册六覆盖内容

1. 自建故障注入器 `chaos.sh`：6 类题库（`log_flood` / `port_busy` / `perm_denied` / `ssh_down` / `dns_bad` / `hosts_wrong`），每类带注入自检，自检失败自动回退
2. 第一轮盲盒：`--inject 1` → `log_flood`，五条命令覆盖磁盘 / 端口 / 权限三族，**缺容量族，0 命中**，20 分钟封顶；对答案后 `du -sh` 显示 `syslog` 已 501 MB
3. 第二轮盲盒：`hosts_wrong`，`getent` 返回 `127.0.0.1` 定性，`cat /etc/hosts` 看到末尾追加行，**2 条命令定位**
4. 附：三个训练指标（命中率 / 平均定位耗时 / 定位层级）、注入器自检失效的三种形态、渐变型故障的间隔采样判据、盲盒前后 6 维巡检

[👉 阅读分册六：盲盒对抗与复盘笔记](./handbook/06-盲盒对抗与复盘.md)

## 📂 仓库目录结构

```
linux-troubleshooting-notes
├── README.md                 # 项目总览（本文件）
├── LICENSE                   # MIT 许可协议
├── .gitattributes            # 固定 LF 换行，防止 .sh 在 Linux 报 bad interpreter
├── .gitignore                # 排除编辑器缓存、脚本运行产物与文档原稿
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
│   ├── ssh-socket-mode.sh      # socket 激活 / 常驻模式切换（分册三）
│   ├── net-layer-triage.sh     # 四层逐段探测，定位卡在哪一层（分册四）
│   ├── dns-view-compare.sh     # getent / dig / dig@上游 三视角对照（分册四）
│   ├── tls-cert-check.sh       # 证书有效期体检，按剩余天数分级（分册四）
│   ├── port-reach-triage.sh    # 端口可达性：nc + iptables + tcpdump（分册四）
│   ├── hosts-drift-check.sh    # /etc/hosts 基线与异常条目检查（分册四）
│   ├── oom-evidence-collect.sh # OOM 证据链一键采集（分册五）
│   ├── mem-safe-run.sh         # cgroup 限额运行 + 自动取证（分册五）
│   ├── time-drift-triage.sh    # 时间漂移分层诊断（分册五）
│   ├── time-sync-restore.sh    # 时间同步恢复标准流程（分册五）
│   ├── resource-baseline-check.sh # 内存 + 时间双维度巡检（分册五）
│   ├── chaos.sh                # 盲盒故障注入器，6 类题库 + 自检 + 对称恢复（分册六）
│   ├── blindbox-audit.sh       # 盲盒前后 6 维健康巡检（分册六）
│   └── blindbox-score.sh       # 盲盒记录表 → 四个训练指标（分册六）
└── images/                   # 实验关键截图证据
```

## 🛠 实验环境

- 分册一、二：QEMU，qcow2 镜像，Ubuntu 22.04.5 LTS，根磁盘 22G LVM，仅主机隔离网络
- 分册三：VMware Workstation 17.6.3（VMnet8 NAT），Ubuntu 24.04.4 LTS，nginx 1.24.0 + OpenSSH 9.6p1，主机名 ubuntu24
- 分册三多一项前置条件：支持剪贴板的图形控制台。四种 SSH 造法都会切断当前连接，必须在能直接操作虚拟机的窗口里注入。
- 分册四：QEMU 双机，lab01（Ubuntu 22.04.5，192.168.56.12）+ attacker（Kali，192.168.56.100）。宿主机只转发 22，不转发 80，所以 Web 客户端只能用 attacker。
- 分册五：回到 lab01（Ubuntu 22.04.5，**2048 MB**，swap 1.8 Gi）。做 OOM 实验前必须关掉宿主机上的 Edge / Steam / WPS——虚拟机内存被挤占时 OOM 现象会失真。
- 分册六：回到 ubuntu24（Ubuntu 24.04.4 LTS，VMware 17.6.3，VMnet8 NAT，`192.168.153.128/24`，网卡 `ens33`，DHCP）。**注入必须在 VMware 控制台窗口执行**：`ssh_down` 会切断当前 SSH 会话，命令还没返回连接就断了，连「注入成功没有」都验不了。

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

### 网络协议故障

1. **先定层，再定因**：`curl -v` 的断点就是层的边界（`Could not resolve host` → DNS，`refused`/`timeout` → TCP，`certificate` → TLS，状态码 → HTTP）。四层里任何一层没通，都不要去看上一层的配置。
2. **`refused` 与 `timeout` 是两种物理事实**：前者收到 RST（端口没人听），后者包被静默丢弃（防火墙/路由）。方向相反，不可互换。
3. **本机 200 不等于对外可用**：`127.0.0.1` 走 `lo`，绕过所有外部路径；连通性必须从对端验证。
4. **规则存在 ≠ 规则命中**：防火墙问题只认 `iptables -vnL` 的 `pkts` 增量，不认「我看规则写对了」。
5. **`dig` 默认不是纯 DNS**：Ubuntu 上它问 `127.0.0.53` 存根，存根会合并 `/etc/hosts`；要纯 DNS 答案必须 `dig @<上游>`。
6. **应用行为只信 `getent`**：它走 `nsswitch`，是唯一与应用程序同路径的解析方式；失败时看退出码，输出为空不代表失败。
7. **证书问题先剥变量**：自签与过期会叠加，`--cacert <crt>` 消掉前者才能看见后者；`s_client` + `x509` 是不依赖浏览器的取证组合。
8. **改系统时间是不可逆操作**：`timedatectl set-ntp false` 之后必须恢复并确认 `synchronized: yes`。
9. **`sudo echo ... >> file` 不提权重定向**：`>>` 由当前 shell 执行，改用 `| sudo tee -a`。

### 资源与调度故障
1. **先看退出码，再谈别的**：`137` = 128+9 = `SIGKILL`（OOM 或 `kill -9`，**日志必然为空**）；`143` = 128+15 = `SIGTERM`（`stop` / 关机，应有退出日志）；其他值才轮到查应用日志。
2. **服务「凭空消失」时，唯一的现场在内核**：`sudo dmesg -T | grep -i 'killed process'`。首行有无 `Memory cgroup` 前缀，直接区分 cgroup 限额与整机耗尽。
3. **`available` 是内存的唯一口径**：`free` 会被缓存骗（缓存也算"用过"但随时可回收），`used` 会因进程死亡反而下降。实测注入前后 `free` 都是 1.5Gi，`used` 却从 178Mi 掉到 165Mi。
4. **RSS 是占用，VSZ 是地址空间**：`total-vm` 可以是 `MemoryMax` 的 13 倍而毫不矛盾（Python 一启动就预留 1.9 GB 地址空间，实际 RSS 只有 146 MB）。判「限额生效」看 `anon-rss` 是否贴顶（实测 97.1%）。
5. **cgroup v2 没有独立限额行**：判据不是某行写着 `limit`，而是被杀进程的 `anon-rss` 有没有压着 `MemoryMax`。
6. **限流优于杀进程**：`MemoryHigh`（软限、节流，进程变慢但不死）在前，`MemoryMax`（硬限、直接 OOM）在后，两个一起设。
7. **`MemoryMax` 的本质是限制故障半径**，不是限制用量——超出只杀自己笼子里的进程，`sshd`、`journald`、数据库一概不碰。
8. **验证某变量是根因前，先把它之外的所有变量消掉**：`curl -k` 掩盖全部两个错误（假阴性），裸 `curl` 卡在自签不受信，只有 `--cacert` 让「有效期」成为唯一变量，`not yet valid` 才露出来。
9. **`set-ntp false` 停的不只是开关**：它会把 `chrony.service` 一起停掉，所以随后 `chronyc tracking` 报 `506 Cannot talk to daemon` 不是 chrony 坏了。先 `systemctl is-active` 再解释报错。
10. **时间是每个进程各自读的**：系统时钟改了，已在运行的进程可能还持有旧的时间认知。恢复后要复核 `/var/log/syslog` 的 `mtime` 是否跟随。
11. **时钟回跳后 `journalctl -n` 拿到的是「时间最大」而非「最新写入」**：新日志被标成旧时间会沉到最前。用 `--since/--until` 按时间窗口捞。

### 盲盒对抗与复盘
1. **排障的难点是「方向」，不是「命令」**：命令可以查手册，方向只能从现象里长出来。首轮失手的 `log_flood`，`df`/`du`/`ss` 一条没少敲，缺的是「容量」这一整族假设。
2. **渐变型故障的单次采样永远正常**：它就是从正常值开始涨的。判据必须换成两次采样求差 + `du -sh /var/log/* | sort -h | tail -3` 点名。
3. **注入器没有自检，等于没有题库**：自检失败要自动回退；自检锚点要选「服务视角的事实」（`curl` 的 403 比 `test -r` 稳，`ss` 的监听表比 `systemctl` 返回码稳）。
4. **恢复必须与注入对称**：`do_inject` / `verify_one` / `do_restore` 三段分离，改一段就数一遍分支；少一项，下一轮现象叠加。
5. **读操作与写操作不能共用代码路径**：`--status` 复用注入函数会二次注入（`hosts_wrong` 再追加一行、`log_flood` 再写 500 MB）。
6. **前置条件不满足时宁可不注入**：断网机器上注入 `dns_bad`，自检恒真，制造假阳性。
7. **解释力不等于正确性**：「每分钟备份任务在写盘」能解释任何缓慢增长，但 `crontab -l` 一查，它 22:00 才跑。
8. **指标比形容词可信**：命中率、定位层级、误判次数，三个数字就能说清一轮训练的质量。

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

### 分册四

- [`net-layer-triage.sh`](./scripts/net-layer-triage.sh)：给定 URL 按 DNS → TCP → TLS → HTTP 逐层探测，第一个失败层即结论；传上游 DNS 时自动做「系统解析 vs 纯 DNS」对照。
- [`dns-view-compare.sh`](./scripts/dns-view-compare.sh)：同一域名的三视角并排输出（`getent` / 默认 `dig` / `dig @上游`），三者不一致即说明本地有覆盖，末尾自带判读规则。
- [`tls-cert-check.sh`](./scripts/tls-cert-check.sh)：`s_client` + `x509` 取证书并算剩余天数，退出码分级（0 正常 / 1 临期 / 2 过期或未生效 / 3 取不到），可直接接监控。
- [`port-reach-triage.sh`](./scripts/port-reach-triage.sh)：端口可达性三件套，`nc` 判 `refused`/`timeout`、`iptables` 看计数、`tcpdump` 看有无 SYN-ACK，并给出路由出口。
- [`hosts-drift-check.sh`](./scripts/hosts-drift-check.sh)：`/etc/hosts` 指纹基线比对 + 异常条目识别（公网域名指向回环/内网），对应分册四的 hosts 劫持场景。

### 分册五
- [`oom-evidence-collect.sh`](./scripts/oom-evidence-collect.sh)：OOM 证据链五步采集，自动区分 cgroup OOM 与全局 OOM，并算出 `anon-rss` 占限额比；支持按 PID 查 `oom_score`。
- [`mem-safe-run.sh`](./scripts/mem-safe-run.sh)：把命令关进 `MemoryMax` 笼子里跑，跑完自动对比内存前后值、按起始时间从 `dmesg` 捞本次记录、算 RSS 占限额比；`--scope` 保证 `$?` 拿到真实退出码（含 137）。
- [`time-drift-triage.sh`](./scripts/time-drift-triage.sh)：时间漂移五层诊断（RTC / 系统时钟 / 同步服务 / 时间源 / 偏差量），专治 `506` 误判与「RTC 存 UTC 被当本地时间」。
- [`time-sync-restore.sh`](./scripts/time-sync-restore.sh)：时间恢复的标准流程（交回 NTP → 服务真的起来 → `makestep` 跳变 → 三处验证），含 `--dry-run` 预演与 NTP 不可达时的 `--force-set`。
- [`resource-baseline-check.sh`](./scripts/resource-baseline-check.sh)：内存 + 时间双维度巡检，含 swap、`si/so` 换页、OOM 分类计数、未设限额服务数、时间源数量，支持基线保存与比对，退出码可接监控。

### 分册六

- [`chaos.sh`](./scripts/chaos.sh)：盲盒故障注入器，6 类题库（日志暴涨 / 端口占用 / 权限收紧 / SSH 停止 / 上游 DNS 不可达 / hosts 劫持）。每类带注入自检，验不过自动回退；`--inject` 洗牌不重复抽取，`--status` 只读不二次注入，`--restore` 与注入严格对称。
- [`blindbox-audit.sh`](./scripts/blindbox-audit.sh)：盲盒前后 6 维巡检（容量 / 端口 / 站点 / 解析 / 时间 / 调度），把注入器的自检条件反写成健康判据，退出码 0/1/2 可直接接监控。
- [`blindbox-score.sh`](./scripts/blindbox-score.sh)：把盲盒记录 CSV 按轮聚合成四个指标（命中率 / 平均耗时 / 平均定位层级 / 误判次数），按「命中率 ≥ 50%」判定是否具备独立排障能力。

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

# 分册四：一条命令定位「打不开」卡在哪一层（第二个参数是上游 DNS，用于对照）
./scripts/net-layer-triage.sh https://127.0.0.1/ 10.0.2.3

# 分册四：解析三视角对照（getent / dig / dig @上游）
./scripts/dns-view-compare.sh www.ubuntu.com 10.0.2.3

# 分册四：证书剩余天数体检（退出码 0/1/2/3 可接监控）
./scripts/tls-cert-check.sh 127.0.0.1 443 30

# 分册四：端口可达性分层判定（在目标机上执行）
sudo ./scripts/port-reach-triage.sh 192.168.56.12 80 ens4

# 分册四：/etc/hosts 基线比对（首次运行会给出保存基线的命令）
./scripts/hosts-drift-check.sh
./scripts/hosts-drift-check.sh /var/lib/baseline/hosts.sha256

# 分册五：服务「凭空消失」时第一个该跑的命令（可传 PID 查 oom_score）
sudo ./scripts/oom-evidence-collect.sh
sudo ./scripts/oom-evidence-collect.sh 998

# 分册五：在 150M 限额下复现 OOM，跑完自动给证据链
sudo ./scripts/mem-safe-run.sh 150M python3 /tmp/oom_eat.py

# 分册五：时间漂移五层诊断（只读，不需要 root）
./scripts/time-drift-triage.sh
./scripts/time-drift-triage.sh -v

# 分册五：时钟恢复标准流程（先 dry-run 看清楚会改什么）
sudo ./scripts/time-sync-restore.sh --dry-run
sudo ./scripts/time-sync-restore.sh

# 分册五：内存 + 时间双维度巡检，退出码 0/1/2 可接监控
sudo ./scripts/resource-baseline-check.sh
./scripts/resource-baseline-check.sh --save /var/lib/baseline/mt.json
./scripts/resource-baseline-check.sh --diff /var/lib/baseline/mt.json

# 分册六：开盲盒前巡检（0 干净 / 1 WARN / 2 FAIL）
./scripts/blindbox-audit.sh

# 分册六：注入 1 个故障（必须在控制台执行，不要在 SSH 会话里）
sudo ./scripts/chaos.sh --inject 1
sudo ./scripts/chaos.sh --status

# 分册六：对答案 + 恢复 + 复核
sudo ./scripts/chaos.sh --answer
sudo ./scripts/chaos.sh --restore
./scripts/blindbox-audit.sh

# 分册六：把记录表算成指标
./scripts/blindbox-score.sh --template > record.csv
./scripts/blindbox-score.sh record.csv
```

## 📄 许可

本仓库采用 [MIT License](./LICENSE) 发布：笔记与脚本可自由用于学习、教学与生产排障，保留版权声明即可；因直接照搬脚本产生的任何后果，作者不承担责任——排障命令请先在隔离环境验证。

仓库内所有命令、输出与截图均来自本人实验环境实测，不含任何真实生产系统地址、账号或凭据。
