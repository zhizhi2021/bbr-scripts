#!/usr/bin/env bash
# BBR manager — only this script is required. Bash >= 4.4, Linux.
# Algorithm references: https://github.com/google/bbr
# No remote shell execution, automatic reboot, or kernel removal.

VERSION=1.1.5
STATE_DIR=/var/lib/bbr-script
CONFIG=/etc/sysctl.d/99-zz-bbr-script.conf
LOG=$STATE_DIR/bbr-script.log
OS_RELEASE=/etc/os-release
DRY_RUN=0 YES=0 AUTO_INSTALL=1
COMMAND='' ACTION='' HOST='' IFACE='' QUEUE=fq PORT=5201 DURATION=10 STREAMS=1
REVERSE=0 COMPARE=0 ALGORITHM=bbr
OS_ID=unknown OS_VERSION=unknown ARCH=unknown VIRT=unknown
SUPPORTED=0
TX_ACTIVE=0 TX_DIR=''
AUTO=0 SUITE=0 QUEUE_EXPLICIT=0 STREAMS_EXPLICIT=0 ALGORITHM_EXPLICIT=0
BEFORE='' AFTER='' DEVICE_JSON='' DEVICE_QUEUE=fq DEVICE_BUDGET=0 DEVICE_STREAMS=1

say() { printf '%s\n' "$*"; }
warn() { printf '提示：%s\n' "$*" >&2; }
fail() { printf '错误：%s\n' "$*" >&2; return 1; }
usage() {
    cat <<'HELP'
BBR 管理工具：检测、预演、启用和恢复；不会自动重启。
用法：bash bbr.sh <命令> [选项]
  install-deps            安装运行依赖（不安装内核或启动器）
  status / doctor         查看系统、算法、队列和连接诊断
  enable                  启用当前内核 BBR，默认队列 fq
  disable                 恢复第一次 enable 前的状态（与 restore 相同）
  restore                 恢复原配置及原运行参数；拒绝覆盖后续人工修改
  queue --interface 网卡  显式更换简单根队列；支持 fq/fq_codel/cake
  queue-restore           恢复本脚本更换过的简单根队列
  kernel list|plan|install|verify|recover [--channel distro|bbr3]
                          发行版内核管理；BBRv3 无可信安装源时拒绝安装
  benchmark --host 主机   运行 iperf3；需自备有权限使用的服务端
  profile / plan          查看有效设备资源 / 配置前后差异
  recovery                只读恢复与排障中心
  compare --before 目录 --after 目录
                          比较相同条件下保存的两组测速结果
  menu                    简洁首页：1 设备启用 / 2 状态 / 3 测速 / 4 恢复 / 5 全部高级功能
选项：
  --auto                  均衡设备建议；手动参数优先，队列预算仅用于 queue
  --suite                 单连接与设备建议并发分别测试，需自备 iperf3 服务端
  --dry-run               仅预演，不写文件、不加载模块、不发起测速
  --no-install            禁止按需自动安装缺少的依赖
  --yes                   确认修改；默认需要终端确认
  --qdisc fq|fq_codel|cake 队列选择（enable 仅设置默认，不替换现有队列）
  --port 1..65535         iperf3 端口，默认 5201
  --duration 1..120       测速秒数，默认 10
  --parallel 1..16        TCP 流数量，默认 1
  --algorithm 名称        测速客户端发送使用的可用算法，默认 bbr
  --compare               按相同条件依次测试 cubic / bbr，仅正向
  --reverse               测试服务端发送；算法由服务端控制，结果需核实
  --help / --version
适配名单（2026-11-07）：Debian 12 LTS/13，Ubuntu 22.04 LTS/24.04 LTS/26.04/26.10，Rocky/AlmaLinux 9.8/10.2；x86_64/aarch64。
其他版本仅诊断；名单内也须通过能力、权限和启动检查，未承诺跨发行版真机验证。
重复启用且配置一致时不重复写入；恢复已有记录不受适配名单变化限制，仍需 root 且不在容器。
运行状态与配置状态分开显示。默认算法只影响新 socket，监听 socket 可能继承旧值。
断电/SIGKILL 后需先检查并执行 restore / queue-restore / kernel recover；失败时勿盲目重启。
状态：/var/lib/bbr-script；日志：/var/lib/bbr-script/bbr-script.log（仅修改操作）。
队列更换拒绝附着 filter/共享 block；fq/fq_codel 使用显式 MTU 参数，cake 限普通 Ethernet。
内核安装保留当前内核包版本；同 ABI 覆盖更新会因版本约束而停止，不强行覆盖。
BBRv1/v3 不凭算法名 bbr 猜测。容器不允许系统修改，可诊断、预演和测速。性能提升取决于路径与负载。
HELP
}

has() { command -v "$1" >/dev/null 2>&1; }
# Keep installation outside JSON-producing device probes.
dependency_can_install() { (( EUID == 0 )); }
dependency_manager() {
    local key value id=''
    while IFS='=' read -r key value; do
        [[ $key == ID ]] || continue
        value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
        id=$value; break
    done < "$OS_RELEASE"
    case $id in
        debian|ubuntu) has apt-get && printf 'apt\n' ;;
        rocky|almalinux) has dnf && printf 'dnf\n' ;;
        *) fail '无法自动安装：此发行版未配置支持的包管理器'; return 1 ;;
    esac
}
install_runtime_packages() {
    local manager=$1; shift
    case $manager in
        apt)
            local -a opts=(-o APT::Get::AllowUnauthenticated=false -o Acquire::AllowInsecureRepositories=false
                -o Acquire::https::Verify-Peer=true -o Acquire::https::Verify-Host=true
                -o DPkg::Lock::Timeout=60 -o Acquire::Retries=2)
            DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" update >&2 || return $?
            DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold install --yes --no-remove --no-install-recommends "$@" >&2 ;;
        dnf)
            dnf --assumeyes --setopt=gpgcheck=1 --setopt='*.gpgcheck=1' \
                --setopt=sslverify=1 --setopt='*.sslverify=1' --setopt=install_weak_deps=False install "$@" >&2 ;;
        *) fail '未知包管理器'; return 1 ;;
    esac
}
ensure_dependencies() {
    local tool manager package present rc
    local -a missing=() packages=()
    for tool in "$@"; do has "$tool" || missing+=("$tool"); done
    (( ${#missing[@]} )) || return 0
    if (( DRY_RUN )); then fail "预演不安装依赖；缺少：${missing[*]}。请先运行 install-deps"; return 1; fi
    (( AUTO_INSTALL )) || { fail "自动安装已关闭；缺少：${missing[*]}"; return 1; }
    dependency_can_install || { fail "自动安装缺少的依赖需要 root：${missing[*]}"; return 1; }
    manager=$(dependency_manager) || return 1
    for tool in "${missing[@]}"; do
        case $tool in
            python3|iperf3|grep|sed) package=$tool ;;
            sysctl) if [[ $manager == apt ]]; then package=procps; else package=procps-ng; fi ;;
            ip|tc)
                if [[ $manager == apt ]]; then package=iproute2
                elif [[ $tool == tc ]]; then package=iproute-tc
                else package=iproute; fi ;;
            flock|unshare|setsid) package=util-linux ;;
            modprobe) package=kmod ;;
            awk) package=gawk ;; cmp) package=diffutils ;;
            timeout|stat|mktemp|date|head|cat|cp|mv|chmod|sync|rm|mkdir|rmdir|uname|df|readlink) package=coreutils ;;
            *) fail "没有工具 $tool 的可信包映射"; return 1 ;;
        esac
        present=0
        for rc in "${packages[@]}"; do [[ $rc != "$package" ]] || present=1; done
        (( present )) || packages+=("$package")
    done
    warn "正在通过系统包管理器安装缺少的依赖：${missing[*]}"
    install_runtime_packages "$manager" "${packages[@]}" || { rc=$?; fail '依赖安装失败，请检查软件源、网络及包管理器状态后重试'; return "$rc"; }
    hash -r
    for tool in "${missing[@]}"; do has "$tool" || { fail "安装后仍缺少 $tool"; return 1; }; done
}
install_dependencies() {
    ensure_dependencies python3 sysctl ip tc flock unshare setsid modprobe awk cmp grep sed timeout stat mktemp date head cat cp mv chmod sync rm mkdir rmdir uname df readlink iperf3
}
read_os_field() {
    awk -F= -v key="$1" '$1==key {v=substr($0,index($0,"=")+1); gsub(/^"|"$/, "", v); gsub(/^\047|\047$/, "", v); print v; exit}' "$OS_RELEASE"
}
detect_system() {
    OS_ID=unknown OS_VERSION=unknown SUPPORTED=0
    if [[ -r $OS_RELEASE ]]; then
        OS_ID=$(read_os_field ID); OS_VERSION=$(read_os_field VERSION_ID)
    fi
    ARCH=$(uname -m)
    VIRT=none
    if [[ -e /.dockerenv || -e /run/.containerenv ]]; then
        VIRT=container
    elif has systemd-detect-virt; then
        local detected
        detected=$(systemd-detect-virt --container 2>/dev/null) && VIRT="container:$detected"
    fi
    [[ -d /proc/vz && ! -d /proc/bc ]] && VIRT=container:openvz
    # Stable release allowlist checked 2026-11-07; not a rolling support claim.
    # Debian/Ubuntu: signed Debian distro-info-data 0.66+deb13u2 CSVs.
    # Rocky: https://docs.rockylinux.org/releases/ (official documentation repo).
    # Alma: https://wiki.almalinux.org/release-notes/ (official wiki repo).
    # Include maintained LTS releases, even outside the recent-release window:
    # Debian 12 LTS through 2028-06; Ubuntu 22.04 standard support into 2027.
    # Ubuntu VERSION_ID stays major.minor across point releases.
    # RPM vendors maintain only the latest minor. Unlisted releases remain
    # diagnostic-only until reviewed; no VM test implied.
    SUPPORTED=0
    case "$OS_ID:$OS_VERSION" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|ubuntu:26.10|rocky:9.8|rocky:10.2|almalinux:9.8|almalinux:10.2) SUPPORTED=1 ;;
    esac
    case $ARCH in x86_64|aarch64) ;; *) SUPPORTED=0 ;; esac
    return 0
}
sys_value() { sysctl -n "$1" 2>/dev/null; }
contains_word() { [[ " $1 " == *" $2 "* ]]; }
detect_capabilities() {
    AVAILABLE=$(sys_value net.ipv4.tcp_available_congestion_control || :)
    CURRENT_CC=$(sys_value net.ipv4.tcp_congestion_control || :)
    CURRENT_QDISC=$(sys_value net.core.default_qdisc || :)
}
inspect_qdiscs() {
    if has tc; then tc -s qdisc show; else fail '缺少 tc（iproute2），无法检查实际网卡队列。'; return 1; fi
}
show_status() {
    local rc=0
    detect_system; detect_capabilities
    say "BBR 管理工具 $VERSION"
    say "系统：$OS_ID $OS_VERSION / $ARCH；虚拟化：$VIRT"
    say "内核：$(uname -r)"
    say "适配名单匹配：$SUPPORTED（名单核对 2026-11-07；不代表真机验证，后续版本需更新名单）"
    say "可用拥塞算法：${AVAILABLE:-无法读取}"
    say "运行默认算法：${CURRENT_CC:-无法读取}"
    say "运行默认队列：${CURRENT_QDISC:-无法读取}"
    say 'BBR 版本：未知；算法名不能证明 v1/v3，需核验内核来源。'
    if [[ -r $CONFIG ]]; then say "持久配置：$CONFIG"; cat -- "$CONFIG" || rc=1
    elif [[ -e $CONFIG || -L $CONFIG ]]; then say '持久配置：存在，但当前用户无读取权限或链接目标不可用'; rc=1
    else say '持久配置：未由本脚本管理'; fi
    if [[ -z $AVAILABLE || -z $CURRENT_CC || -z $CURRENT_QDISC ]]; then warn '运行参数读取不完整，不能确认配置状态。'; rc=1; fi
    say '实际网卡队列：'; inspect_qdiscs || rc=1
    say '新建 socket 才采用新的默认算法；已有监听 socket 可能继续继承旧值。'
    [[ $VIRT == container* ]] && warn '容器内可见值不代表宿主机可由本脚本管理。'
    return "$rc"
}
confirm() {
    (( YES )) && return 0
    [[ -t 0 ]] || { fail '非交互修改需要 --yes；先使用 --dry-run 查看。'; return 1; }
    local reply
    read -r -p '确认应用？[y/N]：' reply || { warn '已取消。'; return 1; }
    case $reply in y|Y|yes|YES|Yes) return 0 ;; *) warn '已取消。'; return 1 ;; esac
}
validate_platform() {
    local mode=${1:-write}
    [[ $VIRT != container* ]] || { fail '容器只支持诊断，不修改宿主机相关设置。'; return 1; }
    # Recorded recovery must remain available after a distribution upgrade.
    if [[ $mode != recovery ]] && (( ! SUPPORTED )); then
        fail "尚未开放此系统/架构的写入：$OS_ID $OS_VERSION $ARCH"; return 1
    fi
}
require_mutation() {
    (( EUID == 0 )) || { fail '此操作需要 root。'; return 1; }
    validate_platform "${1:-write}" || return 1
    confirm
}
parse_args() {
    local -a scoped=()
    CHANNEL=distro
    while (( $# )); do
        case $1 in
            --help|-h) usage; return 10 ;;
            --version) say "$VERSION"; return 10 ;;
            --dry-run) DRY_RUN=1 ;;
            --no-install) AUTO_INSTALL=0 ;;
            --yes|-y) YES=1 ;;
            --auto) AUTO=1; scoped+=(--auto) ;;
            --suite) SUITE=1; scoped+=(--suite) ;;
            --reverse) REVERSE=1; scoped+=(--reverse) ;;
            --compare) COMPARE=1; scoped+=(--compare) ;;
            --host|--interface|--qdisc|--port|--duration|--parallel|--algorithm|--channel|--before|--after)
                local opt=$1
                scoped+=("$opt")
                (( $# >= 2 )) && [[ $2 != --* ]] || { fail "$opt 缺少参数"; return 2; }
                case $opt in
                    --host) HOST=$2 ;; --interface) IFACE=$2 ;; --qdisc) QUEUE=$2; QUEUE_EXPLICIT=1 ;;
                    --port) PORT=$2 ;; --duration) DURATION=$2 ;; --parallel) STREAMS=$2; STREAMS_EXPLICIT=1 ;;
                    --algorithm) ALGORITHM=$2; ALGORITHM_EXPLICIT=1 ;; --channel) CHANNEL=$2 ;;
                    --before) BEFORE=$2 ;; --after) AFTER=$2 ;;
                esac
                shift ;;
            --*) fail "未知选项：$1"; return 2 ;;
            *)
                if [[ -z $COMMAND ]]; then COMMAND=$1
                elif [[ $COMMAND == kernel && -z $ACTION ]]; then ACTION=$1
                else fail "未知参数：$1"; return 2; fi ;;
        esac
        shift
    done
    case $COMMAND in ''|install-deps|status|doctor|enable|disable|restore|queue|queue-restore|kernel|benchmark|menu|profile|plan|recovery|compare) ;; *) fail "未知命令：$COMMAND"; return 2 ;; esac
    case $QUEUE in fq|fq_codel|cake) ;; *) fail '不支持的队列'; return 2 ;; esac
    case $CHANNEL in distro|bbr3) ;; *) fail '不支持的内核通道'; return 2 ;; esac
    [[ $ALGORITHM =~ ^[a-zA-Z0-9_]{1,32}$ ]] || { fail '算法名称不合法'; return 2; }
    local scope
    for scope in "${scoped[@]}"; do
        case "$scope:$COMMAND" in
            --host:benchmark|--host:menu|--port:benchmark|--port:menu|--duration:benchmark|--duration:menu|--parallel:benchmark|--parallel:menu|--algorithm:benchmark|--algorithm:menu|--reverse:benchmark|--compare:benchmark|--interface:queue|--interface:menu|--qdisc:enable|--qdisc:queue|--qdisc:menu|--channel:kernel|--interface:profile|--interface:plan|--qdisc:plan|--auto:enable|--auto:queue|--auto:benchmark|--auto:plan|--auto:menu|--suite:benchmark|--before:compare|--after:compare) ;;
            *) fail "$scope 不适用于命令 ${COMMAND:-空}，请查看 --help"; return 2 ;;
        esac
    done
    local value limit
    for value in "$PORT:65535" "$DURATION:120" "$STREAMS:16"; do
        limit=${value#*:}; value=${value%:*}
        if [[ ! $value =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$value > limit )); then fail '端口、时长或流数超出范围'; return 2; fi
    done
    [[ -z $HOST || $HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$ ]] || { fail '主机格式不合法（不能是 URL 或选项）'; return 2; }
    [[ -z $IFACE || $IFACE =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ ]] || { fail '网卡名称不合法'; return 2; }
    return 0
}
hardware_snapshot() {
    has python3 || { fail '设备分析需要 python3；基础 BBR 命令仍可独立使用'; return 1; }
    python3 - "${1:-/proc}" "${2:-/sys}" <<'PY'
import json,os,pathlib,re,sys,math
proc=pathlib.Path(sys.argv[1]);syspath=pathlib.Path(sys.argv[2]);notes=[];uncertain=False
def read(p):
    try:return p.read_text().strip()
    except OSError as e:
        global uncertain
        if isinstance(e,PermissionError):uncertain=True
        return ''
def integer(p):
    try:return int(read(p))
    except ValueError:return None
def finite_limit(p):
    n=integer(p)
    return n if n is not None and 0<=n<2**60 else None
logical=sum(1 for x in read(proc/'cpuinfo').splitlines() if re.match(r'^processor\s*:',x)) or (os.cpu_count() or 1)
affinity=logical
for line in read(proc/'self/status').splitlines():
    if line.startswith('Cpus_allowed_list:'):
        try:
            affinity=0
            for item in line.split(':',1)[1].strip().split(','):
                a,sep,b=item.partition('-');a=int(a);b=int(b) if sep else a
                if not 0<=a<=b<=1000000:raise ValueError()
                affinity+=b-a+1
        except ValueError:affinity=logical
mem={}
for line in read(proc/'meminfo').splitlines():
    m=re.match(r'(MemTotal|MemAvailable):\s+(\d+)\s+kB',line)
    if m:mem[m[1]]=int(m[2])*1024
total=mem.get('MemTotal',0);available=mem.get('MemAvailable',0)
if 'MemAvailable' not in mem:uncertain=True;notes.append('可用内存未知，自动应用被禁用')
cpu_caps=[float(max(1,min(logical,affinity)))];mem_caps=[total];headroom=[available]
groups={}
for line in read(proc/'self/cgroup').splitlines():
    parts=line.split(':',2)
    if len(parts)==3:
        for c in parts[1].split(','):groups[c]=parts[2]
def unescape(s):return re.sub(r'\\([0-7]{3})',lambda m:chr(int(m[1],8)),s)
def mapped_mount(path):
    p=pathlib.PurePosixPath(path)
    return syspath/path[5:] if path.startswith('/sys/') else pathlib.Path(path)
def ancestors(mount,root,group):
    if '..' in pathlib.PurePosixPath(group).parts:return []
    root=root.rstrip('/') or '/'
    rel=group[len(root):] if root!='/' and (group==root or group.startswith(root+'/')) else group
    current=mount/rel.lstrip('/');out=[]
    while True:
        out.append(current)
        if current==mount:break
        if mount not in current.parents:return []
        current=current.parent
    return out
mounts=[]
for line in read(proc/'self/mountinfo').splitlines():
    left,sep,right=line.partition(' - ')
    if not sep:continue
    a=left.split();b=right.split()
    if len(a)>=5 and len(b)>=3 and b[0] in ('cgroup','cgroup2'):
        mounts.append((mapped_mount(unescape(a[4])),unescape(a[3]),b[0],set(b[2].split(','))))
if not mounts and (syspath/'fs/cgroup/cpu.max').exists():mounts=[(syspath/'fs/cgroup','/','cgroup2',set())]
for mount,root,kind,ctrls in mounts:
    group=groups.get('' if kind=='cgroup2' else ('memory' if 'memory' in ctrls else 'cpu'))
    if group is None:continue
    for node in ancestors(mount,root,group):
        if kind=='cgroup2':
            vals=read(node/'cpu.max').split()
            if len(vals)==2 and vals[0]!='max':
                try:
                    q,p=map(int,vals)
                    if q>0 and p>0:cpu_caps.append(q/p)
                except ValueError:pass
            limits=[finite_limit(node/'memory.max'),finite_limit(node/'memory.high')]
            usage=integer(node/'memory.current')
        else:
            if 'cpu' in ctrls:
                q=integer(node/'cpu.cfs_quota_us');p=integer(node/'cpu.cfs_period_us')
                if q is not None and p is not None and q>0 and p>0:cpu_caps.append(q/p)
            limits=[finite_limit(node/'memory.limit_in_bytes')] if 'memory' in ctrls else []
            usage=integer(node/'memory.usage_in_bytes')
        for limit in limits:
            if limit is not None:
                mem_caps.append(limit)
                if usage is not None and usage>=0:headroom.append(max(0,limit-usage))
                else:uncertain=True;headroom.append(0);notes.append('cgroup 内存用量未知，不能确认剩余容量')
effective_cpu=min(cpu_caps);effective_memory=min(mem_caps);available=max(0,min(headroom+[effective_memory]))
budget=max(0,min(32*1024**2,effective_memory//128,available//32))
pressure=min(4,max(1,math.floor(effective_cpu)),max(1,available//(128*1024**2)))
if not total:notes.append('无法读取内存容量，自动应用被禁用')
if available<16*1024**2:notes.append('可用内存过低，建议先释放资源')
print(json.dumps({'logical_cpus':logical,'effective_cpus':effective_cpu,'memory_limit_bytes':effective_memory,
 'memory_available_bytes':available,'queue_budget_bytes':budget,'pressure_streams':pressure,
 'recommended_qdisc':'fq_codel' if effective_memory<512*1024**2 else 'fq',
 'complete':bool(total) and not uncertain,'notes':list(dict.fromkeys(notes))},ensure_ascii=False))
PY
}
load_device_resources() {
    DEVICE_JSON=$(hardware_snapshot) || return 1
    local values
    values=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["recommended_qdisc"]);print(d["queue_budget_bytes"]);print(d["pressure_streams"]);sys.exit(not d["complete"])' <<< "$DEVICE_JSON") || { fail '设备资源读取不完整，自动操作已停止；请运行 profile 查看原因'; return 1; }
    local -a fields
    mapfile -t fields <<< "$values"
    DEVICE_QUEUE=${fields[0]} DEVICE_BUDGET=${fields[1]} DEVICE_STREAMS=${fields[2]}
}
apply_device_defaults() {
    (( AUTO )) || return 0
    load_device_resources || return 1
    (( DEVICE_BUDGET >= 1048576 )) || { fail '设备可用内存不足，自动应用已停止，保留原配置'; return 1; }
    (( QUEUE_EXPLICIT )) || QUEUE=$DEVICE_QUEUE
}
show_device_profile() {
    local json
    json=$(hardware_snapshot) || return 1
    python3 -c 'import json,sys; d=json.load(sys.stdin)
print("有效 CPU：%g（可见逻辑 CPU：%s；含亲和性和配额限制）"%(d["effective_cpus"],d["logical_cpus"]))
print("有效内存：%.1f MiB；当前可用：%.1f MiB"%(d["memory_limit_bytes"]/1048576,d["memory_available_bytes"]/1048576))
print("均衡建议：%s；队列预算 %.2f MiB；单流基准 1，压力测试建议 %s 流"%(d["recommended_qdisc"],d["queue_budget_bytes"]/1048576,d["pressure_streams"]))
for n in d["notes"]:print("提示："+n)
print("fq 包数按 4 KiB/包估算，不是严格内存上限；fq_codel/cake 可限制队列内存。")
print("设备资源不能推算运营商带宽、RTT 或最优 TCP 缓冲区，脚本不自动放大这些参数。")
sys.exit(not d["complete"])' <<< "$json" || return 1
    if [[ -n $IFACE ]] && has ip; then ip -o link show dev "$IFACE" || return 1; fi
}
show_change_plan() {
    show_device_profile || return 1
    apply_device_defaults || return 1
    detect_capabilities
    say "新连接默认算法：${CURRENT_CC:-未知} → bbr"
    say "默认队列：${CURRENT_QDISC:-未知} → $QUEUE（手动 --qdisc 优先）"
    say "持久配置：$CONFIG；原状态：$STATE_DIR/baseline"
    say 'enable 不替换当前网卡队列；queue 才会显式更换选定网卡，并检查拓扑和恢复条件。'
    if (( AUTO )); then say "自动队列预算：$DEVICE_BUDGET 字节；仅在 queue --auto 时生效。"; fi
    say '不调整 TCP 缓冲区/连接数，不安装内核，不自动重启。'
}
show_queue_plan() {
    show_device_profile || return 1
    apply_device_defaults || return 1
    say "网卡变更：$IFACE → $QUEUE；不改变系统默认算法与默认队列。"
    if (( AUTO )); then say "设备队列预算：$DEVICE_BUDGET 字节；fq 仅按包数估算，fq_codel/cake 使用内存限制。"; fi
    say '只在本次运行中更换可完整恢复的简单根队列；现有过滤器、共享 block 或未知拓扑会阻止修改。'
}
recovery_center() {
    say '恢复与排障中心（只读）'
    say "状态目录：$STATE_DIR"
    say "日志位置：$LOG（本命令不自动输出日志内容）"
    if [[ -d $STATE_DIR && ! -x $STATE_DIR ]]; then fail '当前用户无读取权限，请以 root 查看恢复记录。'; return 1; fi
    local pending=0
    if [[ -d $STATE_DIR/transaction ]]; then say '配置事务未完成：bash bbr.sh restore'; pending=1; fi
    if [[ -d $STATE_DIR/kernel.pending ]]; then say '内核事务未完成：bash bbr.sh kernel recover'; pending=1; fi
    if [[ -d $STATE_DIR/queue.pending ]]; then say '队列事务未完成：bash bbr.sh queue-restore'; pending=1; fi
    (( pending )) || say '没有未完成事务。'
    if [[ -d $STATE_DIR/baseline ]]; then
        if valid_snapshot "$STATE_DIR/baseline"; then say '原始配置备份有效：bash bbr.sh restore'
        else fail '原始备份不完整，请核对历史快照，勿盲目覆盖。'; return 1; fi
    fi
    [[ ! -d $STATE_DIR/queue-state ]] || say '存在队列恢复快照：bash bbr.sh queue-restore'
    say '历史记录保留在状态目录的 *-history.* / *-restored.* 下；不会自动选择旧记录覆盖当前配置。'
    say '恢复前仍会核对后续人工修改；换内核中断后先确认启动项，再决定是否重启。'
}
ui_device_menu() {
    local AUTO=1 QUEUE=$QUEUE QUEUE_EXPLICIT=$QUEUE_EXPLICIT
    ensure_dependencies python3 || return $?
    while :; do
        ui_heading '设备自适应（均衡稳定）'
        show_change_plan || { ui_pause; return 1; }
        say '  1  仅预演  2  应用默认 BBR 配置  3  网卡队列配置  0  返回'
        ui_read '请选择 [0-3]' || return 0
        case $UI_INPUT in
            0|q|Q) return 0 ;; 1) ui_preview || : ;;
            2) ui_run '设备自适应 BBR 配置' enable_bbr || : ;;
            3) ui_queue_menu ;; *) warn '无效选择，请输入 0-3。' ;;
        esac
    done
}

# Terminal UI: no extra dependencies; redirected output stays plain text.
UI_BOLD='' UI_CYAN='' UI_GREEN='' UI_YELLOW='' UI_RESET=''
UI_INPUT=''
ui_init() {
    UI_BOLD='' UI_CYAN='' UI_GREEN='' UI_YELLOW='' UI_RESET=''
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
        UI_BOLD=$'\033[1m'; UI_CYAN=$'\033[36m'; UI_GREEN=$'\033[32m'
        UI_YELLOW=$'\033[33m'; UI_RESET=$'\033[0m'
    fi
}
ui_heading() { printf '\n%s%s%s\n' "$UI_BOLD" "$1" "$UI_RESET"; }
ui_read() {
    local prompt=$1 default=${2:-}
    printf '%s' "$prompt" >&2
    if [[ -n $default ]]; then printf ' [%s]' "$default" >&2; fi
    printf '：' >&2
    IFS= read -r UI_INPUT || return 1
    UI_INPUT=${UI_INPUT#"${UI_INPUT%%[![:space:]]*}"}
    UI_INPUT=${UI_INPUT%"${UI_INPUT##*[![:space:]]}"}
    [[ -n $UI_INPUT ]] || UI_INPUT=$default
    return 0
}
ui_pause() {
    [[ -t 0 ]] || return 0
    local _
    printf '\n按回车返回菜单…' >&2
    IFS= read -r _ || return 0
}
ui_run() {
    local title=$1 rc=0
    shift
    ui_heading "$title"
    # Per-action isolation keeps menu parameters and traps out of later actions.
    ( "$@" ) || rc=$?
    if (( rc == 0 )); then
        if (( DRY_RUN )); then printf '\n%s[预演结束]%s 未执行修改或测速。\n' "$UI_GREEN" "$UI_RESET"
        else printf '\n%s[完成]%s %s\n' "$UI_GREEN" "$UI_RESET" "$title"; fi
    else
        printf '\n%s[未完成]%s 退出码 %s；请查看上方原因，处理后可重试。\n' "$UI_YELLOW" "$UI_RESET" "$rc"
    fi
    ui_pause
    return "$rc"
}
ui_overview() {
    detect_system; detect_capabilities
    printf '\n%s------------------------------------------------------------%s\n' "$UI_CYAN" "$UI_RESET"
    printf '%sBBR 管理工具 v%s%s\n' "$UI_BOLD" "$VERSION" "$UI_RESET"
    say "系统：$OS_ID $OS_VERSION / $ARCH   内核：$(uname -r)"
    say "默认 TCP：${CURRENT_CC:-未知}   默认队列：${CURRENT_QDISC:-未知}"
    say '网卡队列与连接详情见状态；完整诊断和手动参数见高级设置。'
    if (( DRY_RUN )); then say '运行模式：预演，不修改系统、不发起测速'
    elif [[ $VIRT == container* ]]; then say '运行模式：容器，不能修改系统；可诊断、预演和测速'
    elif (( ! SUPPORTED )); then say '运行模式：此系统不在适配名单；可诊断、预演和测速'
    elif (( EUID != 0 )); then say '当前权限：普通用户；系统修改需以 root 重新运行'
    else say '当前权限：root；修改前会显示说明并确认'; fi
    if [[ -d $STATE_DIR && ! -x $STATE_DIR ]]; then
        say '备份与恢复记录：当前用户无读取权限'
    else
        [[ ! -d $STATE_DIR/baseline ]] || say '原配置备份：可恢复'
        [[ ! -d $STATE_DIR/transaction ]] || say '待处理：配置事务中断，请进入「恢复与排障 → 原 BBR 配置」'
        [[ ! -d $STATE_DIR/queue.pending ]] || say '待处理：队列事务中断，请进入「恢复与排障 → 原网卡队列」'
        [[ ! -d $STATE_DIR/kernel.pending ]] || say '待处理：内核事务中断，请进入「恢复与排障 → 内核启动项」'
    fi
    printf '%s------------------------------------------------------------%s\n' "$UI_CYAN" "$UI_RESET"
}
ui_ask() {
    local dest=$1 label=$2 kind=$3 default=${4:-} valid
    while :; do
        ui_read "$label（q 返回）" "$default" || return 1
        case $UI_INPUT in q|Q) return 1 ;; esac
        valid=0
        case $kind in
            host) [[ $UI_INPUT =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$ ]] && valid=1 ;;
            interface) [[ $UI_INPUT =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ ]] && valid=1 ;;
            algorithm) [[ $UI_INPUT =~ ^[a-zA-Z0-9_]{1,32}$ ]] && valid=1 ;;
            port|duration|parallel)
                local limit=65535
                [[ $kind != duration ]] || limit=120
                [[ $kind != parallel ]] || limit=16
                if [[ $UI_INPUT =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$UI_INPUT <= limit )); then valid=1; fi ;;
        esac
        if (( valid )); then printf -v "$dest" '%s' "$UI_INPUT"; return 0; fi
        warn '输入格式或范围不正确，请重新输入；输入 q 返回。'
    done
}
ui_preview() { local DRY_RUN=1; ui_run '预演 BBR 配置' enable_bbr; }
ui_kernel_menu() {
    local ACTION='' CHANNEL=distro
    while :; do
        ui_heading '内核管理'
        say '  1  查看已安装内核与计划'
        say '  2  查看安装计划（不修改）'
        say '  3  安装发行版内核'
        say '  4  检查重启后的内核'
        say '  5  中断事务的启动项恢复'
        say '  0  返回主菜单'
        say 'BBRv3 暂无已核验的签名包来源，未开放自动安装。'
        ui_read '请选择 [0-5]' || return 0
        case $UI_INPUT in
            0|q|Q) return 0 ;;
            1) ACTION=list ;; 2) ACTION=plan ;;
            3) ACTION=install
               say '将从官方签名仓库安装；保留旧内核及原默认启动项，不自动重启。' ;;
            4) ACTION=verify ;;
            5) ACTION=recover; say '恢复安装前默认启动项；不会卸载部分安装的软件包。' ;;
            *) warn '无效选择，请输入 0-5。'; continue ;;
        esac
        ui_run '内核操作' kernel_command || :
    done
}
ui_default_interface() {
    has ip && has python3 || return 1
    ip -j route show default 2>/dev/null | python3 -c 'import json,sys,re
try:
 routes=json.load(sys.stdin)
 names=set()
 for r in routes:
  if r.get("dev"):names.add(r["dev"])
  for hop in r.get("nexthops",[]):
   if hop.get("dev"):names.add(hop["dev"])
 if len(names)!=1:sys.exit(1)
 name=next(iter(names))
 if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}",name) or name=="lo":sys.exit(1)
 print(name)
except (ValueError,TypeError,AttributeError):sys.exit(1)'
}

ui_list_interfaces() {
    say '当前可见网卡：'
    if has ip; then
        ip -o link show | awk -F': ' '{sub(/@.*/,"",$2); if ($2!="lo") print "  " $2}' || warn '无法列出网卡，可手动输入。'
    else warn '缺少 ip，可手动输入；实际修改需要 iproute2。'; fi
}
ui_select_queue() {
    local default=1
    case $QUEUE in fq_codel) default=2 ;; cake) default=3 ;; esac
    while :; do
        say '  1  fq（BBR 常用搭配）  2  fq_codel  3  cake  0  返回'
        ui_read '选择队列' "$default" || return 1
        case $UI_INPUT in
            1) QUEUE=fq; QUEUE_EXPLICIT=1; return 0 ;; 2) QUEUE=fq_codel; QUEUE_EXPLICIT=1; return 0 ;; 3) QUEUE=cake; QUEUE_EXPLICIT=1; return 0 ;;
            0|q|Q) return 1 ;; *) warn '无效选择，请输入 0-3。' ;;
        esac
    done
}
ui_queue_menu() {
    local IFACE=$IFACE QUEUE=$QUEUE QUEUE_EXPLICIT=$QUEUE_EXPLICIT
    while :; do
        ui_heading '队列管理'
        say '  1  查看实际队列  2  更换网卡队列  3  恢复原队列  0  返回'
        say '仅修改本次运行；复杂拓扑不自动更换，重启后不自动重建。'
        ui_read '请选择 [0-3]' || return 0
        case $UI_INPUT in
            0|q|Q) return 0 ;;
            1) ui_run '实际网卡队列' inspect_qdiscs || : ;;
            2) ui_list_interfaces
               [[ -n $IFACE ]] || IFACE=$(ui_default_interface 2>/dev/null || :)
               ui_ask IFACE '网卡名称' interface "$IFACE" || continue
               ui_select_queue || continue
               say "将尝试把 $IFACE 的简单根队列更换为 $QUEUE，并保存恢复记录。"
               ui_run '更换网卡队列' set_queue || : ;;
            3) say '核对当前队列与快照后，恢复本脚本此前修改的队列。'
               ui_run '恢复原队列' restore_queue || : ;;
            *) warn '无效选择，请输入 0-3。' ;;
        esac
    done
}
ui_benchmark_custom() {
    local HOST=$HOST PORT=$PORT DURATION=$DURATION STREAMS=$STREAMS
    local REVERSE=0 COMPARE=0 ALGORITHM=$ALGORITHM SUITE=0 STREAMS_EXPLICIT=$STREAMS_EXPLICIT
    ui_heading '性能测试'
    say '需要已获授权的 iperf3 服务端；会产生真实流量，结果取决于测试路径。'
    detect_capabilities
    say "当前可用算法：${AVAILABLE:-无法读取}；对比模式需同时支持 cubic 和 bbr。"
    if [[ ${1:-} != host-ready ]]; then ui_ask HOST '服务端 IP 或域名' host "$HOST" || return 0; fi
    ui_ask PORT '端口 1-65535' port "$PORT" || return 0
    ui_ask DURATION '每轮时长 1-120 秒' duration "$DURATION" || return 0
    ui_ask STREAMS '并发流数 1-16' parallel "$STREAMS" || return 0
    while :; do
        say '  1  正向发送  2  反向接收  3  cubic / bbr 顺序对比'
        say '  4  设备单连接 / 并发套件  0  返回'
        ui_read '选择测试模式' 1 || return 0
        case $UI_INPUT in
            0|q|Q) return 0 ;;
            1) ui_ask ALGORITHM '客户端算法' algorithm "$ALGORITHM" || return 0; break ;;
            2) REVERSE=1; say '反向算法由服务端决定，以实测报告为准。'; break ;;
            3) COMPARE=1; break ;;
            4) load_device_resources || return 1
               ui_ask STREAMS '并发轮次流数 1-16（单连接轮次固定 1）' parallel "$DEVICE_STREAMS" || return 0
               STREAMS_EXPLICIT=1; SUITE=1
               ui_ask ALGORITHM '客户端算法' algorithm "$ALGORITHM" || return 0; break ;;
            *) warn '无效选择，请输入 0-4。' ;;
        esac
    done
    say "测试摘要：$HOST:$PORT，每轮 ${DURATION}s，并发 $STREAMS。"
    if (( COMPARE )); then say '将依次测试 cubic、bbr，共两轮；不修改系统默认算法。'; fi
    if (( SUITE )); then say "将分别进行单连接和 $STREAMS 流测试；并发为 1 时不重复测试。"; fi
    # Testing sends traffic, so give menu users a final chance to return.
    ui_read '回车开始测试，或输入 q 返回' || return 0
    case $UI_INPUT in q|Q) return 0 ;; '') ;; *) warn '未开始测试，请重新选择。'; return 0 ;; esac
    ui_run '性能测试' run_benchmark || :
}
ui_quick_enable() {
    local AUTO=1 QUEUE=$QUEUE QUEUE_EXPLICIT=$QUEUE_EXPLICIT
    ui_run '按设备建议启用 BBR' enable_bbr
}
ui_manual_enable() {
    local AUTO=0 QUEUE=$QUEUE QUEUE_EXPLICIT=1
    ui_heading '手动 BBR 配置'
    ui_select_queue || return 0
    ui_run '启用手动 BBR 配置' enable_bbr
}
ui_benchmark_menu() {
    local HOST=$HOST PORT=$PORT DURATION=$DURATION STREAMS=$STREAMS
    local AUTO=1 SUITE=1 REVERSE=0 COMPARE=0 ALGORITHM=$ALGORITHM
    local STREAMS_EXPLICIT=$STREAMS_EXPLICIT recommended=1
    detect_capabilities
    if (( ! ALGORITHM_EXPLICIT )) && valid_value "$CURRENT_CC" && contains_word "$AVAILABLE" "$CURRENT_CC"; then ALGORITHM=$CURRENT_CC; fi
    ui_heading '测速'
    ui_ask HOST 'iperf3 服务端 IP 或域名' host "$HOST" || return 0
    ensure_dependencies python3 || return $?
    if load_device_resources; then
        recommended=$DEVICE_STREAMS
        (( STREAMS_EXPLICIT )) || STREAMS=$recommended
    else
        warn '设备信息不完整，快捷测试使用单组参数；仍可选择自定义。'
        AUTO=0; SUITE=0
        (( STREAMS_EXPLICIT )) || STREAMS=1
    fi
    while :; do
        if (( SUITE && STREAMS > 1 )); then
            say "默认：单连接 + $STREAMS 流两轮，每轮 ${DURATION}s，端口 $PORT，算法 $ALGORITHM。"
        else say "默认：并发 $STREAMS，每轮 ${DURATION}s，端口 $PORT，算法 $ALGORITHM。"; fi
        say '会产生真实流量；a 可调整端口、时长、算法、方向、并发和测试模式。'
        ui_read '回车开始 / a 自定义 / q 返回' || return 0
        case $UI_INPUT in
            '') ui_run '测速' run_benchmark || :; return 0 ;;
            a|A) ui_benchmark_custom host-ready; return $? ;;
            q|Q|0) return 0 ;;
            *) warn '无效选择，请回车开始，或输入 a / q。' ;;
        esac
    done
}
ui_recovery_menu() {
    local ACTION='' CHANNEL=distro
    while :; do
        ui_heading '恢复与排障'
        recovery_center || :
        say '  1  恢复原 BBR 配置'
        say '  2  恢复原网卡队列'
        say '  3  恢复内核启动项'
        say '  0  返回'
        ui_read '请选择 [0-3]' || return 0
        case $UI_INPUT in
            0|q|Q) return 0 ;;
            1) ui_run '恢复原 BBR 配置' restore_state || : ;;
            2) ui_run '恢复原网卡队列' restore_queue || : ;;
            3) ACTION=recover; ui_run '恢复内核启动项' kernel_command || : ;;
            *) warn '无效选择，请输入 0-3。' ;;
        esac
    done
}
ui_advanced_menu() {
    while :; do
        ui_heading '高级设置'
        say '  1  手动 BBR 配置       2  完整诊断'
        say '  3  内核管理           4  网卡队列管理'
        say '  5  设备方案详情       6  仅预演 BBR 配置'
        say '  7  全部命令行用法     8  比较历史测速结果'
        say '  0  返回'
        ui_read '请选择 [0-8]' || return 0
        case $UI_INPUT in
            0|q|Q) return 0 ;;
            1) ui_manual_enable || : ;;
            2) ui_run '完整诊断' doctor || : ;;
            3) ui_kernel_menu ;;
            4) ui_queue_menu ;;
            5) ui_device_menu || : ;;
            6) ui_preview || : ;;
            7) ui_run '全部命令行用法' usage || : ;;
            8) ui_compare_results ;;
            *) warn '无效选择，请输入 0-8。' ;;
        esac
    done
}
menu() {
    while :; do
        ui_overview
        say '  1  一键按设备启用 BBR（推荐）'
        say '  2  查看状态'
        say '  3  测速'
        say '  4  恢复与排障'
        say '  5  高级设置（全部功能）'
        say '  0  退出       r  刷新'
        ui_read '请选择 [0-5 / r]' || { say ''; return 0; }
        case $UI_INPUT in
            0|q|Q) say '已退出。'; return 0 ;;
            1) ui_quick_enable || : ;;
            2) ui_run '状态详情' show_status || : ;;
            3) ui_benchmark_menu ;;
            4) ui_recovery_menu ;;
            5) ui_advanced_menu ;;
            r|R) continue ;;
            *) warn '无效选择，请输入 0-5，或 r 刷新。' ;;
        esac
    done
}

# Validate the complete path chain before root writes. No symlinks or writable
# group/other components, including ancestors, are accepted.
secure_path() {
    local path=$1 mode owner
    [[ $path == /* ]] || { fail '路径必须是绝对路径'; return 1; }
    while [[ $path != / ]]; do
        [[ ! -L $path ]] || { fail "拒绝符号链接：$path"; return 1; }
        if [[ -e $path ]]; then
            owner=$(stat -c %u -- "$path") || return 1
            mode=$(stat -c %a -- "$path") || return 1
            if [[ $owner != 0 ]] || (( (8#$mode & 0022) != 0 )); then
                fail "路径必须由 root 所有且不可被其他用户写入：$path"; return 1
            fi
        fi
        path=${path%/*}; [[ -n $path ]] || path=/
    done
}
prepare_state() {
    secure_path "$STATE_DIR" || return 1
    [[ -d ${STATE_DIR%/*} ]] || { fail '状态目录父路径不存在'; return 1; }
    [[ -d $STATE_DIR ]] || mkdir -m 700 -- "$STATE_DIR" || return 1
    secure_path "$STATE_DIR" || return 1
}
acquire_lock() {
    has flock || { fail '缺少 flock，请安装 util-linux 后再执行修改。'; return 1; }
    secure_path "$STATE_DIR/operations.lock" || return 1
    exec 9>"$STATE_DIR/operations.lock" || return 1
    flock -n 9 || { fail '另一个修改操作正在运行。'; return 1; }
}
log_event() {
    secure_path "$LOG" || return 1
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"
}
CONF_DIRS=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d)
SYSCTL_CONF=/etc/sysctl.conf
detect_conflicts() {
    local file output found=0 number pattern line value expected
    local target_cc=${1:-bbr} target_qd=${2:-$QUEUE}
    local -a files=("$SYSCTL_CONF")
    for file in "${CONF_DIRS[@]}"; do [[ ! -d $file ]] || files+=("$file"/*.conf); done
    for file in "${files[@]}"; do
        [[ $file != "$CONFIG" && -f $file ]] || continue
        output=$(awk '
            /^[[:space:]]*[#;]/ {next}
            index($0,"=") {
                key=substr($0,1,index($0,"=")-1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                sub(/^-[[:space:]]*/, "", key)
                gsub(/\//, ".", key)
                if (length(key)) print FNR "\t" key "\t" $0
            }' "$file") || return 1
        while IFS=$'\t' read -r number pattern line; do
            [[ -n $pattern ]] || continue
            # RHS intentionally unquoted: sysctl.d accepts shell-style globs.
            # shellcheck disable=SC2053 # Match sysctl glob assignments deliberately.
            if [[ net.core.default_qdisc == $pattern || net.ipv4.tcp_congestion_control == $pattern ]]; then
                # Literal assignments already matching the requested value are
                # compatible. Keep globs and ambiguous values conservative.
                value=${line#*=}
                value=${value#"${value%%[![:space:]]*}"}
                value=${value%"${value##*[![:space:]]}"}
                expected=''
                case $pattern in
                    net.core.default_qdisc) expected=$target_qd ;;
                    net.ipv4.tcp_congestion_control) expected=$target_cc ;;
                esac
                if [[ -n $expected && $value == "$expected" ]]; then continue; fi
                warn "配置冲突 $file:$number：$line"; found=1
            fi
        done <<< "$output"
    done
    (( found == 0 )) || { fail '请先手动处理以上冲突，本脚本不删除其他文件的参数。'; return 1; }
}
valid_value() { [[ $1 =~ ^[a-zA-Z0-9_]{1,32}$ ]]; }
read_pair() {
    PAIR_CC=$(sys_value net.ipv4.tcp_congestion_control) || return 1
    PAIR_QD=$(sys_value net.core.default_qdisc) || return 1
    if ! valid_value "$PAIR_CC" || ! valid_value "$PAIR_QD"; then fail '无法可靠读取运行参数'; return 1; fi
}
ensure_modules() {
    detect_capabilities
    if ! contains_word "$AVAILABLE" bbr; then
        ensure_dependencies modprobe || return $?
        modprobe tcp_bbr || { fail '无法加载 tcp_bbr，当前内核可能不支持。'; return 1; }
        detect_capabilities
        contains_word "$AVAILABLE" bbr || { fail '加载后仍没有 bbr'; return 1; }
    fi
    ensure_queue_module
}
ensure_queue_module() {
    # A registered default or live qdisc proves support, even when modules and
    # kernel build config are not shipped in a minimal/cloud image.
    local current config option kernel
    current=$(sys_value net.core.default_qdisc || :)
    [[ $current != "$QUEUE" ]] || return 0
    if has tc && tc qdisc show 2>/dev/null | awk -v queue="$QUEUE" '$1=="qdisc" && $2==queue {found=1} END {exit !found}'; then return 0; fi
    if has modprobe && modprobe "sch_$QUEUE" 2>/dev/null; then return 0; fi
    kernel=$(uname -r) || return 1
    option="CONFIG_NET_SCH_${QUEUE^^}"
    for config in "/boot/config-$kernel" "/lib/modules/$kernel/config" "/lib/modules/$kernel/build/.config"; do
        if [[ -r $config ]] && grep -qx "$option=y" "$config"; then return 0; fi
    done
    if [[ -r /proc/config.gz ]] && has zgrep && zgrep -qx "$option=y" /proc/config.gz; then return 0; fi
    if ! has modprobe; then
        ensure_dependencies modprobe || return $?
        modprobe "sch_$QUEUE" 2>/dev/null && return 0
    fi
    fail "不能确认 $QUEUE 已注册、内置或可加载；请安装当前内核的匹配模块。"
}

snapshot_state() {
    local dest=$1
    mkdir -m 700 -- "$dest" || return 1
    if [[ -e $CONFIG ]]; then
        cp -p -- "$CONFIG" "$dest/before.conf" || return 1
    else
        : > "$dest/before.absent" || return 1
    fi
    read_pair || return 1
    printf '%s\n' "$PAIR_CC" > "$dest/before.cc" || return 1
    printf '%s\n' "$PAIR_QD" > "$dest/before.qd"
}
render_config() {
    printf '# Managed by bbr.sh; use restore before editing.\nnet.core.default_qdisc = %s\nnet.ipv4.tcp_congestion_control = %s\n' "$2" "$1"
}
check_managed_file() {
    [[ ! -L $CONFIG ]] || { fail '配置路径是符号链接'; return 1; }
    if [[ -e $STATE_DIR/applied.conf ]]; then
        if [[ ! -f $CONFIG ]] || ! cmp -s -- "$CONFIG" "$STATE_DIR/applied.conf"; then
            fail '配置已被外部修改；保留现场，请手动核对备份。'; return 1
        fi
    elif [[ -e $CONFIG ]]; then
        fail "配置文件已存在但不属于本脚本的有效事务：$CONFIG"; return 1
    fi
}
atomic_copy() {
    local src=$1 dest=$2 temp
    secure_path "$dest" || return 1
    temp=$(mktemp "${dest}.tmp.XXXXXXXX") || return 1
    if ! cat -- "$src" > "$temp" || ! chmod 600 -- "$temp" || ! sync -f "$temp" || ! mv -fT -- "$temp" "$dest"; then
        rm -f -- "$temp"; return 1
    fi
}
valid_snapshot() {
    local dir=$1 cc qd
    [[ -d $dir && ! -L $dir ]] || return 1
    cc=$(cat "$dir/before.cc") || return 1
    qd=$(cat "$dir/before.qd") || return 1
    valid_value "$cc" && valid_value "$qd" || return 1
    if [[ -f $dir/before.absent && ! -e $dir/before.conf ]]; then return 0; fi
    [[ -f $dir/before.conf && ! -e $dir/before.absent ]]
}
replace_baseline() {
    local src=${1:-} staged='' history
    # Stage a complete replacement before moving the old directory. Journals
    # remain intact if either rename fails, so recovery can safely retry.
    if [[ -n $src ]]; then
        valid_snapshot "$src" || { fail '原始状态快照不完整，保留恢复事务'; return 1; }
        staged=$(mktemp -d "$STATE_DIR/baseline-stage.XXXXXXXX") || return 1
        cp -a -- "$src" "$staged/data" || return 1
        valid_snapshot "$staged/data" || return 1
        sync -f "$staged" || return 1
    fi
    if [[ -e $STATE_DIR/baseline || -L $STATE_DIR/baseline ]]; then
        [[ -d $STATE_DIR/baseline && ! -L $STATE_DIR/baseline ]] || { fail '原始备份路径异常'; return 1; }
        history=$(mktemp -d "$STATE_DIR/baseline-history.XXXXXXXX") || return 1
        mv -T -- "$STATE_DIR/baseline" "$history/previous" || return 1
    fi
    if [[ -n $staged ]]; then
        mv -T -- "$staged/data" "$STATE_DIR/baseline" || return 1
        rmdir -- "$staged" || return 1
    fi
    sync -f "$STATE_DIR"
}

begin_transaction() {
    local cc=$1 qd=$2 kind=${3:-enable}
    TX_DIR="$STATE_DIR/transaction"
    [[ ! -e $TX_DIR ]] || { fail '存在未完成事务，请先运行 restore 恢复。'; return 1; }
    local temp
    temp=$(mktemp -d "$STATE_DIR/journal.XXXXXXXX") || return 1
    # Construct journal fully before publishing it; no changes before this point.
    if ! snapshot_state "$temp/snapshot"; then rm -rf -- "$temp"; return 1; fi
    local name
    for name in applied.conf applied.qd; do
        if [[ -f $STATE_DIR/$name ]]; then cp -p -- "$STATE_DIR/$name" "$temp/previous.$name" || return 1
        else : > "$temp/absent.$name" || return 1; fi
    done
    if [[ -e $STATE_DIR/baseline || -L $STATE_DIR/baseline ]]; then
        valid_snapshot "$STATE_DIR/baseline" || { fail '原始备份损坏，请先核对历史恢复记录'; return 1; }
        cp -a -- "$STATE_DIR/baseline" "$temp/baseline" || return 1
    else : > "$temp/baseline.absent" || return 1; fi
    printf '%s\n' "$cc" > "$temp/target.cc" || return 1
    printf '%s\n' "$qd" > "$temp/target.qd" || return 1
    printf '%s\n' "$kind" > "$temp/kind" || return 1
    if [[ $kind == restore ]]; then
        if [[ -e $STATE_DIR/baseline/before.absent ]]; then : > "$temp/after.absent" || return 1
        else cp -- "$STATE_DIR/baseline/before.conf" "$temp/after.conf" || return 1; fi
    else render_config "$cc" "$qd" > "$temp/after.conf" || return 1; fi
    sync -f "$temp" || return 1
    mv -T -- "$temp" "$TX_DIR" || return 1
    TX_ACTIVE=1
    trap 'transaction_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    sync -f "$STATE_DIR" || return 1
}
write_managed_config() {
    if [[ -e $TX_DIR/after.absent ]]; then rm -f -- "$CONFIG"
    else atomic_copy "$TX_DIR/after.conf" "$CONFIG"; fi
}
set_pair() {
    sysctl -w "net.core.default_qdisc=$2" || return 1
    sysctl -w "net.ipv4.tcp_congestion_control=$1" || return 1
    read_pair || return 1
    [[ $PAIR_CC == "$1" && $PAIR_QD == "$2" ]] || { fail '运行值校验失败'; return 1; }
}
archive_transaction() {
    local history
    history=$(mktemp -d "$STATE_DIR/transaction-history.XXXXXXXX") || return 1
    # Atomic rename commits/archives the journal. Never recursively delete an
    # active recovery journal: interrupted unlink could destroy recovery data.
    mv -T -- "$TX_DIR" "$history/journal" || return 1
    TX_ACTIVE=0
    sync -f "$STATE_DIR" || warn '归档已完成，但文件系统同步失败，请核对磁盘状态。'
}
rollback_transaction() {
    [[ -d $TX_DIR && ! -L $TX_DIR ]] || return 1
    local cc qd target_cc target_qd
    cc=$(cat "$TX_DIR/snapshot/before.cc") || return 1
    qd=$(cat "$TX_DIR/snapshot/before.qd") || return 1
    target_cc=$(cat "$TX_DIR/target.cc") || return 1
    target_qd=$(cat "$TX_DIR/target.qd") || return 1
    valid_value "$cc" && valid_value "$qd" && valid_value "$target_cc" && valid_value "$target_qd" || return 1
    read_pair || return 1
    [[ $PAIR_CC == "$cc" || $PAIR_CC == "$target_cc" ]] &&
        [[ $PAIR_QD == "$qd" || $PAIR_QD == "$target_qd" ]] || { fail '事务后运行参数有外部修改，拒绝覆盖。'; return 1; }
    [[ ! -L $CONFIG ]] || return 1
    if [[ -e $CONFIG ]]; then
        cmp -s "$CONFIG" "$TX_DIR/after.conf" || cmp -s "$CONFIG" "$TX_DIR/snapshot/before.conf" || {
            fail '事务后配置有外部修改，拒绝覆盖。'; return 1;
        }
    elif [[ ! -e $TX_DIR/after.absent && ! -e $TX_DIR/snapshot/before.absent ]]; then
        fail '事务配置文件丢失，拒绝猜测恢复'; return 1
    fi
    if [[ -e $TX_DIR/snapshot/before.absent ]]; then rm -f -- "$CONFIG" || return 1
    else atomic_copy "$TX_DIR/snapshot/before.conf" "$CONFIG" || return 1; fi
    set_pair "$cc" "$qd" || return 1
    local name
    for name in applied.conf applied.qd; do
        if [[ -f $TX_DIR/previous.$name ]]; then atomic_copy "$TX_DIR/previous.$name" "$STATE_DIR/$name" || return 1
        elif [[ -f $TX_DIR/absent.$name ]]; then rm -f -- "$STATE_DIR/$name" || return 1
        else fail '事务元数据不完整，保留现场'; return 1; fi
    done
    if [[ -d $TX_DIR/baseline ]]; then
        replace_baseline "$TX_DIR/baseline" || return 1
    elif [[ -f $TX_DIR/baseline.absent ]]; then
        replace_baseline '' || return 1
    else fail '事务缺少原始备份记录，保留现场'; return 1; fi
    sync -f "$STATE_DIR" || return 1
    archive_transaction || return 1
    warn '已恢复此事务之前的配置和运行参数；已加载模块不强行卸载。'
}
transaction_exit() {
    local rc=$1
    if (( TX_ACTIVE )); then
        warn '事务未完成，尝试恢复。'
        rollback_transaction || { warn "自动恢复未完成；保留 $TX_DIR，请检查后运行 restore。"; rc=1; }
        (( rc != 0 )) || rc=1
    fi
    trap - EXIT
    exit "$rc"
}
finish_transaction() {
    local kind=$1
    if [[ $kind == enable ]]; then
        if [[ ! -f $TX_DIR/previous.applied.conf ]]; then
            # A failed first attempt (including older script versions) must not
            # define the baseline of a later successful activation.
            replace_baseline "$TX_DIR/snapshot" || return 1
        fi
        atomic_copy "$CONFIG" "$STATE_DIR/applied.conf" || return 1
        printf '%s\n' "$QUEUE" > "$TX_DIR/new.applied.qd" || return 1
        atomic_copy "$TX_DIR/new.applied.qd" "$STATE_DIR/applied.qd" || return 1
    else
        replace_baseline '' || return 1
        rm -f -- "$STATE_DIR/applied.conf" "$STATE_DIR/applied.qd" || return 1
    fi
    sync -f "$STATE_DIR" || return 1
    archive_transaction || return 1
    trap - EXIT INT TERM HUP
    log_event "$kind completed" || warn '操作成功，但日志记录失败。'
}
enable_bbr() ( enable_bbr_impl )
enable_bbr_impl() {
    ensure_dependencies sysctl flock awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat || return $?
    if (( AUTO )); then ensure_dependencies python3 || return $?; fi
    apply_device_defaults || return 1
    detect_system; detect_capabilities
    if (( DRY_RUN )); then
        say "预演：检查 bbr 与 sch_$QUEUE；备份到 $STATE_DIR；写入 $CONFIG。"
        say "将设置新连接默认 bbr 和新队列默认 $QUEUE；不替换当前网卡队列，不重启。"
        say "平台：$OS_ID $OS_VERSION $ARCH；虚拟化：$VIRT；可用：$AVAILABLE"
        detect_conflicts || return 1
        return 0
    fi
    say "变更预览：默认算法 ${CURRENT_CC:-未知} → bbr；默认队列 ${CURRENT_QDISC:-未知} → $QUEUE。"
    (( ! AUTO )) || show_change_plan || return 1
    require_mutation || return 1
    prepare_state && acquire_lock || return 1
    secure_path "$CONFIG" && secure_path "$LOG" || return 1
    [[ ! -e $STATE_DIR/transaction ]] || { fail '存在未完成事务，请运行 restore。'; return 1; }
    check_managed_file && detect_conflicts && ensure_modules || return 1
    read_pair || return 1
    if [[ -f $STATE_DIR/applied.conf && -f $STATE_DIR/applied.qd && $PAIR_CC == bbr && $PAIR_QD == "$QUEUE" ]] &&
        [[ $(cat "$STATE_DIR/applied.qd") == "$QUEUE" ]] && cmp -s "$CONFIG" <(render_config bbr "$QUEUE"); then
        valid_snapshot "$STATE_DIR/baseline" || { fail '原始备份不完整，拒绝跳过检查'; return 1; }
        say '当前运行参数和本脚本持久配置已一致，无需重复修改。'; return 0
    fi
    begin_transaction bbr "$QUEUE" || return 1
    log_event "enable begin qdisc=$QUEUE" || return 1
    write_managed_config && set_pair bbr "$QUEUE" || return 1
    finish_transaction enable || return 1
    say 'BBR 默认配置已启用并读回校验；实际网卡队列保持原状。'
    say '可运行 doctor 检查 socket；已有连接/监听 socket 不保证切换。'
}
restore_state() ( restore_state_impl )
restore_state_impl() {
    if (( DRY_RUN )); then say "预演：检查并恢复 $STATE_DIR 中的原配置与运行参数；不会删除其他配置。"; return 0; fi
    ensure_dependencies sysctl flock awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat || return $?
    detect_system; require_mutation recovery || return 1
    prepare_state && acquire_lock || return 1
    secure_path "$CONFIG" && secure_path "$LOG" || return 1
    TX_DIR="$STATE_DIR/transaction"
    if [[ -d $TX_DIR ]]; then
        rollback_transaction || return 1
        log_event 'recovered interrupted transaction' || return 1
        say '已恢复中断事务前的状态；如需恢复第一次启用前状态，再运行 restore。'
        return 0
    fi
    [[ -d $STATE_DIR/baseline ]] || { say '没有可恢复的原始状态。'; return 0; }
    check_managed_file || return 1
    local cc qd applied_qd
    cc=$(cat "$STATE_DIR/baseline/before.cc") || return 1
    qd=$(cat "$STATE_DIR/baseline/before.qd") || return 1
    valid_value "$cc" && valid_value "$qd" || return 1
    detect_conflicts "$cc" "$qd" || return 1
    read_pair || return 1
    # Failed enable may leave a baseline with no applied state: it is already original.
    if [[ ! -f $STATE_DIR/applied.conf ]]; then
        [[ $PAIR_CC == "$cc" && $PAIR_QD == "$qd" ]] || { fail '运行参数已改变，拒绝覆盖'; return 1; }
        say '原状态未改变，无需恢复。'; return 0
    fi
    applied_qd=$(cat "$STATE_DIR/applied.qd") || return 1
    [[ $PAIR_CC == bbr && $PAIR_QD == "$applied_qd" ]] || { fail '运行参数已被外部修改，拒绝覆盖。'; return 1; }
    begin_transaction "$cc" "$qd" restore || return 1
    log_event 'restore begin' || return 1
    write_managed_config && set_pair "$cc" "$qd" || return 1
    finish_transaction restore || return 1
    say '已恢复原配置与原运行参数；备份已归档，未修改其他网络设置。'
}

probe_tcp() {
    has python3 || { fail '需要 python3 才能读取新建 TCP socket 的算法。'; return 1; }
    python3 - <<'PY'
import socket, sys
try:
    with socket.socket() as server, socket.socket() as client:
        server.settimeout(3); client.settimeout(3)
        server.bind(('127.0.0.1',0)); server.listen(1)
        client.connect(server.getsockname())
        conn,_=server.accept()
        with conn:
            conn.settimeout(3)
            client.sendall(b'bbr-probe')
            payload=b''
            while len(payload)<9:
                chunk=conn.recv(9-len(payload))
                if not chunk: raise RuntimeError('loopback connection closed early')
                payload+=chunk
            if payload!=b'bbr-probe': raise RuntimeError('loopback payload mismatch')
            opt=socket.TCP_CONGESTION
            def cc(s): return s.getsockopt(socket.IPPROTO_TCP,opt,64).split(b'\0')[0].decode('ascii')
            print('新建 TCP socket 实测：client=%s listener=%s accepted=%s' % (cc(client),cc(server),cc(conn)))
except (OSError, AttributeError, RuntimeError) as e:
    print('socket 检查失败：'+str(e), file=sys.stderr);sys.exit(1)
PY
}
verify_defaults() {
    detect_capabilities
    [[ $CURRENT_CC == bbr ]] || { fail '当前默认算法不是 bbr'; return 1; }
    say "运行默认值校验：bbr / $CURRENT_QDISC（不代表当前网卡队列）"
}
doctor() {
    local rc=0 tool
    show_status || rc=1
    say '开发/管理依赖：'
    for tool in sysctl flock ip tc modprobe python3; do
        if has "$tool"; then say "  $tool: 可用"; else warn "缺少 $tool"; fi
    done
    probe_tcp || rc=1
    if has ss; then say '现有 TCP 连接（算法与统计由 ss 输出）：'; ss -tin || rc=1; fi
    detect_conflicts || rc=1
    return "$rc"
}
# Print one tc argument per line; no eval and no shell-generated commands.
# Unknown options/topologies are refused instead of approximated on restoration.
queue_restore_args() {
    has python3 || { fail '队列事务需要 python3'; return 1; }
    python3 /dev/fd/3 3<<'PY'
import json,sys
try:
    q=json.load(sys.stdin)
    if not isinstance(q,list) or len(q)!=1 or not isinstance(q[0],dict):raise ValueError('队列结构不合法')
    if set(q[0])-{'kind','handle','root','refcnt','options'}:raise ValueError('存在共享 block、卸载或未知拓扑属性，不能可靠恢复')
    if not q[0].get('root') or q[0].get('kind')!='fq_codel':
        raise ValueError('仅可恢复单个 fq_codel 根队列；其他拓扑只诊断')
    options=q[0].get('options',{})
    supported={'limit','flows','quantum','target','interval','memory_limit','ecn','drop_batch','ce_threshold'}
    required={'limit','flows','quantum','target','interval','memory_limit'}
    if set(options)-supported or not required.issubset(options):
        raise ValueError('队列选项未知或不完整，不能可靠恢复')
    options=dict(options)
    options.setdefault('ecn',False)  # tc omits this field when ECN is disabled.
    handle=q[0].get('handle','0:')
    import re
    if not re.fullmatch(r'[0-9a-fA-F]{1,4}:',handle): raise ValueError('不支持的 handle')
    out=(['handle',handle] if int(handle[:-1],16) else [])+['fq_codel']
    for key,val in options.items():
        if key=='ecn':
            if type(val) is not bool: raise ValueError('ecn 类型不合法')
            out.append('ecn' if val else 'noecn')
        else:
            if type(val) is not int or val<0: raise ValueError('队列数值不合法')
            if key in ('target','interval','ce_threshold'):
                candidate=val if val%128==0 else val+1
                if ((candidate*1000>>10)<<10)//1000 != val: raise ValueError('时间值无法精确还原')
                val=candidate
            unit='us' if key in ('target','interval','ce_threshold') else ('b' if key=='memory_limit' else '')
            out.extend([key,str(val)+unit])
    print('\n'.join(out))
except (ValueError,TypeError,KeyError) as e:
    print('队列检查失败：'+str(e),file=sys.stderr);sys.exit(1)
PY
}
queue_signature() {
    python3 /dev/fd/3 3<<'PY'
import json,sys
try:
    q=json.load(sys.stdin)
    print(json.dumps([{'kind':x['kind'],'root':x.get('root',False),'parent':x.get('parent'),
                       'handle':x.get('handle'),'options':x.get('options',{})} for x in q],sort_keys=True))
except (ValueError,KeyError,TypeError) as e:
    print(e,file=sys.stderr);sys.exit(1)
PY
}
read_queue() {
    has tc || { fail '需要 tc（iproute2）读取队列快照'; return 1; }
    tc -j qdisc show dev "$1" || {
        fail '无法读取队列 JSON 快照，请检查网卡及 iproute2 的 JSON 支持；仅查看可使用 status。'; return 1;
    }
}
queue_matches() {
    read_queue "$1" | python3 /dev/fd/3 "$2" 3<<'PY'
import json,sys
try:
    current=json.load(sys.stdin); saved=json.load(open(sys.argv[1]))
    def signature(q,ignore):
        out=[]
        for x in q:
            item={k:x.get(k) for k in ('kind','root','parent','options')}
            if x.get('kind')=='fq_codel':
                item['options']=dict(x.get('options',{}));item['options'].setdefault('ecn',False)
            if not ignore:item['handle']=x.get('handle')
            out.append(item)
        return out
    ignore=len(saved)==1 and saved[0].get('handle')=='0:'
    sys.exit(signature(current,ignore)!=signature(saved,ignore))
except (ValueError,OSError,TypeError,KeyError):sys.exit(1)
PY
}
rollback_queue() {
    local dir=$1 iface
    iface=$(cat "$dir/interface") || return 1
    [[ $iface =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ ]] || return 1
    if queue_matches "$iface" "$dir/before.json"; then :
    elif [[ -f $dir/after.json ]] && queue_matches "$iface" "$dir/after.json"; then
        ensure_no_queue_filters "$iface" || return 1
        local -a args
        mapfile -t args < "$dir/before.args"
        tc qdisc replace dev "$iface" root "${args[@]}" || return 1
        queue_matches "$iface" "$dir/before.json" || { fail '队列恢复后校验失败'; return 1; }
    else
        fail "队列与已知快照不一致，拒绝覆盖；原始参数在 $dir/before.args"; return 1
    fi
    local history
    history=$(mktemp -d "$STATE_DIR/queue-restored.XXXXXXXX") || return 1
    mv -- "$dir" "$history/snapshot" || return 1
    say "已恢复 $iface 原队列；仅本次运行生效，未修改启动服务。"
}
queue_exit() {
    local rc=$1
    if (( QUEUE_ACTIVE )); then
        warn '队列操作中断，尝试恢复。'
        rollback_queue "$STATE_DIR/queue.pending" || warn "未能自动恢复，请检查 $STATE_DIR/queue.pending 后运行 queue-restore。"
        (( rc != 0 )) || rc=1
    fi
    trap - EXIT; exit "$rc"
}
ensure_no_queue_filters() {
    local filters iface=${1:-$IFACE}
    [[ $iface =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ ]] || { fail '检查 filter 的网卡名称不合法'; return 1; }
    filters=$(tc -j filter show dev "$iface" root) || { fail '无法读取 tc filter，拒绝修改可能不完整的队列拓扑'; return 1; }
    python3 -c 'import json,sys
try:
 data=json.load(sys.stdin)
 if not isinstance(data,list) or data: raise ValueError("存在 filter/classifier 或未知过滤器结构，不能可靠恢复")
except (ValueError,TypeError) as e:
 print("队列 filter 检查失败："+str(e),file=sys.stderr);sys.exit(1)' <<< "$filters"
}
queue_target_plan() {
    if (( AUTO )); then
        load_device_resources || return 1
        (( DEVICE_BUDGET >= 1048576 )) || { fail '设备可用内存不足，保留原队列，请释放资源后重试'; return 1; }
    fi
    python3 /dev/fd/3 "$QUEUE" "$AUTO" "$DEVICE_BUDGET" 3<<'PY'
import json,sys
try:
    links=json.load(sys.stdin)
    if not isinstance(links,list) or len(links)!=1:raise ValueError('无法唯一确定网卡')
    link=links[0];mtu=link['mtu'];kind=sys.argv[1]
    if type(mtu) is not int or not 68<=mtu<=1000000:raise ValueError('MTU 不合法')
    args=['handle','bbf0:',kind]
    # Explicit values avoid Ethernet/tunnel hard_header_len differences.
    if kind=='fq':args+=['quantum',str(2*mtu),'initial_quantum',str(10*mtu)]
    elif kind=='fq_codel':args+=['quantum',str(mtu)]
    elif kind=='cake':
        info=link.get('linkinfo',{})
        if link.get('link_type')!='ether' or info.get('info_kind') not in (None,'veth','dummy'):
            raise ValueError('cake 自动更换只开放已验证的普通 Ethernet 类型；可使用 fq/fq_codel')
    else:raise ValueError('不支持的队列')
    if sys.argv[2]=='1':
        budget=int(sys.argv[3])
        if kind=='fq':
            limit=max(64,min(10000,budget//4096));args+=['limit',str(limit),'flow_limit',str(min(100,limit))]
        elif kind=='fq_codel':args+=['memory_limit',str(budget)+'b']
        elif kind=='cake':args+=['memlimit',str(budget)+'b']
    print(mtu);print('\n'.join(args))
except (ValueError,TypeError,KeyError,AttributeError) as e:
    print('目标队列预检失败：'+str(e),file=sys.stderr);sys.exit(1)
PY
}
prepare_queue_target() {
    local dest=$1 plan mtu
    local -a lines args
    has unshare || { fail '需要 util-linux unshare 预先验证目标队列'; return 1; }
    plan=$(ip -j link show dev "$IFACE" | queue_target_plan) || return 1
    mapfile -t lines <<< "$plan"
    mtu=${lines[0]}; args=("${lines[@]:1}")
    printf '%s\n' "${args[@]}" > "${dest%/*}/target.args" || return 1
    # shellcheck disable=SC2016 # Parameters expand inside the isolated shell.
    unshare --net -- bash -c '
        set -eu
        ip link add bbr-probe type dummy
        ip link set dev bbr-probe mtu "$1"
        ip link set dev bbr-probe up
        shift
        tc qdisc replace dev bbr-probe root "$@"
        tc -j qdisc show dev bbr-probe
    ' bbr-probe "$mtu" "${args[@]}" > "$dest" || {
        fail '无法在临时网络命名空间验证目标队列；真实网卡保持原状'; return 1;
    }
    queue_signature < "$dest" >/dev/null || return 1
    sync -f "$dest"
}

set_queue() ( set_queue_impl )
set_queue_impl() {
    ensure_dependencies python3 ip tc unshare flock || return $?
    [[ -n $IFACE ]] || { fail '请指定 --interface 网卡'; return 2; }
    apply_device_defaults || return 1
    if (( DRY_RUN )); then
        (( ! AUTO )) || show_queue_plan || return 1
        say "预演：检查 $IFACE 的简单根队列，备份完整可恢复选项，替换为 $QUEUE。"
        say 'mq/复杂或未知队列拒绝修改；仅影响本次运行，重启后需重新显式操作。'
        return 0
    fi
    (( ! AUTO )) || show_queue_plan || return 1
    detect_system; require_mutation || return 1
    if ! has tc || ! has ip || ! has python3; then fail '需要 iproute2 和 python3'; return 1; fi
    ip link show dev "$IFACE" >/dev/null || return 1
    [[ $IFACE != lo ]] || { fail '不修改 loopback 队列'; return 1; }
    prepare_state && acquire_lock || return 1
    [[ ! -e $STATE_DIR/queue.pending && ! -e $STATE_DIR/queue-state ]] || { fail '请先 queue-restore 恢复已有队列事务'; return 1; }
    local temp
    temp=$(mktemp -d "$STATE_DIR/queue-preflight.XXXXXXXX") || return 1
    if ! read_queue "$IFACE" > "$temp/before.json" || ! queue_restore_args < "$temp/before.json" > "$temp/before.args"; then
        rm -rf -- "$temp"; return 1
    fi
    ensure_no_queue_filters || { rm -rf -- "$temp"; return 1; }
    printf '%s\n' "$IFACE" > "$temp/interface" || return 1
    ensure_queue_module || { rm -rf -- "$temp"; return 1; }
    prepare_queue_target "$temp/after.json" || { rm -rf -- "$temp"; return 1; }
    sync -f "$temp" || return 1
    if ! queue_matches "$IFACE" "$temp/before.json" || ! ensure_no_queue_filters; then fail '预检期间队列或过滤器发生变化，停止修改'; return 1; fi
    log_event "queue begin interface=$IFACE qdisc=$QUEUE" || return 1
    mv -T -- "$temp" "$STATE_DIR/queue.pending" || return 1
    QUEUE_ACTIVE=1
    trap 'queue_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    sync -f "$STATE_DIR" || return 1
    local -a target_args
    mapfile -t target_args < "$STATE_DIR/queue.pending/target.args" || return 1
    (( ${#target_args[@]} > 0 )) || { fail '目标队列参数缺失，保留事务'; return 1; }
    tc qdisc replace dev "$IFACE" root "${target_args[@]}" || return 1
    queue_matches "$IFACE" "$STATE_DIR/queue.pending/after.json" || {
        fail '真实网卡队列与预先验证的目标不一致，请检查保留的事务'; return 1;
    }
    mv -T -- "$STATE_DIR/queue.pending" "$STATE_DIR/queue-state" || return 1
    QUEUE_ACTIVE=0; trap - EXIT INT TERM HUP
    log_event "queue completed interface=$IFACE qdisc=$QUEUE" || warn '队列已设置但日志失败'
    say "已验证 $IFACE 根队列为 $QUEUE；重启后不自动重建。可用 queue-restore 恢复。"
}
restore_queue() ( restore_queue_impl )
restore_queue_impl() {
    if (( DRY_RUN )); then say '预演：核对当前队列与快照，恢复此前简单根队列；不改变启动配置。'; return 0; fi
    detect_system; require_mutation recovery || return 1
    ensure_dependencies python3 tc || return $?
    prepare_state && acquire_lock || return 1
    local dir
    if [[ -d $STATE_DIR/queue.pending ]]; then dir="$STATE_DIR/queue.pending"
    elif [[ -d $STATE_DIR/queue-state ]]; then dir="$STATE_DIR/queue-state"
    else say '没有本脚本保存的网卡队列事务。'; return 0; fi
    rollback_queue "$dir" || return 1
    log_event 'queue restored' || warn '恢复成功，但日志失败'
}

kernel_package() {
    case $OS_ID:$ARCH in
        debian:x86_64) say linux-image-amd64 ;; debian:aarch64) say linux-image-arm64 ;;
        ubuntu:x86_64|ubuntu:aarch64) say linux-generic ;;
        rocky:*|almalinux:*) say kernel ;;
        *) fail '没有此平台的发行版内核适配器'; return 1 ;;
    esac
}
# Read system APT sources as data, never shell code. Emit a constrained source
# list bound to the distribution keyring, not third-party/global trust keys.
apt_sources() {
    python3 - "$1" "$OS_ID" "$OS_CODENAME" <<'PY'
import pathlib,sys,re,urllib.parse
root=pathlib.Path(sys.argv[1]); distro=sys.argv[2]; codename=sys.argv[3]
key={'debian':'debian-archive-keyring.gpg','ubuntu':'ubuntu-archive-keyring.gpg'}[distro]
key='/usr/share/keyrings/'+key
allowed={'debian':{'deb.debian.org','security.debian.org'},
         'ubuntu':{'archive.ubuntu.com','security.ubuntu.com','ports.ubuntu.com'}}[distro]
lines=[]
def emit(uri,suite,components,opts=''):
    u=urllib.parse.urlsplit(uri)
    official=u.hostname in allowed or (distro=='ubuntu' and (u.hostname or '').endswith('.archive.ubuntu.com'))
    if (u.scheme not in ('http','https') or not official or u.username or u.password
        or u.port or u.query or u.fragment): raise ValueError('只允许明确的发行版官方仓库主机')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]*',u.path): raise ValueError('仓库路径不合法')
    if not codename or suite not in (codename,codename+'-updates',codename+'-security'):
        raise ValueError('只接受当前代号的正式版、updates 和 security 仓库')
    if not components or any(not re.fullmatch(r'[a-z0-9-]+',x) for x in components):
        raise ValueError('仓库组件不合法')
    low=opts.lower()
    if re.search(r'(trusted\s*[=:]\s*yes|allow-insecure\s*[=:]\s*(yes|true)|check-valid-until\s*[=:]\s*no)',low):
        raise ValueError('拒绝关闭验证的仓库选项')
    lines.append('deb [signed-by='+key+'] '+uri+' '+suite+' '+' '.join(components))
try:
    files=[root/'sources.list']+sorted((root/'sources.list.d').glob('*.list'))+sorted((root/'sources.list.d').glob('*.sources'))
    for p in files:
        if not p.exists(): continue
        text=p.read_text()
        if p.suffix=='.sources':
            for block in re.split(r'\n\s*\n',text):
                fields={};last=None
                for line in block.splitlines():
                    if not line.strip() or line.lstrip().startswith('#'):continue
                    if line[0].isspace() and last: fields[last]+=' '+line.strip();continue
                    k,sep,v=line.partition(':')
                    if not sep:raise ValueError('无效 Deb822 字段')
                    last=k.lower();fields[last]=v.strip()
                if not fields or fields.get('enabled','yes').lower()=='no': continue
                if 'deb' not in fields.get('types','').split(): continue
                for uri in fields.get('uris','').split():
                    for suite in fields.get('suites','').split():
                        emit(uri,suite,fields.get('components','').split(),' '.join(k+':'+v for k,v in fields.items()))
        else:
            for line in text.splitlines():
                line=line.split('#',1)[0].strip()
                if not line or line.startswith('deb-src '):continue
                m=re.fullmatch(r'deb\s+(?:\[([^\]]*)\]\s+)?(\S+)\s+(\S+)\s+(.+)',line)
                if not m: raise ValueError('无法解析 sources.list')
                opts,uri,suite,components=m.groups();emit(uri,suite,components.split(),opts or '')
    if not lines:raise ValueError('没有可使用的官方二进制仓库')
    print('\n'.join(dict.fromkeys(lines)))
except (ValueError,OSError) as e:
    print('APT 来源检查失败：'+str(e),file=sys.stderr);sys.exit(1)
PY
}
dnf_trust() {
    local key_package
    case $OS_ID in rocky) key_package=rocky-gpg-keys ;; almalinux) key_package=almalinux-gpg-keys ;; *) return 1 ;; esac
    # Verify locally installed vendor trust files have not been modified.
    rpm -V "$key_package" || { fail '发行版 GPG key 软件包校验失败'; return 1; }
    python3 - "$OS_ID" <<'PY'
import configparser,glob,pathlib,sys,urllib.parse
try:
    c=configparser.ConfigParser(interpolation=None,strict=True)
    c.read(glob.glob('/etc/yum.repos.d/*.repo'))
    for name in ('baseos','appstream'):
        if name not in c:raise ValueError('缺少 '+name+' 官方仓库')
        r=c[name]
        if r.get('gpgcheck','1')!='1' or r.get('sslverify','1') not in ('1','true','True'):
            raise ValueError('仓库禁用了签名或 TLS 校验')
        urls=(r.get('metalink','')+' '+r.get('mirrorlist','')+' '+r.get('baseurl','')).split()
        suffix='.rockylinux.org' if sys.argv[1]=='rocky' else '.almalinux.org'
        if not urls:raise ValueError('仓库地址为空')
        for url in urls:
            u=urllib.parse.urlsplit(url)
            if u.scheme!='https' or not (u.hostname or '').endswith(suffix) or u.username or u.password:
                raise ValueError('仓库入口必须使用官方 HTTPS 主机')
        keys=r.get('gpgkey','').split()
        if not keys:raise ValueError('没有 GPG key')
        for k in keys:
            u=urllib.parse.urlsplit(k)
            p=pathlib.Path(u.path)
            expected='RPM-GPG-KEY-Rocky-' if sys.argv[1]=='rocky' else 'RPM-GPG-KEY-AlmaLinux-'
            if u.scheme!='file' or u.netloc or p.parent!=pathlib.Path('/etc/pki/rpm-gpg') or not p.name.startswith(expected):
                raise ValueError('需要发行版安装的官方本地 GPG key')
    print('\n'.join(dict.fromkeys(k for name in ('baseos','appstream') for k in (urllib.parse.urlsplit(u).path for u in c[name].get('gpgkey','').split()))))
except (ValueError,configparser.Error,OSError) as e:
    print('DNF 来源检查失败：'+str(e),file=sys.stderr);sys.exit(1)
PY
}
boot_preflight() {
    BOOT_MODE='' BOOT_ENTRY=''
    if [[ $OS_ID == rocky || $OS_ID == almalinux ]]; then
        has grubby || { fail '需要 grubby 保留已验证的默认内核'; return 1; }
        BOOT_ENTRY=$(grubby --default-kernel) || return 1
        [[ $BOOT_ENTRY == "/boot/vmlinuz-$(uname -r)" && -f $BOOT_ENTRY ]] || { fail '当前运行内核与默认启动内核不一致，请先核对。'; return 1; }
        BOOT_MODE=grubby
    else
        if ! has grub-editenv || ! has grub-set-default; then fail '需要 GRUB saved-entry 启动环境；不支持的启动器拒绝自动安装。'; return 1; fi
        local file default='' entry
        for file in /etc/default/grub /etc/default/grub.d/*.cfg; do
            [[ -f $file ]] || continue
            entry=$(sed -n 's/^[[:space:]]*GRUB_DEFAULT[[:space:]]*=[[:space:]]*//p' "$file" | tail -n 1)
            [[ -z $entry ]] || default=$entry
        done
        [[ $default == saved || $default == '"saved"' || $default == "'saved'" ]] || {
            fail '自动安装要求预先配置 GRUB_DEFAULT=saved 并保存当前内核启动项；避免新内核意外成为默认。'; return 1;
        }
        local env
        env=$(grub-editenv list) || return 1
        [[ $env != *next_entry=* ]] || { fail '存在一次性启动项，请先处理'; return 1; }
        BOOT_ENTRY=$(printf '%s\n' "$env" | sed -n 's/^saved_entry=//p')
        [[ $BOOT_ENTRY == *"$(uname -r)"* && $BOOT_ENTRY != *$'\n'* ]] || { fail 'saved_entry 必须明确指向当前运行内核，而非索引'; return 1; }
        [[ -s /boot/grub/grub.cfg ]] || { fail '找不到可核验 GRUB 配置'; return 1; }
        grep -Fq -- "$BOOT_ENTRY" /boot/grub/grub.cfg || {
            # Nested IDs use 'submenu>entry'. Check the final full entry ID.
            grep -Fq -- "${BOOT_ENTRY##*>}" /boot/grub/grub.cfg || { fail 'saved_entry 不在 GRUB 配置中'; return 1; }
        }
        BOOT_MODE=grub
    fi
}
preserve_boot() {
    local observed saved
    if [[ $BOOT_MODE == grubby ]]; then
        grubby --set-default "$BOOT_ENTRY" || return 1
        observed=$(grubby --default-kernel) || return 1
        [[ $observed == "$BOOT_ENTRY" ]] || { fail '默认启动内核读回校验失败'; return 1; }
    elif [[ $BOOT_MODE == grub ]]; then
        grub-set-default "$BOOT_ENTRY" || return 1
        grub-editenv unset next_entry || return 1
        observed=$(grub-editenv list) || return 1
        saved=$(printf '%s\n' "$observed" | sed -n 's/^saved_entry=//p')
        [[ $saved == "$BOOT_ENTRY" && $observed != *next_entry=* ]] || { fail 'GRUB 启动项读回校验失败'; return 1; }
    else return 1; fi
}
kernel_verify() {
    say "当前运行内核：$(uname -r)"
    say 'BBR 实现版本：未知；发行版包签名不证明 BBRv3，不凭 bbr 名称判断。'
    if has dpkg-query; then dpkg-query -W -f='${binary:Package} ${Version} ${db:Status-Abbrev}\n' 'linux-image*' 2>/dev/null || :
    elif has rpm; then rpm -q kernel kernel-core || :; fi
    [[ ! -r /var/run/reboot-required ]] || say '发行版提示需要重启；本脚本不会自动重启。'
    if [[ -r $STATE_DIR/kernel-before ]]; then
        say "安装前运行内核：$(cat "$STATE_DIR/kernel-before")"
        [[ $(cat "$STATE_DIR/kernel-before") != "$(uname -r)" ]] || say '运行内核尚未改变；安装成功不等于已启动新内核。'
    fi
    return 0
}
kernel_plan() {
    detect_system
    local package
    package=$(kernel_package) || return 1
    say "内核计划：$OS_ID $OS_VERSION / $ARCH；软件包 $package；通道 $CHANNEL。"
    say '安装前要求：官方签名仓库、可核验的旧内核与固定启动项、/boot 至少 700 MiB、模块目录至少 2 GiB 空间。'
    say '保留旧内核；不移除软件包、不自动重启。安装后保留原默认启动项，新内核需人工选择测试。'
    say '容器、不支持的启动方式、第三方源或验证关闭时拒绝安装。'
    return 0
}
run_kernel_tool() {
    has setsid || { fail '需要 util-linux setsid 管理包安装进程组'; return 1; }
    local rc=0
    setsid --wait "$@" &
    KERNEL_CHILD_PID=$!
    wait "$KERNEL_CHILD_PID" || rc=$?
    KERNEL_CHILD_PID=''
    return "$rc"
}
stop_kernel_child() {
    local count
    if [[ -n ${KERNEL_CHILD_PID:-} ]]; then
        kill -TERM -- "-$KERNEL_CHILD_PID" 2>/dev/null || :
        for (( count=0; count<30; count++ )); do
            kill -0 -- "-$KERNEL_CHILD_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL -- "-$KERNEL_CHILD_PID" 2>/dev/null || :
        wait "$KERNEL_CHILD_PID" 2>/dev/null || :
        KERNEL_CHILD_PID=''
    fi
}
kernel_signal() {
    local rc=$1
    trap '' HUP INT TERM
    stop_kernel_child
    exit "$rc"
}

begin_kernel_journal() {
    [[ ! -e $STATE_DIR/kernel.pending ]] || { fail '存在未完成内核事务，请先 kernel recover'; return 1; }
    local temp
    temp=$(mktemp -d "$STATE_DIR/kernel-journal.XXXXXXXX") || return 1
    printf '%s\n' "$BOOT_MODE" > "$temp/mode" || return 1
    printf '%s\n' "$BOOT_ENTRY" > "$temp/entry" || return 1
    sync -f "$temp" || return 1
    mv -T -- "$temp" "$STATE_DIR/kernel.pending" || return 1
    KERNEL_ACTIVE=1
    trap 'kernel_exit $?' EXIT
    trap 'kernel_signal 130' INT
    trap 'kernel_signal 143' TERM
    trap 'kernel_signal 129' HUP
    sync -f "$STATE_DIR" || return 1
}
recover_kernel_journal() {
    [[ -d $STATE_DIR/kernel.pending ]] || { say '没有待恢复的内核启动项。'; return 0; }
    local dir="$STATE_DIR/kernel.pending" history
    BOOT_MODE=$(cat "$dir/mode") || return 1
    BOOT_ENTRY=$(cat "$dir/entry") || return 1
    case $BOOT_MODE in grub|grubby) ;; *) fail '未知的启动恢复模式'; return 1 ;; esac
    [[ -n $BOOT_ENTRY && $BOOT_ENTRY != -* && $BOOT_ENTRY != *$'\n'* && $BOOT_ENTRY != *$'\r'* ]] || { fail '启动项记录不合法'; return 1; }
    preserve_boot || { fail '启动项恢复失败，请通过控制台检查；保留恢复记录'; return 1; }
    history=$(mktemp -d "$STATE_DIR/kernel-history.XXXXXXXX") || return 1
    mv -- "$dir" "$history/journal" || return 1
    KERNEL_ACTIVE=0
    log_event 'kernel original boot entry restored' || warn '日志失败'
    say '原默认启动项已恢复；这不会卸载部分安装的内核，请核对包管理器状态。'
}
kernel_exit() {
    local rc=$1
    trap '' HUP INT TERM
    stop_kernel_child
    if (( KERNEL_ACTIVE )); then
        warn '内核操作退出，恢复原默认启动项。'
        recover_kernel_journal || { warn '请通过控制台核对后执行 kernel recover；勿直接重启。'; rc=1; }
    fi
    trap - EXIT; exit "$rc"
}
kernel_recover() (
    if (( DRY_RUN )); then say '预演：从 kernel.pending 恢复安装前默认启动项，不卸载软件包。'; return 0; fi
    ensure_dependencies sysctl flock awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat || return $?
    detect_system; require_mutation recovery || return 1
    prepare_state && acquire_lock || return 1
    recover_kernel_journal
)
vendor_key_owned() {
    local owner
    owner=$(rpm -qf --qf '%{NAME}' -- "$1") || return 1
    [[ $owner == "$2" ]] || { fail '所选签名 key 不属于已验证的发行版 key 软件包'; return 1; }
}
install_rpm_kernel() {
    local key_package keys key dir rpmfile
    [[ $OS_ID == rocky ]] && key_package=rocky-gpg-keys || key_package=almalinux-gpg-keys
    keys=$(dnf_trust) || return 1
    while IFS= read -r key; do vendor_key_owned "$key" "$key_package" || return 1; done <<< "$keys"
    dir=$(mktemp -d "$STATE_DIR/kernel-rpms.XXXXXXXX") || return 1
    mkdir -m 700 "$dir/rpmdb" || return 1
    rpm --dbpath "$dir/rpmdb" --initdb || return 1
    while IFS= read -r key; do rpmkeys --dbpath "$dir/rpmdb" --import "$key" || return 1; done <<< "$keys"
    local -a opts=(--noplugins --disablerepo='*' --enablerepo=baseos --enablerepo=appstream
        --setopt=gpgcheck=1 --setopt=localpkg_gpgcheck=1 --setopt=sslverify=1
        --setopt=baseos.gpgcheck=1 --setopt=appstream.gpgcheck=1
        --setopt=baseos.sslverify=1 --setopt=appstream.sslverify=1 --setopt=installonly_limit=0 '--setopt=installonlypkgs=kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra')
    # Download first; then verify EVERY RPM against an isolated vendor-only
    # keyring, independent of other keys imported in the host RPM database.
    run_kernel_tool dnf "${opts[@]}" --assumeyes --downloadonly --downloaddir="$dir" install kernel || return 1
    local -a packages=()
    local signature
    for rpmfile in "$dir"/*.rpm; do
        [[ -f $rpmfile && ! -L $rpmfile ]] || continue
        signature=$(rpmkeys --dbpath "$dir/rpmdb" --checksig --verbose "$rpmfile") || { fail 'RPM 签名验证失败'; return 1; }
        grep -Eiq 'Signature.*: OK' <<< "$signature" || { fail 'RPM 缺少可验证的签名'; return 1; }
        packages+=("$rpmfile")
    done
    (( ${#packages[@]} > 0 )) || { say '没有下载新内核软件包，可能已是当前仓库最新版本。'; return 0; }
    run_kernel_tool dnf --noplugins --disablerepo='*' --setopt=installonly_limit=0 '--setopt=installonlypkgs=kernel,kernel-core,kernel-modules,kernel-modules-core,kernel-modules-extra' \
        --setopt=gpgcheck=1 --setopt=localpkg_gpgcheck=1 --assumeyes install "${packages[@]}"
}

running_kernel_pins() {
    local kernel rows name version status base found=0
    local -a pins=()
    kernel=$(uname -r) || return 1
    rows=$(dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n') || return 1
    while IFS=$'\t' read -r name version status; do
        [[ $status == installed ]] || continue
        base=${name%%:*}
        case $base in
            "linux-image-$kernel"|"linux-image-unsigned-$kernel"|"linux-modules-$kernel"|"linux-modules-extra-$kernel")
                [[ -n $version ]] || return 1
                pins+=("$name=$version")
                [[ $base != "linux-image-$kernel" && $base != "linux-image-unsigned-$kernel" ]] || found=1 ;;
        esac
    done <<< "$rows"
    (( found )) || { fail '无法确定当前运行内核的软件包版本，拒绝覆盖恢复内核'; return 1; }
    printf '%s\n' "${pins[@]}"
}

kernel_install() ( kernel_install_impl )
kernel_install_impl() {
    detect_system; require_mutation || return 1
    ensure_dependencies python3 setsid || return $?
    prepare_state && acquire_lock || return 1
    [[ ! -e $STATE_DIR/kernel.pending ]] || { fail '存在未完成内核事务，请先 kernel recover'; return 1; }
    boot_preflight || return 1
    [[ -d /boot && -d /lib/modules ]] || { fail '缺少 /boot 或 /lib/modules'; return 1; }
    local free_boot free_modules package rc=0
    free_boot=$(df -Pk /boot | awk 'END {print $4}') || return 1
    free_modules=$(df -Pk /lib/modules | awk 'END {print $4}') || return 1
    if [[ ! $free_boot =~ ^[0-9]+$ || ! $free_modules =~ ^[0-9]+$ ]] ||
        (( free_boot < 716800 || free_modules < 2097152 )); then fail '启动分区或模块目录空间不足'; return 1; fi
    package=$(kernel_package) || return 1
    begin_kernel_journal || return 1
    uname -r > "$STATE_DIR/kernel-before" || return 1
    printf '%s\n' "$BOOT_ENTRY" > "$STATE_DIR/kernel-boot-entry" || return 1
    log_event "kernel install begin distro=$OS_ID package=$package" || return 1
    if [[ $OS_ID == debian || $OS_ID == ubuntu ]]; then
        local keyring sources pin_text
        local -a pins=()
        [[ $OS_ID == debian ]] && keyring=/usr/share/keyrings/debian-archive-keyring.gpg || keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
        [[ -s $keyring ]] || { fail '缺少发行版归档签名 keyring'; return 1; }
        OS_CODENAME=$(read_os_field VERSION_CODENAME)
        sources=$(apt_sources /etc/apt) || return 1
        printf '%s\n' "$sources" > "$STATE_DIR/kernel-sources.list" || return 1
        [[ -d $STATE_DIR/empty-sources ]] || mkdir -m 700 "$STATE_DIR/empty-sources" || return 1
        local -a opts=(-o "Dir::Etc::sourcelist=$STATE_DIR/kernel-sources.list" -o "Dir::Etc::sourceparts=$STATE_DIR/empty-sources"
            -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false
            -o APT::Get::AllowUnauthenticated=false -o Acquire::https::Verify-Peer=true -o Acquire::https::Verify-Host=true
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
        dpkg-query -W -f='${db:Status-Status}' "linux-image-$(uname -r)" 2>/dev/null | grep -qx installed || {
            fail '当前内核不是已安装的发行版 linux-image 软件包，不能保证恢复启动'; return 1;
        }
        pin_text=$(running_kernel_pins) || return 1
        mapfile -t pins <<< "$pin_text"
        # Manual mark prevents later autoremove from deleting the recovery kernel.
        apt-mark manual "linux-image-$(uname -r)" || return 1
        DEBIAN_FRONTEND=noninteractive run_kernel_tool apt-get "${opts[@]}" update &&
            DEBIAN_FRONTEND=noninteractive run_kernel_tool apt-get "${opts[@]}" --simulate --no-remove --no-install-recommends install "$package" "${pins[@]}" &&
            DEBIAN_FRONTEND=noninteractive run_kernel_tool apt-get "${opts[@]}" --yes --no-remove --no-install-recommends install "$package" "${pins[@]}" || rc=$?
    else
        install_rpm_kernel || rc=$?
    fi
    # Package scripts may update the bootloader even on a failed transaction.
    recover_kernel_journal || return 1
    trap - EXIT INT TERM HUP
    (( rc == 0 )) || { fail "内核包事务失败，退出码 $rc；未自动删除部分安装内容，请检查包管理器状态。"; return "$rc"; }
    log_event 'kernel package transaction completed; old boot entry retained' || warn '日志失败'
    say '内核包安装完成，原默认启动项已保留。请通过控制台选择新内核测试，再运行 kernel verify。'
    say '未重启，未证明新内核已可启动，也未证明存在 BBRv3。'
}
kernel_command() {
    case ${ACTION:-plan} in list|plan|install|verify|recover) ;; *) fail '未知 kernel 子命令'; return 2 ;; esac
    if [[ ${CHANNEL:-distro} == bbr3 ]]; then
        fail '目前没有配置经过核验的可信 BBRv3 签名软件包来源；拒绝下载未知第三方内核。官方研究源码：https://github.com/google/bbr/tree/v3'
        return 1
    fi
    case ${ACTION:-plan} in
        list) detect_system; kernel_verify; kernel_plan ;;
        plan) kernel_plan ;;
        verify) kernel_verify ;;
        recover) kernel_recover ;;
        install) if (( DRY_RUN )); then say '预演：不会运行包管理器或修改启动项。'; kernel_plan; else kernel_install; fi ;;
    esac
}

benchmark_summary() {
    python3 /dev/fd/3 3<<'PY'
import json,sys,math,re

def printable(value):
    return ''.join(c if c.isprintable() else repr(c)[1:-1] for c in str(value))
def number(value,label):
    if type(value) not in (int,float) or not math.isfinite(value) or value<0:
        raise ValueError(label+'必须是非负有限数值')
    return value
try:
    d=json.load(sys.stdin)
    if not isinstance(d,dict): raise ValueError('结果根节点必须是对象')
    if d.get('error'): raise ValueError(printable(d['error']))
    end=d['end']
    if not isinstance(end,dict): raise ValueError('end 结果不合法')
    rx=number(end['sum_received']['bits_per_second'],'吞吐')
    sent=end.get('sum_sent',{})
    if not isinstance(sent,dict): raise ValueError('发送统计不合法')
    retries=sent.get('retransmits','未知')
    if retries!='未知' and (type(retries) is not int or retries<0): raise ValueError('重传次数不合法')
    streams=end.get('streams',[])
    if not isinstance(streams,list): raise ValueError('流统计必须是数组')
    rtts=[]
    for stream in streams:
        if not isinstance(stream,dict): raise ValueError('流统计项不合法')
        sender=stream.get('sender',{})
        if not isinstance(sender,dict): raise ValueError('发送流统计不合法')
        if 'mean_rtt' in sender:rtts.append(number(sender['mean_rtt'],'RTT')/1000)
    cc=end.get('sender_tcp_congestion')
    if cc is None:cc='未知（服务端/旧版 iperf3 未报告）'
    elif not isinstance(cc,str) or not re.fullmatch(r'[A-Za-z0-9_]{1,32}',cc):raise ValueError('算法报告不合法')
    print('接收吞吐 %.3f Mbps；发送重传 %s；发送端算法 %s' % (rx/1000000,retries,cc))
    print('各流平均 TCP RTT (ms)：'+(', '.join('%.3f'%x for x in rtts) if rtts else '未知'))
except (ValueError,KeyError,TypeError,OverflowError) as e:
    print('测速结果无效：'+printable(e),file=sys.stderr);sys.exit(1)
PY
}
run_benchmark_once() {
    [[ -n $HOST ]] || { fail '请指定 --host 自备 iperf3 服务端；仅测试有权限的目标'; return 2; }
    (( REVERSE == 0 || COMPARE == 0 )) || { fail '反向测试由服务端控制算法，不能进行本地 --compare'; return 2; }
    if (( DRY_RUN )); then
        say "预演：iperf3 TCP 主机 $HOST 端口 $PORT 时长 ${DURATION}s 并发 $STREAMS 算法 $ALGORITHM reverse=$REVERSE compare=$COMPARE。"
        say '不会连接服务端、加载模块或创建结果文件。'; return 0
    fi
    ensure_dependencies iperf3 python3 timeout sysctl date uname head mktemp || return $?
    detect_capabilities
    local -a algorithms=("$ALGORITHM")
    (( COMPARE == 0 )) || algorithms=(cubic bbr)
    local algorithm
    if (( REVERSE == 0 )); then
        for algorithm in "${algorithms[@]}"; do
            contains_word "$AVAILABLE" "$algorithm" || { fail "当前内核未注册算法 $algorithm；测速不自动加载模块"; return 1; }
        done
    fi
    local dir rc=0 current_rc result device_record=''
    if (( AUTO )); then device_record=$(hardware_snapshot) || return 1; fi
    dir=$(mktemp -d /tmp/bbr-benchmark.XXXXXXXX) || return 1
    {
        printf 'timestamp_utc=%s\nhost=%s\nport=%s\nduration=%s\nparallel=%s\nreverse=%s\n' "$(date -u +%FT%TZ)" "$HOST" "$PORT" "$DURATION" "$STREAMS" "$REVERSE"
        printf 'requested_algorithm=%s\ncompare=%s\n' "$ALGORITHM" "$COMPARE"
        [[ -z $device_record ]] || printf 'device_profile=%s\n' "$device_record"
        printf 'kernel=%s\niperf_version=' "$(uname -r)"
        iperf3 --version | head -n 1
    } > "$dir/conditions.txt" || return 1
    say "测试条件与原始结果保存在：$dir"
    say "目标 $HOST:$PORT；每轮 ${DURATION}s；并发 $STREAMS；reverse=$REVERSE"
    say '只设置测试 socket，不修改系统默认拥塞算法。'
    if (( REVERSE )); then warn '反向模式算法由服务端决定，--algorithm 不作为服务端算法证明。'; fi
    for algorithm in "${algorithms[@]}"; do
        local -a args=(-c "$HOST" -p "$PORT" -t "$DURATION" -P "$STREAMS" -J --connect-timeout 5000)
        if (( REVERSE )); then args+=(-R); else args+=(-C "$algorithm"); fi
        result="$dir/$algorithm.json"
        say "测试请求算法：$algorithm"
        current_rc=0
        # A bounded wall-clock timeout also covers a peer stalling after connect.
        if has timeout; then timeout --signal=TERM --kill-after=5 "$(( DURATION + 30 ))" iperf3 "${args[@]}" > "$result" 2>"$dir/$algorithm.stderr" || current_rc=$?
        else fail '需要 coreutils timeout 以限制远端测试等待'; return 1; fi
        if (( current_rc != 0 )); then
            warn "iperf3 失败，退出码 $current_rc；详情：$dir/$algorithm.stderr"
            (( rc != 0 )) || rc=$current_rc
        fi
        benchmark_summary < "$result" || { (( rc != 0 )) || rc=1; }
    done
    if (( COMPARE )); then
        say '对比按 cubic → bbr 顺序进行，仅代表这两次测量；路径变化和测试顺序会影响结果。'
    fi
    return "$rc"
}

run_benchmark() {
    (( SUITE )) || { run_benchmark_once; return $?; }
    [[ -n $HOST ]] || { fail '请指定 --host'; return 2; }
    (( REVERSE == 0 || COMPARE == 0 )) || { fail '反向模式不能使用 --compare'; return 2; }
    ensure_dependencies python3 || return $?
    load_device_resources || return 1
    local pressure=$DEVICE_STREAMS rc=0 current=0
    (( ! STREAMS_EXPLICIT )) || pressure=$STREAMS
    say '设备测试套件：先单连接，再单独测试并发；每轮使用相同目标、时长和方向。'
    ( STREAMS=1; run_benchmark_once ) || rc=$?
    if (( pressure > 1 )); then
        say "并发测试：$pressure 流（手动 --parallel 优先）"
        ( STREAMS=$pressure; run_benchmark_once ) || current=$?
        (( rc != 0 )) || rc=$current
    else say '本次并发设置为 1，未重复执行相同条件的测试。'; fi
    return "$rc"
}
benchmark_compare() {
    [[ -n $BEFORE && -n $AFTER ]] || { fail '需要 --before 与 --after 两个保存的测速目录'; return 2; }
    has python3 || { fail '结果比较需要 python3'; return 1; }
    python3 - "$BEFORE" "$AFTER" <<'PY'
import json,pathlib,re,sys,math

def conditions(path):
    d={}
    for line in (path/'conditions.txt').read_text().splitlines():
        k,sep,v=line.partition('=')
        if not sep or k in d:raise ValueError('条件记录格式错误或重复')
        d[k]=v
    return d

def metric(path,algo):
    raw=json.loads((path/(algo+'.json')).read_text())
    if not isinstance(raw,dict) or raw.get('error'):raise ValueError('结果包含失败或不是有效对象')
    end=raw['end'];rate=end['sum_received']['bits_per_second']
    if type(rate) not in (int,float) or not math.isfinite(rate) or rate<0:raise ValueError('吞吐无效')
    retries=end.get('sum_sent',{}).get('retransmits')
    if retries is not None and (type(retries) is not int or retries<0):raise ValueError('重传无效')
    rtts=[]
    for stream in end.get('streams',[]):
        val=stream.get('sender',{}).get('mean_rtt')
        if val is not None:
            if type(val) not in (int,float) or not math.isfinite(val) or val<0:raise ValueError('RTT 无效')
            rtts.append(val/1000)
    cc=end.get('sender_tcp_congestion')
    if cc is not None and (not isinstance(cc,str) or not re.fullmatch(r'[A-Za-z0-9_]{1,32}',cc)):raise ValueError('实测算法报告无效')
    return rate,retries,(sum(rtts)/len(rtts) if rtts else None),cc
try:
    before,after=map(pathlib.Path,sys.argv[1:]);a=conditions(before);b=conditions(after)
    for key in ('host','port','duration','parallel','reverse','requested_algorithm','compare'):
        if key not in a or key not in b or a[key]!=b[key]:raise ValueError('条件不一致或缺失：'+key)
    algo=a['requested_algorithm']
    if not re.fullmatch(r'[A-Za-z0-9_]{1,32}',algo):raise ValueError('算法名称不合法')
    algorithms=['cubic','bbr'] if a['compare']=='1' else [algo]
    if a['compare'] not in ('0','1'):raise ValueError('compare 条件不合法')
    for algo in algorithms:
        x=metric(before,algo);y=metric(after,algo)
        if x[3] and y[3] and x[3]!=y[3]:raise ValueError('实测发送端算法不一致，不能按相同条件比较')
        if a['reverse']=='1' and (not x[3] or not y[3]):raise ValueError('反向测试缺少服务端实测算法，不能确认可比性')
        delta='%+.1f%%'%((y[0]/x[0]-1)*100) if x[0] else '不可计算（原吞吐为 0）'
        fmt=lambda v:'未知' if v is None else ('%.3f'%v)
        print('%s：吞吐 %.3f → %.3f Mbps（%s）'%(algo,x[0]/1e6,y[0]/1e6,delta))
        print('  实测发送端算法 %s → %s'%(x[3] or '未知',y[3] or '未知'))
        print('  重传 %s → %s；各流平均 RTT 的均值 %s → %s ms'%(fmt(x[1]),fmt(y[1]),fmt(x[2]),fmt(y[2])))
    print('这只是两次相同记录条件的观测；链路变化、测试顺序和服务端状态可能影响结果，不自动宣称提速。')
except (OSError,ValueError,TypeError,KeyError,AttributeError,OverflowError) as e:
    message=''.join(c if c.isprintable() else repr(c)[1:-1] for c in str(e))
    print('无法比较：'+message,file=sys.stderr);sys.exit(1)
PY
}
ui_compare_results() {
    local BEFORE='' AFTER=''
    ui_heading '比较保存的测速结果'
    ui_read '优化前结果目录（q 返回）' || return 0
    case $UI_INPUT in q|Q) return 0 ;; esac
    BEFORE=$UI_INPUT
    ui_read '优化后结果目录（q 返回）' || return 0
    case $UI_INPUT in q|Q) return 0 ;; esac
    AFTER=$UI_INPUT
    ui_run '测速前后对比' benchmark_compare || :
}

main() {
    # Fixed trusted command search path for privileged operations.
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    export LC_ALL=C
    umask 077
    ui_init
    local rc=0
    parse_args "$@" || rc=$?
    (( rc == 10 )) && return 0
    (( rc == 0 )) || return "$rc"
    case $COMMAND in
        enable|disable|restore|queue|queue-restore)
            ensure_dependencies sysctl flock awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat sed df readlink || return $? ;;
        kernel)
            if [[ $ACTION == install || $ACTION == recover ]]; then
                ensure_dependencies sysctl flock awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat sed df readlink || return $?
            fi ;;
        menu) ensure_dependencies python3 sysctl ip tc flock unshare awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat sed df readlink || return $? ;;
        '') if [[ -t 0 ]]; then ensure_dependencies python3 sysctl ip tc flock unshare awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat sed df readlink || return $?; fi ;;
    esac
    case $COMMAND in
        '') if [[ -t 0 ]]; then menu; else usage; fi ;;
        install-deps) install_dependencies ;;
        status) show_status ;; doctor) doctor ;; enable) enable_bbr ;;
        disable|restore) restore_state ;; queue) set_queue ;; queue-restore) restore_queue ;;
        kernel) kernel_command ;; benchmark) run_benchmark ;; menu) menu ;;
        profile) show_device_profile ;; plan) show_change_plan ;; recovery) recovery_center ;; compare) benchmark_compare ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -uo pipefail
    main "$@"
fi
