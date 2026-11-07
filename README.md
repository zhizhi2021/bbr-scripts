# BBR Scripts

一个面向 Linux 服务器的单文件 BBR 管理脚本，提供设备自适应建议、配置预览、启用与恢复、网卡队列管理、内核管理和测速对比。

首页按系统状态、操作选项分区，设备方案分为资源、配置变更、执行范围及恢复路径；菜单每行一个选项，长路径在窄终端单独显示。执行前用“将修改 / 保持不变”标记计划，执行后用醒目结果框和“已修改 / 保持不变”展示实际读回值。失败时显示退出码；配置操作另行展示回滚结束后的运行状态。颜色关闭时仍保留全部文字标记。完整功能保留在高级设置和命令行中。设备建议以**均衡稳定**为目标，不承诺所有线路都能提速。

## 一键运行

在 **Bash 终端**中，以 **root** 身份执行；需要已安装 `curl`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhizhi2021/bbr-scripts/main/bbr.sh)
```

首页选择 **1**，查看设备方案后输入 **y** 即可启用；直接回车或输入 `n` 会取消修改。以后执行同一条命令，可以再次管理或恢复配置。

```text
1  一键按设备启用 BBR（推荐）
2  查看状态
3  测速
4  恢复与排障
5  高级设置（全部功能）
0  退出
```

测速填写自己的 iperf3 服务端后，回车使用推荐参数；输入 `a` 可以自定义端口、时长、算法、方向、并发和测试模式。测试会产生实际流量。

也可以先查看 [bbr.sh](bbr.sh)，或保留本地副本：

```bash
git clone https://github.com/zhizhi2021/bbr-scripts.git
cd bbr-scripts
bash bbr.sh menu
```

下文的 `bash bbr.sh ...` 命令均在脚本所在目录执行。只读命令可用普通用户运行；配置、队列和内核修改需要 root。

## 适配范围

代码中的适配名单核对日期为 **2026-11-07**：

| 发行版 | 名单内版本 |
| --- | --- |
| Debian | 12 LTS、13 |
| Ubuntu | 22.04 LTS、24.04 LTS（均含各点版本）、26.04、26.10 |
| Rocky Linux | 9.8、10.2 |
| AlmaLinux | 9.8、10.2 |

架构识别覆盖 `x86_64` 和 `aarch64`。**名单匹配不等于已完成该发行版或架构的真机验证。** 后续版本需更新名单，不自动视为兼容。

名单同时覆盖仍在支持期内的 Debian 12 LTS、Ubuntu 22.04/24.04 LTS，不再只按最近两年的发布日期筛选。Ubuntu 各点版本使用相同的 `VERSION_ID` 判断。名单通过后仍须检查实际内核能力、root 权限和恢复条件。

其他版本仍可查看状态、预演和测速，但新配置写入受限。已有恢复记录不受名单变化阻断，仍需 root、非容器环境及有效的恢复条件。

容器内允许诊断、预演和测速，禁止系统配置、队列和内核修改。

## 依赖

需要 Linux、Bash 4.4 或更新版本，以及常见 GNU 工具。

| 用途 | 工具或软件包 |
| --- | --- |
| 下载 | `curl` |
| 运行参数与修改锁 | `sysctl`（procps）、`flock`（util-linux） |
| 设备分析、JSON、连接检查、结果比较 | Python 3 |
| 网卡与队列 | `ip`、`tc`（Debian: iproute2；Rocky/Alma: iproute-tc），`unshare`（util-linux） |
| 按需加载内核模块 | `modprobe`（kmod）；已内置或注册的能力不强制依赖模块文件 |
| 测速 | iperf3、`timeout`（coreutils） |
| 内核安装 | 发行版包管理器、官方签名信任及脚本支持的启动环境 |

从 v1.1.2 起，交互菜单、配置修改和测速会先检查所需工具，以 root 身份通过系统包管理器自动安装缺失项，再继续操作。例如选择“按设备建议启用 BBR”时，缺少 Python 3 会自动安装，无需手动退出处理。Debian/Ubuntu 使用 APT，Rocky/AlmaLinux 使用 DNF；依赖安装不添加软件源、不安装内核或启动器、不重启，也不会关闭 TLS 或包签名验证。

只读 CLI 命令与 `--dry-run` 不安装软件。可以提前一次补齐所有运行依赖：

```bash
bash bbr.sh install-deps
```

添加 `--no-install` 可禁止自动安装。非 root 用户、软件源不可用或安装后工具仍缺失时，会明确报错并停止依赖该工具的操作。下载脚本所需的 Bash 和 curl 需由系统预先提供。

日志从 v1.1.4 起保存在 root 专用状态目录，避免系统 `/var/log` 的组写入权限触发路径保护。旧日志保留原处，不自动迁移或修改系统目录权限。

## 常用命令

### 查看设备与预演

```bash
bash bbr.sh profile
bash bbr.sh plan --auto
bash bbr.sh enable --auto --dry-run
bash bbr.sh status
bash bbr.sh doctor
```

`--dry-run` 不写配置、不加载模块、不发起测速；它不代表实际执行所需的权限、模块和启动条件已经满足。

### 启用与恢复

```bash
# 按设备建议启用，执行前确认
bash bbr.sh enable --auto

# 手动指定队列；优先于自动建议
bash bbr.sh enable --auto --qdisc fq

# 恢复启用前保存的配置和运行参数
bash bbr.sh restore
```

`disable` 与 `restore` 含义相同。重复启用且运行值、持久配置和恢复记录一致时，不重复写入。

自动化调用可追加 `--yes` 跳过确认。请先通过 `plan` 或 `--dry-run` 核对目标。

**启用默认 BBR 不会直接更换现有网卡的根队列。** 默认拥塞算法主要影响新建 socket；已有连接或监听 socket 可能继续使用原选择。

### 网卡队列

下面的 `eth0` 需替换为目标网卡：

```bash
bash bbr.sh queue --interface eth0 --auto --dry-run
bash bbr.sh queue --interface eth0 --auto
bash bbr.sh queue --interface eth0 --qdisc fq_codel --auto
bash bbr.sh queue-restore
```

交互模式在默认路由唯一时提供网卡建议；存在歧义时由用户选择。

队列修改仅在本次运行中生效，不安装常驻服务。脚本只处理可完整恢复的简单拓扑；附着过滤规则、共享 block、复杂或未知属性会阻止自动替换。`cake` 自动更换限普通 Ethernet 类型。

## 设备自适应策略

`--auto` 在目标机器运行时读取资源，而不是套用开发机器的固定配置：

- CPU：结合可见逻辑核心、进程亲和性、cgroup v1/v2 当前层及可见祖先配额。
- 内存：结合可见容量、cgroup 限制和剩余内存。关键用量未知时停止自动应用。
- 队列建议：有效内存低于 512 MiB 时推荐 `fq_codel`，其余推荐 `fq`。手动 `--qdisc` 优先。
- 队列预算：取 **32 MiB、有效内存 / 128、可用内存 / 32** 的最小值；不足 1 MiB 时停止自动应用。
- `fq` 按每包 4 KiB 估算包数上限，**不构成严格的内存上限**；`fq_codel` 使用 `memory_limit`，`cake` 使用 `memlimit`。
- 单连接基准使用 1 流；设备推荐并发最多 4 流，手动 `--parallel` 优先。

队列预算只在显式执行 `queue --auto` 时应用。`enable --auto` 仅管理默认 BBR 配置，不会顺便替换网卡队列。

CPU、内存和 MTU 不能推算运营商带宽、RTT 或业务负载。脚本不自动放大 TCP 缓冲区、连接数等参数。

## 测速与前后对比

准备自己有权使用的 iperf3 服务端。在服务端启动：

```bash
iperf3 -s
```

确保测试客户端能够访问服务端的测试端口，默认 TCP 5201。以下 `iperf.example.com` 是占位符，需要替换：

```bash
# 单连接
bash bbr.sh benchmark --host iperf.example.com

# 单连接和设备建议并发分轮测试
bash bbr.sh benchmark --host iperf.example.com --suite --auto

# 手动并发和时长
bash bbr.sh benchmark --host iperf.example.com --parallel 4 --duration 10

# 相同条件下依次测试 cubic 与 bbr，需当前内核均已注册
bash bbr.sh benchmark --host iperf.example.com --compare

# 反向接收，实际发送算法由服务端决定
bash bbr.sh benchmark --host iperf.example.com --reverse
```

命令行测速默认请求 `bbr`，需要该算法已注册；也可用 `--algorithm cubic` 等选择当前可用算法。快捷菜单默认使用当前算法。测速不会自动加载拥塞控制模块。

测试只设置测试 socket，不修改系统默认拥塞算法。`--reverse` 不能与 `--compare` 同用。

条件记录、原始 JSON 和错误输出保存在每次打印的 `/tmp/bbr-benchmark.*` 目录。自动模式还记录设备资源快照；这些临时结果需要长期保存时请自行备份。

对比两组已保存的结果，将下面的路径替换为真实目录：

```bash
bash bbr.sh compare --before /path/to/before --after /path/to/after
```

目标、端口、时长、方向、并发和请求算法等条件必须一致。实测发送端算法不同会拒绝比较；反向测试缺少实测服务端算法也会拒绝比较。结果展示吞吐、重传和 RTT，不把两次观测自动解释为优化收益。

## 内核管理

```bash
bash bbr.sh kernel list
bash bbr.sh kernel plan
bash bbr.sh kernel install --dry-run
bash bbr.sh kernel install
bash bbr.sh kernel verify
```

安装只使用经校验的发行版来源，并检查空间、旧内核和启动环境：

- Debian / Ubuntu 要求有效的 GRUB saved-entry，明确指向当前运行内核。
- Rocky / AlmaLinux 通过 grubby 核对并保留默认内核。
- APT 固定当前运行内核及模块包的已安装版本；同 ABI 覆盖更新可能因依赖冲突而停止。
- DNF 使用已校验的发行版 key，并在独立信任库中校验下载的软件包；保留旧内核版本。

**从 v1.2.0 起，`kernel install` 安装并校验新内核后，会直接设置新内核为默认启动项，倒计时 10 秒后自动重启。** 倒计时内按 `Ctrl+C` 会取消并恢复原默认项。运行安装命令前应保存工作，并确保有服务器控制台可选回旧内核。

- Debian/Ubuntu 只选择本次安装的发行版元包所依赖的内核镜像；不会取全机任意最高版本。
- Rocky/AlmaLinux 只选择本次已通过发行版 key 验签的 RPM 对应内核；没有下载新镜像时不重启。
- 切换前校验内核包、架构、BBR 支持及模块、initramfs、模块目录和精确启动项，再读回默认启动项。
- 没有更新的可信候选内核、启动项不明确、安装/校验/重启请求失败时，不会自动重启；切换途中失败会尝试恢复原默认启动项，并保留无法恢复的事务记录。
- 保留旧内核。只支持已适配的 GRUB saved-entry / grubby，不自动改造其他启动器。
- 重启请求成功仍不等于新内核已正常启动。重新连接后，以 root 运行 `bash bbr.sh kernel verify`，确认运行版本和默认启动项后归档切换记录。`--dry-run` 只读取核验结果，不写入记录。
- `bash bbr.sh kernel recover` 可从待确认或已确认的最近切换记录恢复原默认启动项；恢复动作不卸载内核、不自动重启。

普通 BBR 启用、队列调整、依赖安装、诊断和预演均不会自动重启。

**BBRv3 自动安装暂未开放**：没有已核验的签名包来源时会拒绝安装。算法名 `bbr` 本身不能证明是 v1 或 v3。

## 恢复与排障

菜单选择 **4**，或执行：

```bash
bash bbr.sh recovery
```

| 内容 | 位置或命令 |
| --- | --- |
| 持久配置 | `/etc/sysctl.d/99-zz-bbr-script.conf` |
| 原始状态、事务及历史记录 | `/var/lib/bbr-script/` |
| 修改操作日志 | `/var/lib/bbr-script/bbr-script.log` |
| 恢复配置或中断的配置事务 | `bash bbr.sh restore` |
| 恢复网卡队列 | `bash bbr.sh queue-restore` |
| 恢复内核安装前默认启动项 | `bash bbr.sh kernel recover` |

检测到后续人工修改时，脚本会停止覆盖。其他文件中的同名 sysctl 参数与本次目标值相同时允许继续，原文件保持不变；值不同或使用通配符等无法安全确认的配置仍需手动核对。恢复时按原始目标值重新检查，脚本不会批量删除这些配置。

例如系统已通过 `10-bufferbloat.conf` 设置 `fq_codel`，可保留该队列，仅启用 BBR：

```bash
bash bbr.sh enable --auto --qdisc fq_codel
```

若第一次 `restore` 恢复了中断事务，按输出提示再次执行，才能回到首次启用前的原始状态。

断电或 `SIGKILL` 无法执行退出清理。内核操作中断后应先核对恢复记录和启动项，再决定是否重启；启动项恢复不等于卸载部分安装的软件包或修复全部包管理器状态。

## 已验证范围

- **v1.1.1**：158 项外部自动化测试、Bash 语法检查、ShellCheck 和真实终端交互验证通过。测试工作区不随本仓库提交。
- **v1.1.0 核心设备逻辑**：在运行独立 Debian 13 内核和 systemd 的 x86_64 QEMU 虚拟机中验证，而非把普通容器当作内核测试。

| 虚拟机配置 | 已验证流程 |
| --- | --- |
| 2 CPU / 1536 MB | 设备识别、BBR 启用、真实网卡队列更换与恢复、实际单流/并发测试、重启持久化、恢复原参数 |
| 1 CPU / 512 MB | 低资源建议、fq_codel 队列内存限制、队列与原配置恢复 |

尚未完成所有适配发行版、ARM64，以及真实机器通过 GRUB 启动新内核的完整验证。回环测速用于功能检查，不代表公网加速效果。

## 参考

- [Google BBR](https://github.com/google/bbr)
- [Linux TCP BBR 源码](https://github.com/torvalds/linux/blob/master/net/ipv4/tcp_bbr.c)
