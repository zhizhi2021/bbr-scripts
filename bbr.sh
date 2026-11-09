#!/usr/bin/env bash
# BBR manager — only this script is required. Bash >= 4.4, Linux.
# Algorithm references: https://github.com/google/bbr
# No remote shell execution or kernel removal. Kernel install can reboot.

VERSION=1.3.0
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
BENCH_INTERRUPTED=0
# Visual vocabulary; ui_init() upgrades these to box glyphs on a terminal.
# Piped or dumb output keeps the plain ASCII forms.
UI_CARD=0 UI_CARD_INNER=0 QUICK_CPUS='' QUICK_MEM_KB=''
UI_BAR_ON='#' UI_BAR_OFF='-' UI_ICON_OK='[OK]' UI_ICON_NO='[NG]' UI_ICON_WARN='[!]'
UI_ICON_NOTE='>' UI_ICON_INFO='-' UI_SEP='|' UI_RULE_FILL='-'
UI_CARD_TOP='+-' UI_CARD_SIDE='|' UI_CARD_BOTTOM='+-' UI_ENDCAP_TOP='+' UI_ENDCAP_BOTTOM='+'

say() { printf '%s\n' "$*"; }
warn() { printf '提示：%s\n' "$*" >&2; }
fail() { printf '错误：%s\n' "$*" >&2; return 1; }
usage() {
    cat <<'HELP'
BBR 管理工具：检测、预演、启用和恢复；仅内核安装成功切换后自动重启。
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
        debian|ubuntu)
            has apt-get && { printf 'apt\n'; return 0; }
            fail "已识别 $id，但缺少 apt-get，无法自动安装依赖"; return 1 ;;
        rocky|almalinux)
            has dnf && { printf 'dnf\n'; return 0; }
            fail "已识别 $id，但缺少 dnf，无法自动安装依赖"; return 1 ;;
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
            lsinitramfs) [[ $manager == apt ]] || { fail '缺少 lsinitramfs，且此包管理器不支持自动安装'; return 1; }; package=initramfs-tools-core ;;
            lsinitrd) [[ $manager == dnf ]] || { fail '缺少 lsinitrd，且此包管理器不支持自动安装'; return 1; }; package=dracut ;;
            awk) package=gawk ;; cmp) package=diffutils ;;
            timeout|stat|mktemp|date|head|tail|sort|cat|cp|mv|chmod|sync|rm|mkdir|rmdir|uname|df|readlink) package=coreutils ;;
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
    if has tc; then tc qdisc show; else fail '缺少 tc（iproute2），无法检查实际网卡队列。'; return 1; fi
}
show_status() {
    local rc=0
    detect_system; detect_capabilities
    ui_quick_facts
    ui_heading "系统状态 $UI_SEP v$VERSION"
    ui_card_begin '一眼看懂'
    ui_field '这台机器' "$(ui_plain_os) $UI_SEP ${QUICK_CPUS:-?} 核 / $(ui_plain_memory)"
    ui_field '现在' "加速 $(ui_plain_cc "${CURRENT_CC:-}") $UI_SEP 排队 ${CURRENT_QDISC:-未知}"
    ui_field '重启以后' "$(ui_restart_expect)"
    ui_card_end
    ui_note '只影响新连接；已有连接要重连。'
    ui_heading '运行参数'
    ui_note '原始读数，排障时用'
    ui_field '系统' "$OS_ID $OS_VERSION / $ARCH"
    ui_field '虚拟化' "$VIRT"
    ui_field '内核' "$(uname -r)"
    if (( SUPPORTED )); then ui_field '适配名单' '匹配（仍需运行能力检查）'
    else ui_field '适配名单' '未匹配（支持诊断与预演）'; fi
    ui_field '可用算法' "${AVAILABLE:-无法读取}"
    ui_field '默认算法' "${CURRENT_CC:-无法读取}"
    ui_field '默认队列' "${CURRENT_QDISC:-无法读取}"
    ui_field 'BBR 版本' '未知，需核验内核来源'
    ui_heading '持久配置'
    if [[ -r $CONFIG ]]; then ui_field '文件' "$CONFIG"; cat -- "$CONFIG" || rc=1
    elif [[ -e $CONFIG || -L $CONFIG ]]; then ui_field '状态' '存在，但无读取权限或链接不可用'; rc=1
    else ui_field '状态' '未由本脚本管理'; fi
    if [[ -z $AVAILABLE || -z $CURRENT_CC || -z $CURRENT_QDISC ]]; then warn '运行参数读取不完整。'; rc=1; fi
    ui_heading '实际网卡队列'
    inspect_qdiscs || rc=1
    ui_note '要看丢包/超限计数：tc -s qdisc show'
    ui_heading '生效说明'
    say '  新建 socket 才采用新的默认算法。'
    say '  已有监听 socket 可能继续继承旧值。'
    say '  名单核对 2026-11-07；不代表真机验证。'
    [[ $VIRT == container* ]] && warn '容器内读数不代表宿主机状态。'
    return "$rc"
}
confirm() {
    (( YES )) && return 0
    [[ -t 0 ]] || { fail '非交互修改需要 --yes；先使用 --dry-run 查看。'; return 1; }
    local reply
    printf '\n' >&2
    read -r -p '应用以上配置？[y/N，回车取消]：' reply || { warn '已取消。'; return 1; }
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
    # The queue memory budget belongs to `queue --auto` only. `enable --auto`
    # manages the default qdisc and must not be blocked by that budget.
    (( AUTO )) || return 0
    load_device_resources || return 1
    (( QUEUE_EXPLICIT )) || QUEUE=$DEVICE_QUEUE
}
show_device_profile() {
    local json detail=${1:-full}
    json=$(hardware_snapshot) || return 1
    ui_heading '设备资源'
    python3 -c 'import json,sys
d=json.load(sys.stdin)
on=sys.argv[2] if len(sys.argv)>2 else "#"
off=sys.argv[3] if len(sys.argv)>3 else "-"
cols=int(sys.argv[4]) if len(sys.argv)>4 else 64
bw=max(8,min(18,cols-30))
def bar(cur,mx,width=0):
    width=width or bw
    try:n=int(float(cur)*width/float(mx))
    except (TypeError,ValueError,ZeroDivisionError):return off*width
    n=max(0,min(width,n))
    return on*n+off*(width-n)
eff=d["effective_cpus"];log=d["logical_cpus"]
me=d["memory_limit_bytes"];ma=d["memory_available_bytes"]
pct=(100.0*ma/me) if me else 0
mem="%.1f / %.1f GiB"%(ma/1073741824.0,me/1073741824.0)
if cols>=50:mem+="（可用 %.0f%%）"%pct
print("  CPU：%s  %g / %s 核"%(bar(eff,log),eff,log))
print("  内存：%s  %s"%(bar(ma,me),mem))
print("  建议队列：%s"%d["recommended_qdisc"])
print("  测试并发：单流 1 / 压力 %s 流"%d["pressure_streams"])
for n in d["notes"]:print("  提示："+n)
if sys.argv[1]=="full":
 qb=d["queue_budget_bytes"]
 qtail="%.2f MiB（上限 32 MiB）"%(qb/1048576.0) if cols>=50 else "%.2f MiB"%(qb/1048576.0)
 print("  队列预算：%s  %s"%(bar(qb,32*1024**2),qtail))
 print("")
 print("  说明（白话版）")
 print("    CPU 有效/可见核数；内存 可用/上限。")
 print("    CPU 和内存只用来挑建议值。")
 print("    已考虑亲和性与 cgroup 配额。")
 print("    fq 的包数按 4 KiB/包估算。")
 print("    fq_codel/cake 可限制内存。")
 print("    设备资源不能推算线路带宽或 RTT。")
sys.exit(not d["complete"])' "$detail" "$UI_BAR_ON" "$UI_BAR_OFF" "$(ui_width)" <<< "$json" || return 1
    if [[ -n $IFACE ]] && has ip; then ip -o link show dev "$IFACE" || return 1; fi
}
show_change_plan() {
    show_device_profile compact || return 1
    apply_device_defaults || return 1
    detect_capabilities
    ui_heading '配置变更'
    ui_card_begin '要改什么'
    ui_change '新连接算法' "${CURRENT_CC:-}" bbr
    ui_change '默认队列' "${CURRENT_QDISC:-}" "$QUEUE"
    (( ! QUEUE_EXPLICIT )) || ui_field '队列来源' '手动指定（优先于设备建议）'
    ui_field '实际网卡队列' '本次不替换'
    ui_card_end
    ui_note '只改“以后新建连接”的默认值。'
    ui_heading '执行范围'
    ui_check ok '会改：新连接的加速算法与排队方式'
    ui_check ok '会写：配置文件与原始备份'
    ui_check info '不会动：缓冲区、连接数、内核'
    ui_note '执行前会显示计划并等你确认。'
    if (( AUTO )); then
        ui_heading '网卡队列预算（本次不应用）'
        ui_field '预算字节数' "$(awk -v b="$DEVICE_BUDGET" 'BEGIN{printf "%.2f MiB（%d 字节）", b/1048576, b}')"
        ui_note '只在 queue --auto 时使用这个预算。'
        ui_note 'fq 按包数估算；cake 可限制内存。'
    fi
    ui_heading '配置与恢复'
    ui_field '配置文件' "$CONFIG"
    ui_field '原始备份' "$STATE_DIR/baseline"
}
show_queue_plan() {
    show_device_profile || return 1
    apply_device_defaults || return 1
    if (( AUTO )); then
        (( DEVICE_BUDGET >= 1048576 )) || { fail '设备可用内存不足，自动队列修改已停止；请释放资源后重试'; return 1; }
    fi
    say "网卡变更：$IFACE → $QUEUE；不改变系统默认算法与默认队列。"
    if (( AUTO )); then say "设备队列预算：$DEVICE_BUDGET 字节；fq 仅按包数估算，fq_codel/cake 使用内存限制。"; fi
    say '只在本次运行中更换可完整恢复的简单根队列；现有过滤器、共享 block 或未知拓扑会阻止修改。'
}
recovery_center() {
    say '恢复与排障中心（只读）'
    say "状态目录：$STATE_DIR"
    ui_field '日志位置' "$LOG"
    ui_note '本命令不自动输出日志内容'
    if [[ -d $STATE_DIR && ! -x $STATE_DIR ]]; then fail '当前用户无读取权限，请以 root 查看恢复记录。'; return 1; fi
    local pending=0
    ui_card_begin '检查结果'
    if [[ -d $STATE_DIR/transaction ]]; then ui_check warn '配置事务未完成：bash bbr.sh restore'; pending=1; fi
    if [[ -d $STATE_DIR/kernel.pending ]]; then
        if [[ -f $STATE_DIR/kernel.pending/target-version ]]; then ui_check warn '内核切换待确认：bash bbr.sh kernel verify（回退用 kernel recover）'
        else ui_check warn '内核事务未完成：bash bbr.sh kernel recover'; fi
        pending=1
    fi
    [[ ! -d $STATE_DIR/kernel-switched ]] || ui_check ok '已保留内核切换恢复记录：bash bbr.sh kernel recover'
    if [[ -d $STATE_DIR/queue.pending ]]; then ui_check warn '队列事务未完成：bash bbr.sh queue-restore'; pending=1; fi
    (( pending )) || ui_check ok '没有未完成事务。'
    if [[ -d $STATE_DIR/baseline ]]; then
        if valid_snapshot "$STATE_DIR/baseline"; then ui_check ok '原始配置备份有效：bash bbr.sh restore'
        else ui_card_end; fail '原始备份不完整，请核对历史快照，勿盲目覆盖。'; return 1; fi
    fi
    [[ ! -d $STATE_DIR/queue-state ]] || ui_check ok '存在队列恢复快照：bash bbr.sh queue-restore'
    ui_card_end
    ui_note '历史记录在 *-history.* 等目录下'
    ui_note '不会自动用旧记录覆盖当前配置'
}
ui_device_menu() {
    local AUTO=1 QUEUE=$QUEUE QUEUE_EXPLICIT=$QUEUE_EXPLICIT
    ensure_dependencies python3 || return $?
    while :; do
        ui_heading '设备自适应（均衡稳定）'
        show_change_plan || { ui_pause; return 1; }
        say ''; say '  1  仅预演'; say '  2  应用默认 BBR 配置'; say '  3  网卡队列配置'; say '  0  返回'
        ui_read '请选择 [0-3]' || return 0
        case $UI_INPUT in
            0|q|Q) return 0 ;; 1) ui_preview || : ;;
            2) ui_run '设备自适应 BBR 配置' enable_bbr || : ;;
            3) ui_queue_menu ;; *) warn '无效选择，请输入 0-3。' ;;
        esac
    done
}

# Terminal UI: no extra dependencies; redirected output stays plain text.
UI_BOLD='' UI_CYAN='' UI_GREEN='' UI_YELLOW='' UI_RED='' UI_RESET=''
UI_INPUT=''
ui_init() {
    UI_BOLD='' UI_CYAN='' UI_GREEN='' UI_YELLOW='' UI_RED='' UI_RESET=''
    UI_CARD=0
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
        UI_BAR_ON='█' UI_BAR_OFF='░' UI_ICON_OK='✓' UI_ICON_NO='✗'
        UI_ICON_WARN='!' UI_ICON_NOTE='▸' UI_ICON_INFO='·' UI_SEP='·' UI_RULE_FILL='─'
        UI_CARD_TOP='┌─' UI_CARD_SIDE='│' UI_CARD_BOTTOM='└─' UI_ENDCAP_TOP='┐' UI_ENDCAP_BOTTOM='┘'
    fi
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
        UI_BOLD=$'\033[1m'; UI_CYAN=$'\033[36m'; UI_GREEN=$'\033[32m'
        UI_YELLOW=$'\033[33m'; UI_RED=$'\033[31m'; UI_RESET=$'\033[0m'
    fi
}
ui_width() {
    local width=${COLUMNS:-64}
    [[ $width =~ ^[0-9]{1,3}$ ]] || width=64
    width=$((10#$width))
    (( width >= 24 )) || width=24
    (( width <= 64 )) || width=64
    printf '%s' "$width"
}
ui_rule() {
    local line mark=${1:--}
    printf -v line '%*s' "$(ui_width)" ''
    printf '%s%s%s\n' "$UI_CYAN" "${line// /$mark}" "$UI_RESET"
}
ui_heading() { printf '\n%s[%s]%s\n' "$UI_BOLD" "$1" "$UI_RESET"; }
# <title> [title display width, default 8 for four CJK glyphs]
# Display width: CJK and fullwidth take two columns; box/arrow/block glyphs
# take one. LC_ALL=C makes ${#s} a byte count, so decode UTF-8 by hand.
ui_dw() {
    local s=$1 i=0 n=${#1} b b2 b3 cp w=0
    while (( i < n )); do
        b=$(printf '%d' "'${s:i:1}" 2>/dev/null) || b=63
        if (( b < 128 )); then w=$((w+1)); i=$((i+1))
        elif (( b < 224 )); then w=$((w+1)); i=$((i+2))
        elif (( b < 240 )); then
            b2=$(printf '%d' "'${s:i+1:1}" 2>/dev/null) || b2=0
            b3=$(printf '%d' "'${s:i+2:1}" 2>/dev/null) || b3=0
            cp=$(( ((b & 15) << 12) | ((b2 & 63) << 6) | (b3 & 63) ))
            if (( cp >= 0x2E80 )); then w=$((w+2)); else w=$((w+1)); fi
            i=$((i+3))
        else w=$((w+2)); i=$((i+4)); fi
    done
    printf '%s' "$w"
}
ui_fill() {
    local n=${1:-0} out
    (( n > 0 )) || n=0
    printf -v out '%*s' "$n" ''
    printf '%s' "${out// /$UI_RULE_FILL}"
}
# A card is only drawn when there is room for a readable inner width.
ui_card_begin() {
    local title=$1
    UI_CARD_INNER=$(( $(ui_width) - 6 ))
    if (( UI_CARD_INNER < 54 )); then
        UI_CARD=0
        printf '\n  %s%s%s\n' "$UI_BOLD" "$title" "$UI_RESET"
        return 0
    fi
    UI_CARD=1
    printf '\n  %s%s %s %s%s%s\n' "$UI_CYAN" "$UI_CARD_TOP" "$title" \
        "$(ui_fill $(( $(ui_width) - 7 - $(ui_dw "$title") )))" "$UI_ENDCAP_TOP" "$UI_RESET"
}
ui_card_end() {
    (( UI_CARD )) || { UI_CARD=0; return 0; }
    printf '  %s%s%s%s%s\n' "$UI_CYAN" "$UI_CARD_BOTTOM" \
        "$(ui_fill $(( $(ui_width) - 5 )))" "$UI_ENDCAP_BOTTOM" "$UI_RESET"
    UI_CARD=0
}
# One padded line inside the open card.
ui_cell() {
    local text=$1 pad
    pad=$(( UI_CARD_INNER - $(ui_dw "$text") ))
    (( pad >= 0 )) || pad=0
    printf '  %s%s%s %s%*s %s%s%s\n' "$UI_CYAN" "$UI_CARD_SIDE" "$UI_RESET" "$text" \
        "$pad" '' "$UI_CYAN" "$UI_CARD_SIDE" "$UI_RESET"
}
ui_note() {
    if (( UI_CARD )); then ui_cell "$UI_ICON_NOTE $1"; return 0; fi
    printf '  %s%s %s%s\n' "$UI_CYAN" "$UI_ICON_NOTE" "$1" "$UI_RESET"
}
# <ok|no|warn|info> <text>
ui_check() {
    local state=$1 text=$2 mark=$UI_ICON_OK
    case $state in
        no) mark=$UI_ICON_NO ;;
        warn) mark=$UI_ICON_WARN ;;
        info) mark=$UI_ICON_INFO ;;
    esac
    if (( UI_CARD )); then ui_cell "$mark $text"; return 0; fi
    printf '  %s %s\n' "$mark" "$text"
}
ui_plain_cc() {
    case ${1:-} in
        '') printf '无法读取' ;;
        bbr) printf '已开启（bbr）' ;;
        *) printf '未开启（%s）' "$1" ;;
    esac
}
ui_plain_os() {
    local name version
    if (( $(ui_width) < 50 )); then printf '%s %s' "$OS_ID" "$OS_VERSION"; return 0; fi
    name=$(read_os_field NAME 2>/dev/null || :)
    version=$(read_os_field VERSION_ID 2>/dev/null || :)
    if [[ -n $name && -n $version ]]; then printf '%s %s' "$name" "$version"
    else printf '%s %s' "$OS_ID" "$OS_VERSION"; fi
}
ui_quick_facts() {
    QUICK_CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || :)
    QUICK_MEM_KB=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || :)
    [[ $QUICK_CPUS =~ ^[0-9]+$ ]] && (( QUICK_CPUS > 0 )) || QUICK_CPUS=''
    [[ $QUICK_MEM_KB =~ ^[0-9]+$ ]] && (( QUICK_MEM_KB > 0 )) || QUICK_MEM_KB=''
}
ui_plain_memory() {
    if [[ -n $QUICK_MEM_KB ]]; then
        awk -v kb="$QUICK_MEM_KB" 'BEGIN{printf "%.1f GiB", kb/1048576}'
    else printf '内存未知'; fi
}
# Plain-language answer to "will this survive a reboot?", read back from the
# managed file instead of assuming enable's target values.
ui_restart_expect() {
    local cc qd
    if [[ ! -e $CONFIG && ! -L $CONFIG ]]; then
        printf '不受本脚本管理（沿用系统设置）'; return 0
    fi
    if [[ ! -r $CONFIG ]]; then
        printf '无法确认（读取配置文件需要 root）'; return 0
    fi
    cc=$(sed -n 's/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*//p' "$CONFIG" | tail -n 1)
    qd=$(sed -n 's/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*//p' "$CONFIG" | tail -n 1)
    if [[ -z $cc && -z $qd ]]; then
        printf '配置文件存在，但内容无法识别'
    elif [[ ( -z $cc || $cc == "${CURRENT_CC:-}" ) && ( -z $qd || $qd == "${CURRENT_QDISC:-}" ) ]]; then
        printf '和现在一致'
    else
        printf '重启后会变成算法 %s、队列 %s' "${cc:-保持默认}" "${qd:-保持默认}"
    fi
}
ui_field() {
    local label=$1 value=$2
    # Stack long values on narrow terminals; avoid CJK column padding.
    if (( $(ui_width) < 50 && ${#value} > 22 )); then
        if (( UI_CARD )); then
            printf '  %s%s%s %s\n' "$UI_CYAN" "$UI_CARD_SIDE" "$UI_RESET" "$label："
            printf '    %s\n' "$value"
        else printf '  %s：\n    %s\n' "$label" "$value"; fi
        return 0
    fi
    if (( UI_CARD )); then ui_cell "${label}：${value}"
    else printf '  %s：%s\n' "$label" "$value"; fi
}
ui_banner() {
    local status=$1 title=$2 color=$UI_GREEN
    case $status in 未完成|校验不完整) color=$UI_RED ;; 预演结束|无需修改) color=$UI_YELLOW ;; esac
    say ''; ui_rule '='
    printf '%s%s[%s] %s%s\n' "$UI_BOLD" "$color" "$status" "$title" "$UI_RESET"
    ui_rule '='
}
ui_change() {
    local label=$1 before=$2 after=$3 phase=${4:-plan} mark color=$UI_YELLOW
    if [[ -z $before || -z $after ]]; then mark=无法核实
    elif [[ $before == "$after" ]]; then mark=保持不变; color=$UI_CYAN
    elif [[ $phase == actual ]]; then mark=已修改; color=$UI_GREEN
    elif [[ $phase == observed ]]; then mark=检测到变化
    else mark=将修改; fi
    local pair
    if [[ -n $before && $before == "$after" ]]; then pair=$after
    else pair="${before:-无法读取} → ${after:-无法读取}"; fi
    if (( UI_CARD )); then ui_cell "[$mark] ${label}：$pair"; return 0; fi
    printf '  %s[%s]%s %s\n    %s\n' "$color" "$mark" "$UI_RESET" "$label" "$pair"
}
config_result() {
    local title=$1 before_cc=$2 before_qd=$3 target_cc=$4 target_qd=$5 mode=${6:-changed}
    local after_cc after_qd
    after_cc=$(sys_value net.ipv4.tcp_congestion_control) || after_cc=''
    after_qd=$(sys_value net.core.default_qdisc) || after_qd=''
    if [[ $after_cc != "$target_cc" || $after_qd != "$target_qd" ]]; then
        ui_banner '校验不完整' "$title"
        ui_card_begin '实际结果'
        ui_change '默认 TCP' "$before_cc" "$after_cc" observed
        ui_change '默认队列' "$before_qd" "$after_qd" observed
        ui_card_end
        ui_check no '运行值和目标不一致或读不到；请先看“状态”，再决定是否恢复。'
        return 1
    fi
    if [[ $mode == unchanged ]]; then ui_banner '无需修改' "$title"
    else ui_banner '执行成功' "$title"; fi
    ui_card_begin '实际结果'
    ui_change '默认 TCP' "$before_cc" "$after_cc" actual
    ui_change '默认队列' "$before_qd" "$after_qd" actual
    ui_card_end
    ui_check ok '以上为操作后重新读到的运行值，已核对一致。'
    if [[ -r $CONFIG ]]; then
        case $mode in
            unchanged) ui_field '[保持不变] 配置文件' "$CONFIG" ;;
            restored) ui_field '[已恢复] 配置文件' "$CONFIG" ;;
            *) ui_field '[已写入] 配置文件' "$CONFIG" ;;
        esac
    else say '  [配置状态] 本脚本的持久配置文件当前不存在。'; fi
    say '  [保持不变] 当前网卡队列；系统未重启。'
    say '  生效范围：新连接；已有监听 socket 可能沿用旧值。'
}
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
    local title=$1 rc=0 before_cc='' before_qd='' after_cc='' after_qd='' action=${2:-}
    shift
    ui_heading "$title"
    if [[ $action == enable_bbr || $action == restore_state ]]; then
        before_cc=$(sys_value net.ipv4.tcp_congestion_control) || before_cc=''
        before_qd=$(sys_value net.core.default_qdisc) || before_qd=''
    fi
    # Per-action isolation lets rollback traps finish before the failure summary.
    ( "$@" ) || rc=$?
    if (( rc == 0 )); then
        if (( DRY_RUN )); then
            ui_banner '预演结束' "$title"
            say '  [未执行] 未修改配置、加载模块或发起测速。'
        elif [[ $action != enable_bbr && $action != restore_state ]]; then
            ui_banner '执行成功' "$title"
        fi
    else
        ui_banner '未完成' "$title"
        ui_field '退出码' "$rc"
        if [[ $action == enable_bbr || $action == restore_state ]] && (( ! DRY_RUN )); then
            after_cc=$(sys_value net.ipv4.tcp_congestion_control) || after_cc=''
            after_qd=$(sys_value net.core.default_qdisc) || after_qd=''
            ui_heading '当前实际状态（操作结束后读取）'
            ui_change '默认 TCP' "$before_cc" "$after_cc" observed
            ui_change '默认队列' "$before_qd" "$after_qd" observed
            say '  运行值相同不代表所有文件均已恢复。'
            ui_field '恢复记录' "$STATE_DIR"
        fi
        say '  请查看上方原因，处理后重试。'
    fi
    ui_pause
    return "$rc"
}
ui_overview() {
    detect_system; detect_capabilities
    say ''; ui_rule
    printf '%sBBR 管理工具 v%s%s\n' "$UI_BOLD" "$VERSION" "$UI_RESET"
    ui_card_begin '当前情况'
    ui_field '系统' "$OS_ID $OS_VERSION / $ARCH"
    ui_field '内核' "$(uname -r)"
    ui_field '默认 TCP' "$(ui_plain_cc "${CURRENT_CC:-}")"
    ui_field '默认队列' "${CURRENT_QDISC:-未知}"
    ui_card_end
    ui_note '默认 TCP=加速算法，队列=排队方式'
    if (( DRY_RUN )); then say '运行模式：预演，不修改系统、不发起测速'
    elif [[ $VIRT == container* ]]; then say '运行模式：容器，只读（可预演/测速）'
    elif (( ! SUPPORTED )); then say '运行模式：此系统不在适配名单；可诊断、预演和测速'
    elif (( EUID != 0 )); then say '当前权限：普通用户；系统修改需以 root 重新运行'
    else say '当前权限：root；修改前会显示说明并确认'; fi
    if [[ -d $STATE_DIR && ! -x $STATE_DIR ]]; then
        say '备份与恢复记录：当前用户无读取权限'
    else
        [[ ! -d $STATE_DIR/baseline ]] || say '原配置备份：可恢复'
        [[ ! -d $STATE_DIR/transaction ]] || say '待处理：配置事务中断，请进入「恢复与排障 → 原 BBR 配置」'
        [[ ! -d $STATE_DIR/queue.pending ]] || say '待处理：队列事务中断，请进入「恢复与排障 → 原网卡队列」'
        [[ ! -d $STATE_DIR/kernel.pending ]] || say '待核验：内核操作有记录，请进入「内核管理 → 检查重启后的内核」'
    fi
    ui_rule
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
               say '将从官方签名仓库安装并切换默认内核；保留旧内核，校验成功后自动重启。' ;;
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
        say '  1  fq（BBR 常用搭配）'
        say '  2  fq_codel'
        say '  3  cake'
        say '  0  返回'
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
        say '  1  查看实际队列'
        say '  2  更换网卡队列'
        say '  3  恢复原队列'
        say '  0  返回'
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
    case $UI_INPUT in q|Q) return 0 ;; '') ;; *) warn '已取消，未开始测试。'; return 0 ;; esac
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
        say '  1  手动 BBR 配置'
        say '  2  完整诊断'
        say '  3  内核管理'
        say '  4  网卡队列管理'
        say '  5  设备方案详情'
        say '  6  仅预演 BBR 配置'
        say '  7  全部命令行用法'
        say '  8  比较历史测速结果'
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
        say ''; say '  0  退出   r  刷新'
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
    # A concurrent first run may create it between the test and mkdir; the
    # operation lock, not this mkdir, is what serialises modifications.
    [[ -d $STATE_DIR ]] || mkdir -m 700 -- "$STATE_DIR" 2>/dev/null || [[ -d $STATE_DIR ]] ||
        { fail "无法创建状态目录：$STATE_DIR"; return 1; }
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
    # The rename must be durable too: the destination may live on another
    # filesystem than the staged file (e.g. /etc and /var/lib).
    if ! cat -- "$src" > "$temp" || ! chmod 600 -- "$temp" || ! sync -f "$temp" ||
        ! mv -fT -- "$temp" "$dest"; then
        rm -f -- "$temp"; return 1
    fi
    # Best effort: the rename already succeeded and some filesystems reject
    # syncfs, so a failure here must not turn a written file into an error.
    sync -f -- "${dest%/*}" 2>/dev/null || warn "配置已写入，但目录同步失败：${dest%/*}"
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
    trap 'exit 131' QUIT
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
    [[ -d $TX_DIR && ! -L $TX_DIR ]] || { fail "事务记录不存在或不可用：$TX_DIR"; return 1; }
    local cc qd target_cc target_qd value
    cc=$(cat "$TX_DIR/snapshot/before.cc") || { fail '事务缺少原始算法记录，保留现场'; return 1; }
    qd=$(cat "$TX_DIR/snapshot/before.qd") || { fail '事务缺少原始队列记录，保留现场'; return 1; }
    target_cc=$(cat "$TX_DIR/target.cc") || { fail '事务缺少目标算法记录，保留现场'; return 1; }
    target_qd=$(cat "$TX_DIR/target.qd") || { fail '事务缺少目标队列记录，保留现场'; return 1; }
    for value in "$cc" "$qd" "$target_cc" "$target_qd"; do
        valid_value "$value" || { fail '事务记录内容不合法，保留现场'; return 1; }
    done
    read_pair || return 1
    [[ $PAIR_CC == "$cc" || $PAIR_CC == "$target_cc" ]] &&
        [[ $PAIR_QD == "$qd" || $PAIR_QD == "$target_qd" ]] || { fail '事务后运行参数有外部修改，拒绝覆盖。'; return 1; }
    [[ ! -L $CONFIG ]] || { fail '配置路径是符号链接，拒绝恢复'; return 1; }
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
    # A repeated Ctrl+C must not interrupt the rollback itself.
    trap '' HUP INT QUIT TERM
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
    trap - EXIT INT QUIT TERM HUP
    log_event "$kind completed" || warn '操作成功，但日志记录失败。'
}
# Run one privileged operation in a monitored subshell and forward termination
# signals to it. A signal delivered to this process alone (timeout, pkill, a
# supervisor) must not orphan the subshell and let it keep changing the system
# after the caller was told the command had failed.
forward_signal() {
    local signal=$1 code=$2 child=$3
    if [[ -n $child ]] && kill -0 -- "$child" 2>/dev/null; then
        kill -s "$signal" -- "$child" 2>/dev/null || :
        wait "$child" 2>/dev/null || :
        exit "$code"
    fi
}
run_isolated() {
    local action=$1 child='' rc=0
    # Install the forwarders before the fork so no signal can slip through the
    # window between starting the child and being able to signal it.
    trap 'forward_signal TERM 143 "$child"' TERM
    # Forward as TERM: an asynchronous child may inherit SIGINT/SIGQUIT as
    # ignored, and an ignored signal cannot be trapped again. TERM can always be
    # trapped, and every operation uses the same rollback handler for all of them.
    trap 'forward_signal TERM 130 "$child"' INT
    trap 'forward_signal HUP 129 "$child"' HUP
    trap 'forward_signal TERM 131 "$child"' QUIT
    ( "$action" ) <&0 &
    child=$!
    wait "$child" || rc=$?
    trap - HUP INT QUIT TERM
    return "$rc"
}
enable_bbr() { run_isolated enable_bbr_impl; }
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
    if (( AUTO )); then show_change_plan || return 1
    else
        ui_heading '配置变更'
        ui_change '新连接算法' "${CURRENT_CC:-}" bbr
        ui_change '默认队列' "${CURRENT_QDISC:-}" "$QUEUE"
        say '  保留当前网卡队列、TCP 缓冲区和内核，不自动重启。'
    fi
    require_mutation || return 1
    prepare_state && acquire_lock || return 1
    secure_path "$CONFIG" && secure_path "$LOG" || return 1
    [[ ! -e $STATE_DIR/transaction ]] || { fail '存在未完成事务，请运行 restore。'; return 1; }
    check_managed_file && detect_conflicts && ensure_modules || return 1
    read_pair || return 1
    local result_cc=$PAIR_CC result_qd=$PAIR_QD
    if [[ -f $STATE_DIR/applied.conf && -f $STATE_DIR/applied.qd && $PAIR_CC == bbr && $PAIR_QD == "$QUEUE" ]] &&
        [[ $(cat "$STATE_DIR/applied.qd") == "$QUEUE" ]] && cmp -s "$CONFIG" <(render_config bbr "$QUEUE"); then
        valid_snapshot "$STATE_DIR/baseline" || { fail '原始备份不完整，拒绝跳过检查'; return 1; }
        config_result 'BBR 配置已一致' "$result_cc" "$result_qd" bbr "$QUEUE" unchanged; return $?
    fi
    begin_transaction bbr "$QUEUE" || return 1
    log_event "enable begin qdisc=$QUEUE" || return 1
    write_managed_config && set_pair bbr "$QUEUE" || return 1
    finish_transaction enable || return 1
    config_result 'BBR 配置已启用' "$result_cc" "$result_qd" bbr "$QUEUE"
}
restore_state() { run_isolated restore_state_impl; }
restore_state_impl() {
    if (( DRY_RUN )); then say "预演：检查并恢复 $STATE_DIR 中的原配置与运行参数；不会删除其他配置。"; return 0; fi
    ensure_dependencies sysctl flock awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat || return $?
    detect_system; require_mutation recovery || return 1
    prepare_state && acquire_lock || return 1
    secure_path "$CONFIG" && secure_path "$LOG" || return 1
    TX_DIR="$STATE_DIR/transaction"
    if [[ -d $TX_DIR ]]; then
        rollback_transaction || {
            fail "中断事务无法自动恢复；已原样保留 $TX_DIR。核对后如确认不再需要，可手工删除该目录再重试。"
            return 1
        }
        log_event 'recovered interrupted transaction' || return 1
        ui_banner '执行成功' '中断事务已恢复'
        ui_field '默认 TCP' "$(sys_value net.ipv4.tcp_congestion_control || printf '无法读取')"
        ui_field '默认队列' "$(sys_value net.core.default_qdisc || printf '无法读取')"
        say '  如需恢复第一次启用前的状态，再运行 restore。'
        return 0
    fi
    [[ -d $STATE_DIR/baseline ]] || { ui_banner '无需修改' '没有可恢复的原始状态'; return 0; }
    check_managed_file || return 1
    local cc qd applied_qd
    cc=$(cat "$STATE_DIR/baseline/before.cc") || { fail "原始备份缺少算法记录：$STATE_DIR/baseline"; return 1; }
    qd=$(cat "$STATE_DIR/baseline/before.qd") || { fail "原始备份缺少队列记录：$STATE_DIR/baseline"; return 1; }
    { valid_value "$cc" && valid_value "$qd"; } ||
        { fail '原始备份内容不合法；请核对历史恢复记录后手工处理'; return 1; }
    detect_conflicts "$cc" "$qd" || return 1
    read_pair || return 1
    local result_cc=$PAIR_CC result_qd=$PAIR_QD
    # Failed enable may leave a baseline with no applied state: it is already original.
    if [[ ! -f $STATE_DIR/applied.conf ]]; then
        [[ $PAIR_CC == "$cc" && $PAIR_QD == "$qd" ]] || { fail '运行参数已改变，拒绝覆盖'; return 1; }
        config_result '原状态未改变' "$result_cc" "$result_qd" "$cc" "$qd" unchanged; return $?
    fi
    applied_qd=$(cat "$STATE_DIR/applied.qd") || return 1
    [[ $PAIR_CC == bbr && $PAIR_QD == "$applied_qd" ]] || { fail '运行参数已被外部修改，拒绝覆盖。'; return 1; }
    begin_transaction "$cc" "$qd" restore || return 1
    log_event 'restore begin' || return 1
    write_managed_config && set_pair "$cc" "$qd" || return 1
    finish_transaction restore || return 1
    config_result '原配置与运行参数已恢复' "$result_cc" "$result_qd" "$cc" "$qd" restored
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
        if has "$tool"; then ui_check ok "$tool：可用"; else warn "缺少 $tool"; fi
    done
    probe_tcp || rc=1
    if has ss; then say '现有 TCP 连接（算法与统计由 ss 输出）：'; ss -tin || rc=1; fi
    # Diagnose persistence against the observed running values, not enable's
    # bbr/fq defaults. Missing values must not silently fall back to those defaults.
    if valid_value "${CURRENT_CC:-}" && valid_value "${CURRENT_QDISC:-}"; then
        detect_conflicts "$CURRENT_CC" "$CURRENT_QDISC" || rc=1
    else
        fail '无法核对持久配置：当前算法或默认队列未可靠读取。'
        rc=1
    fi
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
    if not q[0].get('root'):
        raise ValueError('根队列不是 root，拒绝修改')
    if q[0].get('kind')!='fq_codel':
        raise ValueError('当前根队列为 %s：自动更换与可验证回滚只在原始为单个 fq_codel 时可用；'
                         '本脚本不会自动替换该拓扑；请先手工记录 tc qdisc show dev <网卡>' % q[0].get('kind'))
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
archive_queue_snapshot() {
    local dir=$1 history
    history=$(mktemp -d "$STATE_DIR/queue-restored.XXXXXXXX") || return 1
    mv -- "$dir" "$history/snapshot" || return 1
    sync -f "$STATE_DIR" || warn '队列快照已归档，但文件系统同步失败，请核对磁盘状态。'
}
rollback_queue() {
    local dir=$1 iface
    iface=$(cat "$dir/interface") || { fail '队列快照缺少网卡记录，保留现场'; return 1; }
    [[ $iface =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ ]] || { fail "队列快照网卡名不合法：$iface"; return 1; }
    # A queue change lives in memory only. Once the device is gone or the
    # machine has rebooted, the old snapshot can never be re-applied and must
    # not block every later queue operation.
    if [[ ! -e /sys/class/net/$iface ]] && { ! has ip || ! ip link show dev "$iface" >/dev/null 2>&1; }; then
        archive_queue_snapshot "$dir" || return 1
        say "网卡 $iface 已不存在，此前的队列修改随之失效；已归档旧快照。"
        return 0
    fi
    if [[ -s $dir/boot_id && -r /proc/sys/kernel/random/boot_id ]] &&
        [[ $(cat "$dir/boot_id") != "$(< /proc/sys/kernel/random/boot_id)" ]]; then
        archive_queue_snapshot "$dir" || return 1
        say '系统已重启，此前的队列修改仅在当时的运行中生效；已归档旧快照（当前队列保持现状）。'
        return 0
    fi
    if queue_matches "$iface" "$dir/before.json"; then :
    elif [[ -f $dir/after.json ]] && queue_matches "$iface" "$dir/after.json"; then
        ensure_no_queue_filters "$iface" || return 1
        local -a args
        mapfile -t args < "$dir/before.args"
        tc qdisc replace dev "$iface" root "${args[@]}" || return 1
        queue_matches "$iface" "$dir/before.json" || { fail '队列恢复后校验失败'; return 1; }
    else
        fail "队列与已知快照不一致，拒绝覆盖；原始参数在 $dir/before.args"
        fail "确认无需恢复该队列后，可手工删除 $dir 再重试。"
        return 1
    fi
    archive_queue_snapshot "$dir" || return 1
    say "已恢复 $iface 原队列；仅本次运行生效，未修改启动服务。"
}
queue_exit() {
    local rc=$1
    # A repeated Ctrl+C must not interrupt the rollback itself.
    trap '' HUP INT QUIT TERM
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

set_queue() { run_isolated set_queue_impl; }
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
    printf '%s\n' "$IFACE" > "$temp/interface" || { rm -rf -- "$temp"; return 1; }
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        cat /proc/sys/kernel/random/boot_id > "$temp/boot_id" || { rm -rf -- "$temp"; return 1; }
    fi
    ensure_queue_module || { rm -rf -- "$temp"; return 1; }
    prepare_queue_target "$temp/after.json" || { rm -rf -- "$temp"; return 1; }
    sync -f "$temp" || { rm -rf -- "$temp"; return 1; }
    if ! queue_matches "$IFACE" "$temp/before.json" || ! ensure_no_queue_filters; then
        fail '预检期间队列或过滤器发生变化，停止修改'
        rm -rf -- "$temp"; return 1
    fi
    log_event "queue begin interface=$IFACE qdisc=$QUEUE" || { rm -rf -- "$temp"; return 1; }
    mv -T -- "$temp" "$STATE_DIR/queue.pending" || { rm -rf -- "$temp"; return 1; }
    QUEUE_ACTIVE=1
    trap 'queue_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    trap 'exit 131' QUIT
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
    local previous_kind
    previous_kind=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["kind"])' < "$STATE_DIR/queue-state/before.json") || previous_kind=''
    ui_heading '网卡队列结果'
    ui_field '网卡' "$IFACE"
    ui_change '根队列算法' "$previous_kind" "$QUEUE" actual
    say '  [已更新] 队列参数已与目标快照读回比对。'
    say '  [保持不变] 默认 TCP 算法、系统启动配置。'
    say '  生效范围：本次运行；重启后不自动重建。'
    ui_field '恢复命令' 'bash bbr.sh queue-restore'
}
restore_queue() { run_isolated restore_queue_impl; }
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
lines=[];skipped=[]
core=set()
if codename:core={codename,codename+'-updates',codename+'-security'}
def skip(uri,suite,reason):
    skipped.append('%s %s：%s'%(uri,suite,reason))
    return False
def emit(uri,suite,components,opts=''):
    u=urllib.parse.urlsplit(uri)
    official=u.hostname in allowed or (distro=='ubuntu' and (u.hostname or '').endswith('.archive.ubuntu.com'))
    # Only the release, -updates and -security suites of the distribution's own
    # archive are used. Extra suites (backports, proposed) and third-party
    # mirrors are skipped instead of aborting the installation: the kernel never
    # comes from them, and one unrelated source must not block a supported host.
    if not core: raise ValueError('无法确定发行版代号，拒绝猜测仓库')
    if not official: return skip(uri,suite,'非发行版官方主机')
    if suite not in core: return skip(uri,suite,'非正式/更新/安全套件')
    if (u.scheme not in ('http','https') or u.username or u.password
        or u.port or u.query or u.fragment): raise ValueError('发行版官方仓库地址不合法')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]*',u.path): raise ValueError('仓库路径不合法')
    if not components or any(not re.fullmatch(r'[a-z0-9-]+',x) for x in components):
        raise ValueError('仓库组件不合法')
    low=opts.lower()
    if re.search(r'(trusted\s*[=:]\s*yes|allow-insecure\s*[=:]\s*(yes|true)|check-valid-until\s*[=:]\s*no)',low):
        raise ValueError('拒绝关闭验证的仓库选项')
    lines.append('deb [signed-by='+key+'] '+uri+' '+suite+' '+' '.join(components))
    return True
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
                if not line:continue
                if line.split()[0]=='deb-src':continue
                m=re.fullmatch(r'deb\s+(?:\[([^\]]*)\]\s+)?(\S+)\s+(\S+)\s+(.+)',line)
                if not m: raise ValueError('无法解析 sources.list')
                opts,uri,suite,components=m.groups();emit(uri,suite,components.split(),opts or '')
    if skipped:
        print('以下仓库不参与本次内核安装：',file=sys.stderr)
        for item in skipped:print('  已跳过 '+item,file=sys.stderr)
    if not lines:raise ValueError('没有可使用的发行版官方核心仓库（需要 %s 或其 -updates / -security）'%codename)
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
        env=$(grub-editenv - list) || return 1
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
        grub-editenv - unset next_entry || return 1
        observed=$(grub-editenv - list) || return 1
        saved=$(printf '%s\n' "$observed" | sed -n 's/^saved_entry=//p')
        [[ $saved == "$BOOT_ENTRY" && $observed != *next_entry=* ]] || { fail 'GRUB 启动项读回校验失败'; return 1; }
    else return 1; fi
}
read_boot_default() {
    local mode=$1 env
    case $mode in
        grubby) grubby --default-kernel ;;
        grub)
            env=$(grub-editenv - list) || return 1
            [[ $env != *next_entry=* ]] || return 1
            printf '%s\n' "$env" | sed -n 's/^saved_entry=//p' ;;
        *) return 1 ;;
    esac
}
# grub-set-default and grubby only write their metadata; neither checks that the
# recorded entry still exists. Restoring a stale entry would look successful and
# silently fall back to the menu default at the next boot.
boot_entry_available() {
    case $BOOT_MODE in
        grub)
            [[ -r /boot/grub/grub.cfg ]] || return 1
            grep -Fq -- "${BOOT_ENTRY##*>}" /boot/grub/grub.cfg ;;
        grubby)
            [[ -f $BOOT_ENTRY ]] && grubby --info="$BOOT_ENTRY" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}
verify_kernel_switch() {
    local dir="$STATE_DIR/kernel.pending" target entry mode observed history
    # A journal without target records means the install died while packages
    # were still being changed; reporting success here would be a lie.
    if [[ -d $dir && ! -f $dir/target-version ]]; then
        fail '存在未完成的内核事务且缺少目标内核记录；请先运行 kernel recover 恢复原默认启动项。'
        return 1
    fi
    [[ -f $dir/target-version ]] || dir="$STATE_DIR/kernel-switched"
    [[ -f $dir/target-version ]] || return 0
    target=$(cat "$dir/target-version") && entry=$(cat "$dir/target-entry") && mode=$(cat "$dir/mode") || return 1
    [[ $target =~ ^[0-9][a-zA-Z0-9.+_~-]*$ ]] || { fail '目标内核记录不合法'; return 1; }
    [[ -n $entry && $entry != -* && $entry != *$'\n'* && $entry != *$'\r'* ]] || { fail '目标启动项记录不合法'; return 1; }
    ui_heading '内核切换核验'
    ui_field '目标内核' "$target"
    ui_field '运行内核' "$(uname -r)"
    [[ $(uname -r) == "$target" ]] || { fail '尚未运行目标内核；保留恢复记录，请检查控制台启动结果。'; return 1; }
    observed=$(read_boot_default "$mode") || { fail '无法读取默认启动项，暂不确认切换'; return 1; }
    [[ $observed == "$entry" ]] || { fail '默认启动项与目标不一致，暂不确认切换'; return 1; }
    if [[ $dir == "$STATE_DIR/kernel.pending" ]]; then
        if (( DRY_RUN )); then
            say '  [预演] 仅核验运行值，不写锁文件或归档恢复记录。'
        elif (( EUID == 0 )); then
            prepare_state && acquire_lock || return 1
            # Recheck the journal under lock: no concurrent recovery or install.
            [[ $(cat "$dir/target-version") == "$target" && $(cat "$dir/target-entry") == "$entry" ]] || return 1
            [[ $(read_boot_default "$mode") == "$entry" ]] || return 1
            if [[ -d $STATE_DIR/kernel-switched ]]; then
                history=$(mktemp -d "$STATE_DIR/kernel-history.XXXXXXXX") || return 1
                mv -- "$STATE_DIR/kernel-switched" "$history/previous-switch" || return 1
            fi
            mv -- "$dir" "$STATE_DIR/kernel-switched" || return 1
            sync -f "$STATE_DIR" || return 1
        else say '  运行值匹配；以 root 再运行 kernel verify 完成恢复记录归档。'; fi
    fi
    ui_banner '执行成功' '目标内核已运行，默认启动项已核验'
    say '  旧内核仍保留；kernel recover 可恢复原默认启动项。'
}

kernel_verify() {
    say "当前运行内核：$(uname -r)"
    say 'BBR 实现版本：未知；发行版包签名不证明 BBRv3，不凭 bbr 名称判断。'
    if has dpkg-query; then dpkg-query -W -f='${binary:Package} ${Version} ${db:Status-Abbrev}\n' 'linux-image*' 2>/dev/null || :
    elif has rpm; then rpm -q kernel kernel-core || :; fi
    [[ ! -r /var/run/reboot-required ]] || say '发行版提示需要重启；仅 kernel install 成功切换时自动重启。'
    if [[ -r $STATE_DIR/kernel-before ]]; then
        say "安装前运行内核：$(cat "$STATE_DIR/kernel-before")"
        [[ $(cat "$STATE_DIR/kernel-before") != "$(uname -r)" ]] || say '运行内核尚未改变；安装成功不等于已启动新内核。'
    fi
    verify_kernel_switch
}
kernel_plan() {
    detect_system
    local package
    package=$(kernel_package) || return 1
    say "内核计划：$OS_ID $OS_VERSION / $ARCH；软件包 $package；通道 $CHANNEL。"
    say '安装前要求：官方签名仓库、可核验的旧内核与固定启动项、/boot 至少 700 MiB、模块目录至少 2 GiB 空间。'
    say '保留旧内核；成功安装并校验后，设置新内核默认启动，10 秒后自动重启。'
    say '找不到更新内核、启动项有歧义或任一步失败时，不重启；失败恢复原默认启动项。'
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
    trap '' HUP INT QUIT TERM
    stop_kernel_child
    exit "$rc"
}

begin_kernel_journal() {
    [[ ! -e $STATE_DIR/kernel.pending ]] || { fail '存在待确认的内核事务，请先 kernel verify 或 kernel recover'; return 1; }
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
    trap 'kernel_signal 131' QUIT
    sync -f "$STATE_DIR" || return 1
}
recover_kernel_journal() {
    [[ -d $STATE_DIR/kernel.pending ]] || { say '没有待恢复的内核启动项。'; return 0; }
    local dir="$STATE_DIR/kernel.pending" history
    BOOT_MODE=$(cat "$dir/mode") || return 1
    BOOT_ENTRY=$(cat "$dir/entry") || return 1
    case $BOOT_MODE in grub|grubby) ;; *) fail '未知的启动恢复模式'; return 1 ;; esac
    [[ -n $BOOT_ENTRY && $BOOT_ENTRY != -* && $BOOT_ENTRY != *$'\n'* && $BOOT_ENTRY != *$'\r'* ]] || { fail '启动项记录不合法'; return 1; }
    boot_entry_available || {
        fail "原默认启动项已不在启动配置中：$BOOT_ENTRY"
        fail '保留恢复记录；请通过控制台核对该内核是否仍安装后再手工处理。'
        fail "确认该内核已卸载、无需回退后，可手工删除 $dir 再重试。"
        return 1
    }
    preserve_boot || { fail '启动项恢复失败，请通过控制台检查；保留恢复记录'; return 1; }
    history=$(mktemp -d "$STATE_DIR/kernel-history.XXXXXXXX") || return 1
    mv -- "$dir" "$history/journal" || return 1
    KERNEL_ACTIVE=0
    log_event 'kernel original boot entry restored' || warn '日志失败'
    say '原默认启动项已恢复；这不会卸载部分安装的内核，请核对包管理器状态。'
}
kernel_exit() {
    local rc=$1
    trap '' HUP INT QUIT TERM
    stop_kernel_child
    if (( KERNEL_ACTIVE )); then
        warn '内核操作退出，恢复原默认启动项。'
        recover_kernel_journal || { warn '默认启动项可能仍指向新内核；请通过控制台核对后执行 kernel recover，勿直接重启。'; rc=1; }
    fi
    trap - EXIT; exit "$rc"
}
kernel_recover() { run_isolated kernel_recover_impl; }
kernel_recover_impl() {
    if (( DRY_RUN )); then say '预演：从内核事务或已确认切换记录恢复原默认启动项，不卸载软件包。'; return 0; fi
    ensure_dependencies sysctl flock awk stat mktemp cp mv chmod sync rm mkdir rmdir grep cmp date uname cat || return $?
    detect_system; require_mutation recovery || return 1
    prepare_state && acquire_lock || return 1
    if [[ ! -e $STATE_DIR/kernel.pending && -d $STATE_DIR/kernel-switched ]]; then
        mv -- "$STATE_DIR/kernel-switched" "$STATE_DIR/kernel.pending" || return 1
    fi
    recover_kernel_journal
}
vendor_key_owned() {
    local owner
    owner=$(rpm -qf --qf '%{NAME}' -- "$1") || return 1
    [[ $owner == "$2" ]] || { fail '所选签名 key 不属于已验证的发行版 key 软件包'; return 1; }
}
install_rpm_kernel() {
    local key_package keys key dir rpmfile metadata
    KERNEL_VERIFIED_VERSIONS=''
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
        metadata=$(rpm -qp --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}' "$rpmfile") || return 1
        if [[ $metadata == kernel-core$'\t'* ]]; then
            KERNEL_VERIFIED_VERSIONS+="${metadata#*$'\t'}"$'\n'
        fi
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

# Resolve only the image dependencies of the exact distro metapackage installed
# by this transaction. Unrelated pre-existing/custom images are never candidates.
kernel_inventory() {
    local output root version
    if [[ $OS_ID == debian || $OS_ID == ubuntu ]]; then
        root=$(kernel_package) || return 1
        output=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Depends}\t${Pre-Depends}\n') || return 1
        python3 /dev/fd/3 "$root" 3<<'PYCODE' <<< "$output"
import re,sys
try:
    packages={}
    for line in sys.stdin:
        fields=line.rstrip('\n').split('\t')
        if len(fields)<2 or fields[1]!='installed':continue
        name=fields[0].split(':')[0]
        if name!=sys.argv[1] and not name.startswith('linux-image-'):continue
        if name in packages:raise ValueError('软件包架构存在歧义')
        packages[name]=','.join(fields[2:])
    queue=[sys.argv[1]];seen=set();images=[]
    while queue:
        name=queue.pop()
        if name in seen:continue
        seen.add(name)
        if name not in packages:raise ValueError('内核依赖未安装：'+name)
        if re.fullmatch(r'linux-image-[0-9][a-zA-Z0-9.+_~-]*',name):
            images.append((name[len('linux-image-'):],name));continue
        for group in packages[name].split(','):
            choices=[]
            for alt in group.split('|'):
                m=re.match(r'\s*([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?',alt)
                if m and m[1].startswith('linux-image-') and m[1] in packages:choices.append(m[1])
            if len(choices)>1:raise ValueError('内核镜像依赖存在歧义')
            queue.extend(choices)
    if len(images)!=1:raise ValueError('无法唯一确定发行版元包依赖的内核镜像')
    for release,name in images:print(release+'\t'+name)
except ValueError as e:
    print('内核依赖检查失败：'+str(e),file=sys.stderr);sys.exit(1)
PYCODE
    else
        # Only versions extracted from RPMs verified against the vendor keyring
        # in install_rpm_kernel may be selected for an automatic reboot.
        while IFS= read -r version; do
            [[ -n $version ]] || continue
            [[ $version =~ ^[0-9][a-zA-Z0-9.+_~-]*$ ]] || return 1
            rpm -q "kernel-core-$version" >/dev/null || return 1
            printf '%s\tkernel-core-%s\n' "$version" "$version"
        done <<< "${KERNEL_VERIFIED_VERSIONS:-}"
    fi
}
select_new_kernel() {
    local inventory running latest version package
    running=$(uname -r) || return 1
    inventory=$(kernel_inventory) || { fail '无法读取可信事务的内核候选'; return 1; }
    [[ -n $inventory ]] || return 3
    latest=$( { printf '%s\n' "$running"; while IFS=$'\t' read -r version package; do
        [[ $version =~ ^[0-9][a-zA-Z0-9.+_~-]*$ ]] || return 1
        printf '%s\n' "$version"
    done <<< "$inventory"; } | sort -V | tail -n 1) || return 1
    [[ -n $latest && $latest != "$running" ]] || return 3
    TARGET_VERSION=$latest TARGET_PACKAGE=''
    while IFS=$'\t' read -r version package; do
        [[ $version != "$latest" ]] || TARGET_PACKAGE=$package
    done <<< "$inventory"
    [[ -n $TARGET_PACKAGE ]] || return 1
    TARGET_IMAGE="/boot/vmlinuz-$TARGET_VERSION"
}
validate_kernel_target() {
    local initrd check module_dir config="/boot/config-$TARGET_VERSION"
    [[ $TARGET_VERSION =~ ^[0-9][a-zA-Z0-9.+_~-]*$ && $TARGET_IMAGE == "/boot/vmlinuz-$TARGET_VERSION" ]] || return 1
    if [[ $OS_ID == debian || $OS_ID == ubuntu ]]; then initrd="/boot/initrd.img-$TARGET_VERSION"
    else initrd="/boot/initramfs-$TARGET_VERSION.img"; fi
    local file
    for file in "$TARGET_IMAGE" "$initrd" "$config"; do
        secure_path "$file" && [[ -f $file && -s $file ]] || { fail "新内核启动文件缺失或不安全：$file"; return 1; }
    done
    module_dir=$(readlink -f -- "/lib/modules/$TARGET_VERSION") || return 1
    [[ $module_dir == "/lib/modules/$TARGET_VERSION" || $module_dir == "/usr/lib/modules/$TARGET_VERSION" ]] || { fail '模块目录位于未知位置'; return 1; }
    secure_path "$module_dir" || return 1
    [[ -d $module_dir ]] || { fail '新内核模块目录缺失'; return 1; }
    grep -Eq '^CONFIG_TCP_CONG_BBR=(y|m)$' "$config" || { fail '目标内核未启用 BBR 支持'; return 1; }
    case $(uname -m) in
        x86_64) grep -qx 'CONFIG_X86_64=y' "$config" || return 1 ;;
        aarch64) grep -qx 'CONFIG_ARM64=y' "$config" || return 1 ;;
        *) fail '目标内核架构未适配'; return 1 ;;
    esac
    if grep -qx 'CONFIG_TCP_CONG_BBR=m' "$config"; then
        local bbr_module=0
        for file in "$module_dir"/kernel/net/ipv4/tcp_bbr.ko{,.xz,.zst,.gz}; do
            [[ ! -f $file || ! -s $file ]] || bbr_module=1
        done
        (( bbr_module )) || { fail '目标内核 BBR 模块缺失'; return 1; }
    fi
    if [[ $OS_ID == debian || $OS_ID == ubuntu ]]; then
        if ! has lsinitramfs || ! lsinitramfs "$initrd" >/dev/null; then
            fail '需要可用的 lsinitramfs 且目标 initramfs 必须可解包'; return 1
        fi
    else
        if ! has lsinitrd || ! lsinitrd "$initrd" >/dev/null; then
            fail '需要可用的 lsinitrd 且目标 initramfs 必须可解析'; return 1
        fi
    fi
    if [[ $OS_ID == debian || $OS_ID == ubuntu ]]; then
        check=$(dpkg --verify "$TARGET_PACKAGE") || { fail '目标内核软件包文件校验失败'; return 1; }
        # Minimal systems intentionally exclude packaged documentation. Missing
        # docs do not affect boot integrity; all other verification output blocks.
        check=$(printf '%s\n' "$check" | awk '!/^missing[[:space:]]+\/usr\/share\/(doc|man)\//') || return 1
    else check=$(rpm -V "$TARGET_PACKAGE") || { fail '目标内核软件包文件校验失败'; return 1; }; fi
    [[ -z $check ]] || { fail '目标内核软件包存在被修改的文件'; return 1; }
    TARGET_INITRD=$initrd
}
select_grub_kernel_entry() {
    python3 - "$@" <<'PYCODE'
import pathlib,re,shlex,sys
try:
    cfg,new,old,saved=sys.argv[1:]
    previous=saved.split('>')[-1]
    prefix='gnulinux-'+old+'-advanced-'
    if not previous.startswith(prefix):raise ValueError('原启动项不是可识别的普通内核 ID')
    disk=previous[len(prefix):]
    if not re.fullmatch(r'[a-zA-Z0-9-]+',disk):raise ValueError('启动项磁盘标识不合法')
    submenu='gnulinux-advanced-'+disk
    if '>' in saved and saved.rsplit('>',1)[0]!=submenu:raise ValueError('原启动项层级无法确认')
    target='gnulinux-'+new+'-advanced-'+disk
    menus=0;matches=[];entry=None;in_submenu=False
    def finish():
        global entry
        if entry is not None and entry[0]==target:matches.append(entry)
        entry=None
    for line in pathlib.Path(cfg).read_text().splitlines():
        stripped=line.strip()
        if re.match(r'^(submenu|menuentry)\s',stripped):
            finish()
            m=re.search(r'(?:--id|\$menuentry_id_option)\s+([\'\"])(.*?)\1',stripped)
            ident=m[2] if m else ''
            if stripped.startswith('submenu '):
                in_submenu=ident==submenu
                if in_submenu:menus+=1
            else:entry=[ident,[],[],in_submenu]
        elif stripped=='}':
            if entry is not None:finish()
            else:in_submenu=False
        elif entry is not None:
            fields=shlex.split(stripped,comments=True)
            if fields and fields[0] in ('linux','linuxefi') and len(fields)>1:entry[1].append(fields[1])
            elif fields and fields[0] in ('initrd','initrdefi'):entry[2].extend(fields[1:])
    finish()
    if menus!=1 or len(matches)!=1:raise ValueError('目标启动项缺失或存在歧义')
    _,images,initrds,nested=matches[0]
    if not nested or len(images)!=1 or images[0] not in ('/vmlinuz-'+new,'/boot/vmlinuz-'+new):raise ValueError('目标启动项内核路径不匹配')
    if not any(p in ('/initrd.img-'+new,'/boot/initrd.img-'+new) for p in initrds):raise ValueError('目标启动项 initramfs 不匹配')
    print(submenu+'>'+target)
except (ValueError,OSError) as e:
    print('启动项检查失败：'+str(e),file=sys.stderr);sys.exit(1)
PYCODE
}
resolve_kernel_boot_entry() {
    local info
    if [[ $BOOT_MODE == grub ]]; then
        TARGET_ENTRY=$(select_grub_kernel_entry /boot/grub/grub.cfg "$TARGET_VERSION" "$(uname -r)" "$BOOT_ENTRY") || return 1
    elif [[ $BOOT_MODE == grubby ]]; then
        info=$(grubby --info="$TARGET_IMAGE") || return 1
        [[ $(printf '%s\n' "$info" | grep -c '^kernel=') == 1 ]] || { fail '目标内核启动项不唯一'; return 1; }
        grep -Fxq "kernel=\"$TARGET_IMAGE\"" <<< "$info" || { fail '目标启动内核路径不匹配'; return 1; }
        grep -Fxq "initrd=\"$TARGET_INITRD\"" <<< "$info" || { fail '目标 initramfs 路径不匹配'; return 1; }
        TARGET_ENTRY=$TARGET_IMAGE
    else fail '不支持的启动器'; return 1; fi
}
# Debian and Ubuntu encode the kernel flavour after the numeric ABI, e.g.
# 6.1.0-13-rt-amd64 or 6.8.0-31-generic. Refuse an automatic switch that would
# silently replace a vendor/RT kernel with a different flavour; names this
# cannot parse are left to the existing package verification instead of guessed.
kernel_flavour_matches() {
    local running=$1 target=$2 running_flavour='' target_flavour=''
    # The flavour suffix is Debian/Ubuntu packaging metadata; RPM releases use a
    # different scheme and are not constrained here.
    [[ $OS_ID == debian || $OS_ID == ubuntu ]] || return 0
    [[ $running =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-(.*)$ ]] && running_flavour=${BASH_REMATCH[1]}
    [[ $target =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-(.*)$ ]] && target_flavour=${BASH_REMATCH[1]}
    [[ -z $running_flavour || -z $target_flavour ]] && return 0
    [[ $running_flavour == "$target_flavour" ]]
}

request_kernel_reboot() {
    if has systemctl && [[ $(cat /proc/1/comm) == systemd ]]; then systemctl reboot
    elif has reboot; then reboot
    else fail '找不到受支持的重启命令'; return 1; fi
}
complete_kernel_switch() {
    local rc=0 original=$BOOT_ENTRY
    select_new_kernel || rc=$?
    if (( rc == 3 )); then
        recover_kernel_journal || return 1
        trap - EXIT INT TERM HUP
        ui_banner '无需修改' '没有比当前运行版本更新的内核，不重启'
        return 0
    fi
    (( rc == 0 )) || return "$rc"
    kernel_flavour_matches "$(uname -r)" "$TARGET_VERSION" || {
        fail "目标内核 $TARGET_VERSION 与运行内核 $(uname -r) 的 flavour 不同"
        fail '自动替换会改变内核形态（如 RT/cloud/aws），已取消切换与重启；请手工安装所需内核。'
        return 1
    }
    validate_kernel_target && resolve_kernel_boot_entry || return 1
    printf '%s\n' "$TARGET_VERSION" > "$STATE_DIR/kernel.pending/target-version" || return 1
    printf '%s\n' "$TARGET_ENTRY" > "$STATE_DIR/kernel.pending/target-entry" || return 1
    sync -f "$STATE_DIR/kernel.pending" || return 1
    BOOT_ENTRY=$TARGET_ENTRY
    preserve_boot || { BOOT_ENTRY=$original; return 1; }
    # The journal retains the original default for explicit or automatic recovery.
    log_event "kernel default switched target=$TARGET_VERSION" || return 1
    ui_banner '执行成功' '新内核已设为默认启动项'
    ui_change '默认启动项' "$original" "$TARGET_ENTRY" actual
    ui_field '下次启动内核' "$TARGET_VERSION"
    say '  [已保留] 旧内核及启动项恢复记录。'
    say '  [待验证] 新内核实际启动情况；不能据此认定 BBRv3。'
    say '  10 秒后自动重启；按 Ctrl+C 取消并恢复原默认启动项。'
    sync || return 1
    sleep 10 || return 1
    # SSH may disconnect as soon as reboot is accepted. Do not roll back a
    # verified default merely because that disconnect sends SIGHUP.
    trap '' HUP INT QUIT TERM
    request_kernel_reboot || { rc=$?; fail '自动重启失败，将恢复原默认启动项'; return "$rc"; }
    KERNEL_ACTIVE=0
    trap - EXIT
    say '  [已请求重启] 重连后运行 kernel verify 核验。'
}

kernel_install() { run_isolated kernel_install_impl; }
kernel_install_impl() {
    say '内核安装成功并切换默认启动项后，将自动重启。'
    detect_system; require_mutation || return 1
    ensure_dependencies python3 setsid sort tail || return $?
    if [[ $OS_ID == debian || $OS_ID == ubuntu ]]; then ensure_dependencies lsinitramfs || return $?
    else ensure_dependencies lsinitrd || return $?; fi
    prepare_state && acquire_lock || return 1
    [[ ! -e $STATE_DIR/kernel.pending ]] || { fail '存在待确认的内核事务，请先 kernel verify 或 kernel recover'; return 1; }
    boot_preflight || return 1
    [[ -d /boot && -d /lib/modules ]] || { fail '缺少 /boot 或 /lib/modules'; return 1; }
    local free_boot free_modules package rc=0 sources='' keyring
    free_boot=$(df -Pk /boot | awk 'END {print $4}') || return 1
    free_modules=$(df -Pk /lib/modules | awk 'END {print $4}') || return 1
    if [[ ! $free_boot =~ ^[0-9]+$ || ! $free_modules =~ ^[0-9]+$ ]] ||
        (( free_boot < 716800 || free_modules < 2097152 )); then fail '启动分区或模块目录空间不足'; return 1; fi
    package=$(kernel_package) || return 1
    if [[ $OS_ID == debian || $OS_ID == ubuntu ]]; then
        # Validate the sources before a journal or boot change exists, so a
        # refused source list leaves nothing to roll back.
        [[ $OS_ID == debian ]] && keyring=/usr/share/keyrings/debian-archive-keyring.gpg || keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
        [[ -s $keyring ]] || { fail '缺少发行版归档签名 keyring'; return 1; }
        OS_CODENAME=$(read_os_field VERSION_CODENAME)
        sources=$(apt_sources /etc/apt) || return 1
    fi
    begin_kernel_journal || return 1
    uname -r > "$STATE_DIR/kernel-before" || return 1
    printf '%s\n' "$BOOT_ENTRY" > "$STATE_DIR/kernel-boot-entry" || return 1
    log_event "kernel install begin distro=$OS_ID package=$package" || return 1
    if [[ $OS_ID == debian || $OS_ID == ubuntu ]]; then
        local pin_text
        local -a pins=()
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
    if (( rc != 0 )); then
        fail "内核包事务失败，退出码 $rc；不重启，恢复原默认启动项。"
        return "$rc"
    fi
    complete_kernel_switch
}
kernel_command() {
    case ${ACTION:-plan} in list|plan|install|verify|recover) ;; *) fail '未知 kernel 子命令'; return 2 ;; esac
    if [[ ${CHANNEL:-distro} == bbr3 ]]; then
        fail '目前没有配置经过核验的可信 BBRv3 签名软件包来源；拒绝下载未知第三方内核。官方研究源码：https://github.com/google/bbr/tree/v3'
        return 1
    fi
    case ${ACTION:-plan} in
        list) detect_system; kernel_verify || return 1; kernel_plan ;;
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
        if 'mean_rtt' in sender:
            rtt=number(sender['mean_rtt'],'RTT')
            # Reverse mode reports 0 when the sender sampled no RTT at all.
            if rtt>0:rtts.append(rtt/1000)
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
    # iperf3 handles SIGINT itself and exits non-zero, so without a flag the next
    # algorithm (or the next suite round) would still run. SIGTERM keeps its
    # conventional immediate-stop behaviour.
    BENCH_INTERRUPTED=0
    trap 'BENCH_INTERRUPTED=1' INT
    for algorithm in "${algorithms[@]}"; do
        (( BENCH_INTERRUPTED == 0 )) || break
        local -a args=(-c "$HOST" -p "$PORT" -t "$DURATION" -P "$STREAMS" -J --connect-timeout 5000)
        if (( REVERSE )); then args+=(-R); else args+=(-C "$algorithm"); fi
        result="$dir/$algorithm.json"
        say "测试请求算法：$algorithm"
        current_rc=0
        # A bounded wall-clock timeout also covers a peer stalling after connect.
        # --foreground keeps iperf3 in this process group so an interactive
        # Ctrl+C reaches it instead of leaving the test running to completion.
        if has timeout; then timeout --foreground --signal=TERM --kill-after=5 "$(( DURATION + 30 ))" iperf3 "${args[@]}" > "$result" 2>"$dir/$algorithm.stderr" || current_rc=$?
        else fail '需要 coreutils timeout 以限制远端测试等待'; return 1; fi
        (( ! BENCH_INTERRUPTED )) || break
        if (( current_rc != 0 )); then
            warn "iperf3 失败，退出码 $current_rc；详情：$dir/$algorithm.stderr"
            (( rc != 0 )) || rc=$current_rc
        fi
        benchmark_summary < "$result" || { (( rc != 0 )) || rc=1; }
    done
    trap - INT
    if (( BENCH_INTERRUPTED )); then
        return 130
    fi
    if (( COMPARE )); then
        say '对比按 cubic → bbr 顺序进行，仅代表这两次测量；路径变化和测试顺序会影响结果。'
    fi
    return "$rc"
}

run_benchmark() {
    if (( ! SUITE )); then
        run_benchmark_once; local rc=$?
        (( rc != 130 )) || warn '测试已中断。'
        return "$rc"
    fi
    [[ -n $HOST ]] || { fail '请指定 --host'; return 2; }
    (( REVERSE == 0 || COMPARE == 0 )) || { fail '反向模式不能使用 --compare'; return 2; }
    ensure_dependencies python3 || return $?
    load_device_resources || return 1
    local pressure=$DEVICE_STREAMS rc=0 current=0 interrupted=0
    (( ! STREAMS_EXPLICIT )) || pressure=$STREAMS
    say '设备测试套件：先单连接，再单独测试并发；每轮使用相同目标、时长和方向。'
    trap 'interrupted=1' INT
    ( STREAMS=1; run_benchmark_once ) || rc=$?
    if (( ! interrupted )) && (( pressure > 1 )); then
        say "并发测试：$pressure 流（手动 --parallel 优先）"
        ( STREAMS=$pressure; run_benchmark_once ) || current=$?
        (( rc != 0 )) || rc=$current
    elif (( ! interrupted )); then
        say '本次并发设置为 1，未重复执行相同条件的测试。'
    fi
    trap - INT
    if (( interrupted )); then
        warn '测试已中断，未继续后续轮次。'
        return 130
    fi
    return "$rc"
}
benchmark_compare() {
    [[ -n $BEFORE && -n $AFTER ]] || { fail '需要 --before 与 --after 两个保存的测速目录'; return 2; }
    has python3 || { fail '结果比较需要 python3'; return 1; }
    python3 - "$BEFORE" "$AFTER" "$UI_BAR_ON" "$UI_BAR_OFF" <<'PY'
import json,pathlib,re,sys,math

def conditions(path):
    d={}
    for line in (path/'conditions.txt').read_text().splitlines():
        k,sep,v=line.partition('=')
        if not sep or k in d:raise ValueError('条件记录格式错误或重复')
        d[k]=v
    return d

def metric(path,algo,allow_fallback=False):
    target=path/(algo+'.json')
    if allow_fallback and not target.is_file():
        # --reverse sends no -C, so the recorded --algorithm can name a file the
        # other run never created; fall back to that directory's single result.
        candidates=[p for p in path.glob('*.json') if p.is_file()]
        if len(candidates)!=1:raise ValueError('缺少结果文件：'+algo+'.json')
        target=candidates[0]
    raw=json.loads(target.read_text())
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
            if val>0:rtts.append(val/1000)
    cc=end.get('sender_tcp_congestion')
    if cc is not None and (not isinstance(cc,str) or not re.fullmatch(r'[A-Za-z0-9_]{1,32}',cc)):raise ValueError('实测算法报告无效')
    return rate,retries,(sum(rtts)/len(rtts) if rtts else None),cc
try:
    before,after=map(pathlib.Path,sys.argv[1:3]);a=conditions(before);b=conditions(after)
    for key in ('host','port','duration','parallel','reverse','compare'):
        if key not in a or key not in b or a[key]!=b[key]:raise ValueError('条件不一致或缺失：'+key)
    # --algorithm only selects the tested socket's algorithm: --reverse leaves
    # it to the server and --compare always runs cubic+bbr, so it must not reject
    # two physically identical runs whose flag merely differed.
    if a['reverse']=='0' and a['compare']=='0':
        if ('requested_algorithm' not in a or 'requested_algorithm' not in b
            or a['requested_algorithm']!=b['requested_algorithm']):
            raise ValueError('条件不一致或缺失：requested_algorithm')
    if 'requested_algorithm' not in a or 'requested_algorithm' not in b:
        raise ValueError('条件缺失：requested_algorithm')
    algo=a['requested_algorithm']
    if not re.fullmatch(r'[A-Za-z0-9_]{1,32}',algo):raise ValueError('算法名称不合法')
    algorithms=['cubic','bbr'] if a['compare']=='1' else [algo]
    fallback=a['reverse']=='1'
    if a['compare'] not in ('0','1'):raise ValueError('compare 条件不合法')
    for algo in algorithms:
        x=metric(before,algo,fallback);y=metric(after,algo,fallback)
        if x[3] and y[3] and x[3]!=y[3]:raise ValueError('实测发送端算法不一致，不能按相同条件比较')
        if a['reverse']=='1' and (not x[3] or not y[3]):raise ValueError('反向测试缺少服务端实测算法，不能确认可比性')
        delta='%+.1f%%'%((y[0]/x[0]-1)*100) if x[0] else '不可计算（原吞吐为 0）'
        fmt=lambda v:'未知' if v is None else (('%d'%v) if type(v) is int else ('%.3f'%v))
        print('%s：吞吐 %.3f → %.3f Mbps（%s）'%(algo,x[0]/1e6,y[0]/1e6,delta))
        peak=max(x[0],y[0]) or 1.0
        def _bar(v,width=18):
            n=max(0,min(width,int(v*width/peak)))
            return sys.argv[3]*n+sys.argv[4]*(width-n)
        print('    优化前 %s  %8.2f Mbps'%(_bar(x[0]),x[0]/1e6))
        print('    优化后 %s  %8.2f Mbps'%(_bar(y[0]),y[0]/1e6))
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
