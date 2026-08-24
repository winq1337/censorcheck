#!/usr/bin/env bash

# -----------------------------------------
# Censor-check script
# Edition version by winq
# -----------------------------------------

TIMEOUT=4
RETRIES=2
MAX_PARALLEL=10
USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
IP_VERSION=4
PROXY=""
VERBOSE=false
DEBUG=false
FORCED_SOURCE_IP=""
BACKEND_ENABLED=true
BACKEND_URL="${BACKEND_URL:-http://185.17.0.25:25444/api/logs}"
RUN_ID="$(date +%s)-$$"
MACHINE_HOSTNAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
MACHINE_KERNEL="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || echo n/a)"
RUN_STATUS="success"
ERROR_MESSAGE=""
FINALIZED=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -d|--debug)
      DEBUG=true
      shift
      ;;
    --source-ip)
      if [[ -z "${2:-}" ]]; then
        echo "Missing value for --source-ip"
        exit 1
      fi
      FORCED_SOURCE_IP="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

DOMAINS=(
  "youtube.com"
  "instagram.com"
  "facebook.com"
  "x.com"
  "patreon.com"
  "linkedin.com"
  "signal.org"
  "tiktok.com"
  "api.telegram.org"
  "web.whatsapp.com"
  "discord.com"
  "viber.com"
  "chatgpt.com"
  "grok.com"
  "reddit.com"
  "twitch.tv"
  "netflix.com"
  "rutracker.org"
  "nnmclub.to"
  "digitalocean.com"
  "api.cloudflare.com"
  "speedtest.net"
  "aws.amazon.com"
  "ooni.org"
  "amnezia.org"
  "torproject.org"
  "proton.me"
  "github.com"
  "google.com"
  "pypi.org"
  "files.pythonhosted.org"
  "bootstrap.pypa.io"
  "registry.npmjs.org"
  "registry.yarnpkg.com"
  "nodejs.org"
  "deb.debian.org"
  "archive.ubuntu.com"
  "security.ubuntu.com"
  "download.docker.com"
  "registry-1.docker.io"
  "production.cloudflare.docker.com"
  "git.kernel.org"
  "repo.anaconda.com"
  "conda.anaconda.org"
  "crates.io"
  "static.crates.io"
)

AI_DOMAINS=(
  "chatgpt.com"
  "grok.com"
  "netflix.com"
)

RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
GREEN="\033[32m"
BLUE="\033[34m"
MAGENTA="\033[35m"
RESET="\033[0m"
BOLD="\033[1m"
ITALIC="\033[3m"
RED_ITALIC="\033[31;3m"
GREEN_ITALIC="\033[32;3m"
YELLOW_ITALIC="\033[33;3m"
BLUE_ITALIC="\033[34;3m"
DIM="\033[2;90m"
SPINNER_FRAMES=('-' '\\' '|' '/')
REVEAL_DELAY=0.03

DOMAIN_WIDTH=34
LINE_SEP="======================================================================"

# Известные DNS-заглушки
RKN_STUB_IPS=(
  "195.208.4.1"    # Ростелеком
  "195.208.5.1"    # Ростелеком
  "188.186.157.35" # MTS
  "80.93.183.168"  # Билайн
  "213.87.154.141" # MTS
  "92.101.255.255" # Мегафон
)

# Провайдеры
declare -A ASN_NAMES=(
  [12389]="Ростелеком"
  [8402]="Билайн"
  [25513]="МГТС"
  [8359]="MTS"
  [3216]="Билайн"
  [20485]="ТТК"
  [25490]="РТК-Юг"
  [43727]="Мегафон"
  [12714]="Мегафон"
  [34757]="Sib Seti"
  [29124]="Iskratelecom"
  [12768]="Дом.ру"
)

is_rkn_spoof() {
  local ip="$1"
  for stub in "${RKN_STUB_IPS[@]}"; do
    [[ "$ip" == "$stub" ]] && return 0
  done
  return 1
}

status_badge() {
  local status="$1"

  case "$status" in
    OK)
      printf "%b" "${GREEN}${BOLD}[ OK ]${RESET}"
      ;;
    BLOCKED)
      printf "%b" "${RED}${BOLD}[ BLOCKED ]${RESET}"
      ;;
    PARTIAL)
      printf "%b" "${YELLOW}${BOLD}[ PARTIAL ]${RESET}"
      ;;
    *)
      printf "%b" "${DIM}[ ${status} ]${RESET}"
      ;;
  esac
}

init_log_files() {
  MAIN_LOG_FILE=$(mktemp)
  DEBUG_LOG_FILE=$(mktemp)
}

append_log_line() {
  local target_file="$1"
  shift
  [[ -n "$target_file" ]] || return 0
  printf "%s\n" "$*" >> "$target_file"
}

log_debug_line() {
  local line="$1"
  printf "%s\n" "$line"
  append_log_line "$DEBUG_LOG_FILE" "$line"
}

collect_system_snapshot() {
  # Собираем runtime-метрики, чтобы алерты включали контекст по железу и нагрузке.
  # Это помогает точнее отлаживать скрипт и сравнивать поведение на разных хостах.
  local cpu_model cpu_cores mem_total_mb mem_available_mb disk_total_kb disk_used_kb disk_free_kb
  local load1 load5 load15 proc_count

  cpu_model="$(awk -F': ' '/model name|Hardware|Processor/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  cpu_cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo '')"
  mem_total_mb="$(awk '/MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)"
  mem_available_mb="$(awk '/MemAvailable:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)"
  read -r disk_total_kb disk_used_kb disk_free_kb < <(df -Pk / 2>/dev/null | awk 'NR==2 {print $2, $3, $4}')
  read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || true
  proc_count="$(find /proc -maxdepth 1 -type d -regex '/proc/[0-9]+' 2>/dev/null | wc -l | awk '{print $1}')"

  SYSTEM_CPU_MODEL="${cpu_model:-unknown}"
  SYSTEM_CPU_CORES="${cpu_cores:-0}"
  SYSTEM_MEM_TOTAL_MB="${mem_total_mb:-0}"
  SYSTEM_MEM_AVAILABLE_MB="${mem_available_mb:-0}"
  SYSTEM_DISK_TOTAL_GB="$(awk -v value="${disk_total_kb:-0}" 'BEGIN {printf "%.1f", value / 1024 / 1024}')"
  SYSTEM_DISK_USED_GB="$(awk -v value="${disk_used_kb:-0}" 'BEGIN {printf "%.1f", value / 1024 / 1024}')"
  SYSTEM_DISK_FREE_GB="$(awk -v value="${disk_free_kb:-0}" 'BEGIN {printf "%.1f", value / 1024 / 1024}')"
  SYSTEM_LOAD1="${load1:-0}"
  SYSTEM_LOAD5="${load5:-0}"
  SYSTEM_LOAD15="${load15:-0}"
  SYSTEM_PROCESS_COUNT="${proc_count:-0}"
}

send_backend_file() {
  local kind="$1"
  local file_path="$2"

  if [[ "$BACKEND_ENABLED" != true || -z "$BACKEND_URL" || ! -s "$file_path" ]]; then
    return 0
  fi

  RUN_ID="$RUN_ID" \
  RUN_STATUS_VALUE="$RUN_STATUS" \
  ERROR_MESSAGE_VALUE="$ERROR_MESSAGE" \
  KIND="$kind" \
  FILE_PATH="$file_path" \
  SOURCE_IP_VALUE="${SOURCE_IPS[0]:-}" \
  SOURCE_ORG_VALUE="${source_org:-}" \
  PUBLIC_IP_VALUE="${CURRENT_IP:-}" \
  PUBLIC_ASN_VALUE="${CURRENT_ASN:-}" \
  MACHINE_HOSTNAME_VALUE="$MACHINE_HOSTNAME" \
  MACHINE_KERNEL_VALUE="$MACHINE_KERNEL" \
  SYSTEM_CPU_MODEL_VALUE="${SYSTEM_CPU_MODEL:-unknown}" \
  SYSTEM_CPU_CORES_VALUE="${SYSTEM_CPU_CORES:-0}" \
  SYSTEM_MEM_TOTAL_MB_VALUE="${SYSTEM_MEM_TOTAL_MB:-0}" \
  SYSTEM_MEM_AVAILABLE_MB_VALUE="${SYSTEM_MEM_AVAILABLE_MB:-0}" \
  SYSTEM_DISK_TOTAL_GB_VALUE="${SYSTEM_DISK_TOTAL_GB:-0}" \
  SYSTEM_DISK_USED_GB_VALUE="${SYSTEM_DISK_USED_GB:-0}" \
  SYSTEM_DISK_FREE_GB_VALUE="${SYSTEM_DISK_FREE_GB:-0}" \
  SYSTEM_LOAD1_VALUE="${SYSTEM_LOAD1:-0}" \
  SYSTEM_LOAD5_VALUE="${SYSTEM_LOAD5:-0}" \
  SYSTEM_LOAD15_VALUE="${SYSTEM_LOAD15:-0}" \
  SYSTEM_PROCESS_COUNT_VALUE="${SYSTEM_PROCESS_COUNT:-0}" \
  TOTAL_DOMAINS_VALUE="${total_domains:-0}" \
  COUNT_OK_VALUE="${count_ok:-0}" \
  COUNT_BLOCKED_VALUE="${count_blocked:-0}" \
  COUNT_PARTIAL_VALUE="${count_partial:-0}" \
  ELAPSED_TIME_VALUE="${elapsed_time:-0}" \
  MAIN_LOG_FILE_VALUE="${MAIN_LOG_FILE:-}" \
  DEBUG_LOG_FILE_VALUE="${DEBUG_LOG_FILE:-}" \
  OK_HOSTS_VALUE="$(printf '%s\n' "${ok_hosts[@]}")" \
  python3 - "$file_path" <<'PY' | curl -fsS \
    -X POST \
    -H "Content-Type: application/json; charset=utf-8" \
    --data-binary @- \
    "$BACKEND_URL" >/dev/null 2>&1
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "run_id": os.environ.get("RUN_ID", ""),
    "run_status": os.environ.get("RUN_STATUS_VALUE", "success"),
    "error_message": os.environ.get("ERROR_MESSAGE_VALUE", ""),
    "kind": os.environ.get("KIND", ""),
    "source_ip": os.environ.get("SOURCE_IP_VALUE", ""),
    "source_org": os.environ.get("SOURCE_ORG_VALUE", ""),
    "public_ip": os.environ.get("PUBLIC_IP_VALUE", ""),
    "public_asn": os.environ.get("PUBLIC_ASN_VALUE", ""),
    "machine": {
        "hostname": os.environ.get("MACHINE_HOSTNAME_VALUE", ""),
        "kernel": os.environ.get("MACHINE_KERNEL_VALUE", ""),
    },
    "system": {
        "cpu_model": os.environ.get("SYSTEM_CPU_MODEL_VALUE", ""),
        "cpu_cores": int(os.environ.get("SYSTEM_CPU_CORES_VALUE", "0")),
        "mem_total_mb": int(os.environ.get("SYSTEM_MEM_TOTAL_MB_VALUE", "0")),
        "mem_available_mb": int(os.environ.get("SYSTEM_MEM_AVAILABLE_MB_VALUE", "0")),
        "disk_total_gb": float(os.environ.get("SYSTEM_DISK_TOTAL_GB_VALUE", "0")),
        "disk_used_gb": float(os.environ.get("SYSTEM_DISK_USED_GB_VALUE", "0")),
        "disk_free_gb": float(os.environ.get("SYSTEM_DISK_FREE_GB_VALUE", "0")),
        "loadavg": [
            float(os.environ.get("SYSTEM_LOAD1_VALUE", "0")),
            float(os.environ.get("SYSTEM_LOAD5_VALUE", "0")),
            float(os.environ.get("SYSTEM_LOAD15_VALUE", "0")),
        ],
        "process_count": int(os.environ.get("SYSTEM_PROCESS_COUNT_VALUE", "0")),
    },
    "counts": {
        "ok": int(os.environ.get("COUNT_OK_VALUE", "0")),
        "blocked": int(os.environ.get("COUNT_BLOCKED_VALUE", "0")),
        "partial": int(os.environ.get("COUNT_PARTIAL_VALUE", "0")),
        "total": int(os.environ.get("TOTAL_DOMAINS_VALUE", "0")),
    },
    "elapsed_seconds": int(os.environ.get("ELAPSED_TIME_VALUE", "0")),
    "ok_hosts": [line for line in os.environ.get("OK_HOSTS_VALUE", "").splitlines() if line.strip()],
    "files": {
        "main_log_file": os.environ.get("MAIN_LOG_FILE_VALUE", ""),
        "debug_log_file": os.environ.get("DEBUG_LOG_FILE_VALUE", ""),
    },
    "content": path.read_text(encoding="utf-8", errors="replace"),
}
print(json.dumps(payload, ensure_ascii=False))
PY
}

finalize_run() {
  local exit_code="$1"
  local last_command="${2:-}"

  if [[ "$FINALIZED" == true ]]; then
    return 0
  fi
  FINALIZED=true

  collect_system_snapshot

  if (( exit_code != 0 )); then
    RUN_STATUS="error"
    ERROR_MESSAGE="exit ${exit_code}${last_command:+: ${last_command}}"
    append_log_line "$DEBUG_LOG_FILE" "ERROR: ${ERROR_MESSAGE}"
  fi

  send_backend_file "main" "$MAIN_LOG_FILE"
  send_backend_file "debug" "$DEBUG_LOG_FILE"
  rm -f "$MAIN_LOG_FILE" "$DEBUG_LOG_FILE"
}

trap 'finalize_run "$?" "$BASH_COMMAND"' EXIT

install_missing_deps() {
  local deps=("curl" "nslookup" "nc" "openssl" "date" "awk" "python3")
  local missing=()

  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null; then
      missing+=("$dep")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    return 0
  fi

  echo "Missing dependencies: ${missing[*]}. Installing automatically..."

  local prefix=""
  if [ "$(id -u)" -eq 0 ]; then
    prefix=""
  elif command -v sudo >/dev/null 2>&1; then
    prefix="sudo "
  else
    echo "You are not root, and sudo is not available."
    exit 1
  fi

  local pkg_mgr=""
  local update_cmd=""
  local quiet_update_cmd=""
  local install_cmd=""
  local quiet_install_cmd=""
  local pkg_names=()

  if [ -f /etc/debian_version ] || grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
    pkg_mgr="apt"
    update_cmd="apt update -y"
    quiet_update_cmd="apt update -y -q"
    install_cmd="apt install -y"
    quiet_install_cmd="apt install -y -q"
    for dep in "${missing[@]}"; do
      case "$dep" in
        curl) pkg_names+=("curl") ;;
        nslookup) pkg_names+=("dnsutils") ;;
        nc) pkg_names+=("netcat-openbsd") ;;
        openssl) pkg_names+=("openssl") ;;
        date) pkg_names+=("coreutils") ;;
        awk) pkg_names+=("gawk") ;;
        python3) pkg_names+=("python3") ;;
      esac
    done
  elif [ -f /etc/fedora-release ] || grep -qi "fedora" /etc/os-release 2>/dev/null; then
    pkg_mgr="dnf"
    update_cmd="dnf check-update -y"
    quiet_update_cmd="dnf check-update -y --quiet"
    install_cmd="dnf install -y"
    quiet_install_cmd="dnf install -y --quiet"
    for dep in "${missing[@]}"; do
      case "$dep" in
        curl) pkg_names+=("curl") ;;
        nslookup) pkg_names+=("bind-utils") ;;
        nc) pkg_names+=("nc") ;;
        openssl) pkg_names+=("openssl") ;;
        date) pkg_names+=("coreutils") ;;
        awk) pkg_names+=("gawk") ;;
        python3) pkg_names+=("python3") ;;
      esac
    done
  elif [ -f /etc/centos-release ] || grep -qi "centos\|rhel" /etc/os-release 2>/dev/null; then
    if command -v dnf >/dev/null; then
      pkg_mgr="dnf"
      update_cmd="dnf check-update -y"
      quiet_update_cmd="dnf check-update -y --quiet"
      install_cmd="dnf install -y"
      quiet_install_cmd="dnf install -y --quiet"
    else
      pkg_mgr="yum"
      update_cmd="yum check-update -y"
      quiet_update_cmd="yum check-update -y --quiet"
      install_cmd="yum install -y"
      quiet_install_cmd="yum install -y --quiet"
    fi
    for dep in "${missing[@]}"; do
      case "$dep" in
        curl) pkg_names+=("curl") ;;
        nslookup) pkg_names+=("bind-utils") ;;
        nc) pkg_names+=("nc") ;;
        openssl) pkg_names+=("openssl") ;;
        date) pkg_names+=("coreutils") ;;
        awk) pkg_names+=("gawk") ;;
        python3) pkg_names+=("python3") ;;
      esac
    done
  elif [ -f /etc/arch-release ] || grep -qi "arch" /etc/os-release 2>/dev/null; then
    pkg_mgr="pacman"
    update_cmd="pacman -Sy --noconfirm"
    quiet_update_cmd="pacman -Sy --noconfirm -qq"
    install_cmd="pacman -S --noconfirm"
    quiet_install_cmd="pacman -S --noconfirm -qq"
    for dep in "${missing[@]}"; do
      case "$dep" in
        curl) pkg_names+=("curl") ;;
        nslookup) pkg_names+=("bind") ;;
        nc) pkg_names+=("openbsd-netcat") ;;
        openssl) pkg_names+=("openssl") ;;
        date) pkg_names+=("coreutils") ;;
        awk) pkg_names+=("gawk") ;;
        python3) pkg_names+=("python3") ;;
      esac
    done
  else
    echo "Unsupported distribution. Please install dependencies manually."
    exit 1
  fi

  ${prefix}${quiet_update_cmd} >/dev/null 2>&1
  for pkg in "${pkg_names[@]}"; do
    ${prefix}${quiet_install_cmd} "$pkg" >/dev/null 2>&1
  done
}

declare -a SOURCE_IPS=()
declare -a CURL_EXTRA_ARGS=()
declare -A IP_ORG_CACHE=()
declare -a SOURCE_CHOICES=()
MAIN_LOG_FILE=""
DEBUG_LOG_FILE=""

is_valid_ipv4() {
  local ip="$1"
  local octet

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done

  return 0
}

is_local_ipv4() {
  local ip="$1"
  [[ "$ip" == 10.* ]] && return 0
  [[ "$ip" == 192.168.* ]] && return 0
  [[ "$ip" =~ ^172\.([1][6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

discover_source_ips() {
  local discovered=()

  if [[ -n "$FORCED_SOURCE_IP" ]]; then
    if ! is_valid_ipv4 "$FORCED_SOURCE_IP"; then
      echo "Invalid IPv4 address for --source-ip: $FORCED_SOURCE_IP"
      exit 1
    fi
    SOURCE_IPS=("$FORCED_SOURCE_IP")
    return
  fi

  if command -v ip >/dev/null 2>&1; then
    # Используем while read вместо mapfile для совместимости с Bash 3.x
    while IFS= read -r line; do
      [[ -n "$line" ]] && discovered+=("$line")
    done < <(ip -o -4 addr show up 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' | sort -u)
  elif command -v ifconfig >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && discovered+=("$line")
    done < <(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2}' | sort -u)
  elif command -v hostname >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && discovered+=("$line")
    done < <(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF' | sort -u)
  fi

  SOURCE_IPS=()
  for ip in "${discovered[@]}"; do
    [[ -z "$ip" || "$ip" == 127.* ]] && continue
    SOURCE_IPS+=("$ip")
  done
}

source_label() {
  local source_ip="$1"
  if [[ -z "$source_ip" ]]; then
    echo "default"
  else
    echo "$source_ip"
  fi
}

lookup_ip_org() {
  local ip="$1"

  if [[ -n "${IP_ORG_CACHE[$ip]:-}" ]]; then
    echo "${IP_ORG_CACHE[$ip]}"
    return
  fi

  local org=""
  if is_local_ipv4 "$ip"; then
    org="Local Address"
    IP_ORG_CACHE[$ip]="$org"
    echo "$org"
    return
  fi

  org=$(curl -s --connect-timeout 3 --max-time 4 "https://ipinfo.io/${ip}/org" 2>/dev/null | tr -d '\r\n')
  [[ -z "$org" ]] && org="org unknown"

  IP_ORG_CACHE[$ip]="$org"
  echo "$org"
}

animate_pid() {
  local pid="$1"
  local message="$2"
  local frames=('[   ]' '[.  ]' '[.. ]' '[...]')
  local i=0

  tput civis 2>/dev/null
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s %s" "$message" "${frames[$(( i % ${#frames[@]} ))]}"
    sleep 0.12
    i=$(( i + 1 ))
  done
  printf "\r%*s\r" 90 ""
  tput cnorm 2>/dev/null
}

resolve_source_choices() {
  local tmpfile
  local ip
  local org

  SOURCE_CHOICES=()
  tmpfile=$(mktemp)

  (
    for ip in "${SOURCE_IPS[@]}"; do
      org=$(lookup_ip_org "$ip")
      printf "%s|%s\n" "$ip" "$org"
    done > "$tmpfile"
  ) &
  local resolver_pid=$!

  animate_pid "$resolver_pid" "Определяем ASN и названия сетей"
  wait "$resolver_pid"

  # Используем while read вместо mapfile
  while IFS='|' read -r ip org; do
    [[ -z "$ip" ]] && continue
    IP_ORG_CACHE[$ip]="$org"
    SOURCE_CHOICES+=("$ip ($org)")
  done < "$tmpfile"

  rm -f "$tmpfile"
}

print_source_selection() {
  local choice=""
  local index=0
  local i
  local selection_error=""

  while true; do
    print_banner
    printf "%b\n" "> Список доступных айпи:"
    echo

    i=1
    for option in "${SOURCE_CHOICES[@]}"; do
      printf "  %b%2d.%b %b%s%b\n" \
        "${YELLOW}${BOLD}" "$i" "${RESET}" \
        "${GREEN}" "${option}" "${RESET}"
      i=$(( i + 1 ))
    done

    echo
    if [[ -n "$selection_error" ]]; then
      printf "%b\n\n" " ${RED}${selection_error}${RESET}"
      selection_error=""
    fi
    printf "%b" "${CYAN}> Выберите цифру:${RESET} "
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SOURCE_IPS[@]} )); then
      index=$(( choice - 1 ))
      if is_local_ipv4 "${SOURCE_IPS[$index]}"; then
        selection_error="Local Address нельзя использовать для сканирования. Выберите внешний IP."
        continue
      fi
      SOURCE_IPS=("${SOURCE_IPS[$index]}")
      break
    fi

    selection_error="Неверный выбор. Введите цифру из списка."
  done
}

select_source_ip() {
  [[ -n "$FORCED_SOURCE_IP" ]] && return

  resolve_source_choices

  if [[ ! -t 0 ]]; then
    SOURCE_IPS=("${SOURCE_IPS[0]}")
    return
  fi

  print_source_selection
}

print_section() {
  local title="$1"
  echo -e "${CYAN}${LINE_SEP}${RESET}"
  echo -e " ${YELLOW}>${RESET} ${BOLD}${BLUE}${title}${RESET}"
}

print_banner() {
  local inner_width=78
  local line_width=80
  local title="CENSOR CHECK BY WINQ"
  local subtitle="live DNS, TLS, HTTP and DPI reachability probe"
  local pad_left pad_right

  clear
  printf "${BLUE}${BOLD}+%*s+${RESET}\n" "$line_width" '' | tr ' ' '-'
  printf "${BLUE}${BOLD}|${RESET}%*s${BLUE}${BOLD}|${RESET}\n" "$inner_width" ''
  pad_left=$(( (inner_width - ${#title}) / 2 ))
  pad_right=$(( inner_width - pad_left - ${#title} ))
  printf "${BLUE}${BOLD}|${RESET}%*s${MAGENTA}${BOLD}%s${RESET}%*s${BLUE}${BOLD}|${RESET}\n" \
    "$pad_left" '' "$title" "$pad_right" ''
  pad_left=$(( (inner_width - ${#subtitle}) / 2 ))
  pad_right=$(( inner_width - pad_left - ${#subtitle} ))
  printf "${BLUE}${BOLD}|${RESET}%*s${DIM}%s${RESET}%*s${BLUE}${BOLD}|${RESET}\n" \
    "$pad_left" '' "$subtitle" "$pad_right" ''
  printf "${BLUE}${BOLD}|${RESET}%*s${BLUE}${BOLD}|${RESET}\n" "$inner_width" ''
  printf "${BLUE}${BOLD}+%*s+${RESET}\n" "$line_width" '' | tr ' ' '-'
  echo
}

build_curl_args() {
  local source_ip="$1"
  CURL_EXTRA_ARGS=()
  if [[ -n "$source_ip" ]]; then
    CURL_EXTRA_ARGS+=(--interface "$source_ip")
  fi
}

fetch_code() {
  local source_ip="$1"
  local url="$2"
  local proxy_args=()

  if [[ -n "$PROXY" ]]; then
    if [[ "$PROXY" == http://* ]]; then
      proxy_args=(--proxy "$PROXY")
    else
      proxy_args=(--proxy "socks5://$PROXY")
    fi
  fi

  build_curl_args "$source_ip"

  curl -s -o /dev/null \
       --retry "$RETRIES" \
       --connect-timeout "$TIMEOUT" \
       --max-time "$TIMEOUT" \
       -$IP_VERSION \
       -A "$USER_AGENT" \
       "${proxy_args[@]}" \
       "${CURL_EXTRA_ARGS[@]}" \
       -w "%{http_code}" \
       "$url"
}

check_keyword_blocking() {
  local domain="$1"
  local source_ip="$2"
  local test_url="https://$domain"

  build_curl_args "$source_ip"

  local dpi_response
  dpi_response=$(curl -s -A "Suspicious-Agent TLS/1.3" \
    --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    "${CURL_EXTRA_ARGS[@]}" \
    "$test_url" 2>/dev/null | tr -d '\000')

  if echo "$dpi_response" | grep -qi "blocked\|forbidden\|access.denied\|roscomnadzor\|rkn\|firewall\|censorship\|prohibited\|restricted"; then
    return 0
  fi

  local sni_code
  sni_code=$(curl -s -o /dev/null \
    --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    --resolve "$domain:443:192.0.2.1" \
    "${CURL_EXTRA_ARGS[@]}" \
    "$test_url" -w "%{http_code}" 2>/dev/null)

  if [[ "$sni_code" =~ [45][0-9][0-9] || "$sni_code" == "000" ]]; then
    return 0
  fi

  return 1
}

check_certificate() {
  local domain="$1"
  local source_ip="$2"
  local cert_info
  local bind_args=()

  if [[ -n "$source_ip" ]]; then
    bind_args=(-bind "${source_ip}:0")
  fi

  cert_info=$(timeout "$TIMEOUT" openssl s_client "${bind_args[@]}" -connect "$domain:443" -servername "$domain" -CApath /etc/ssl/certs -verify 5 < /dev/null 2>&1)

  if echo "$cert_info" | grep -q "Verification error:" || ! echo "$cert_info" | grep -q "Verification: OK"; then
    $VERBOSE && echo "TLS verification failed for $domain via $(source_label "$source_ip")"
    return 1
  fi

  local not_after
  not_after=$(echo "$cert_info" | openssl x509 -noout -dates 2>/dev/null | grep "notAfter" | cut -d= -f2)
  if [[ -n "$not_after" ]]; then
    local expire_epoch
    local current_epoch
    expire_epoch=$(date -d "$not_after" +%s 2>/dev/null)
    current_epoch=$(date +%s)
    if [[ $expire_epoch -lt $current_epoch ]]; then
      $VERBOSE && echo "Certificate expired for $domain via $(source_label "$source_ip")"
      return 1
    fi
    return 0
  fi

  return 1
}

check_port_from_source() {
  local target_ip="$1"
  local target_port="$2"
  local source_ip="$3"
  local nc_args=(-z -w "$TIMEOUT")

  if [[ -n "$source_ip" ]]; then
    nc_args+=(-s "$source_ip")
  fi

  nc "${nc_args[@]}" "$target_ip" "$target_port" 2>/dev/null
}

evaluate_domain_from_source() {
  local domain="$1"
  local source_ip="$2"
  local ips="$3"
  local block_type="UNKNOWN"
  local source_name
  local ip_ok=false
  local port_443_ok=false

  source_name=$(source_label "$source_ip")

  for ip in $ips; do
    if check_port_from_source "$ip" 443 "$source_ip"; then
      ip_ok=true
      port_443_ok=true
      break
    fi
  done

  if ! $port_443_ok; then
    for ip in $ips; do
      if check_port_from_source "$ip" 80 "$source_ip"; then
        ip_ok=true
        break
      fi
    done
  fi

  if ! $ip_ok; then
    echo "SOURCE_RESULT|$source_name|BLOCKED|IP/TCP|"
    return
  fi

  local cert_status=""
  if check_certificate "$domain" "$source_ip"; then
    cert_status="TLS_OK"
  else
    cert_status="TLS_FAIL"
    block_type="TLS/SSL"
  fi

  local http_code
  local https_code
  http_code=$(fetch_code "$source_ip" "http://$domain")
  https_code=$(fetch_code "$source_ip" "https://$domain")

  if [[ "$http_code" =~ 3[0-9][0-9] ]]; then
    $VERBOSE && echo "HTTP redirect detected for $domain via $source_name, falling back to HTTPS"
    http_code="$https_code"
  fi

  if [[ "$http_code" == "000" && "$https_code" == "000" ]]; then
    if $ip_ok; then
      block_type="HTTP(S)"
    else
      block_type="IP/HTTP"
    fi
  elif [[ "$http_code" =~ [45][0-9][0-9] && "$https_code" =~ [45][0-9][0-9] ]]; then
    block_type="HTTP-RESPONSE"
  fi

  if check_keyword_blocking "$domain" "$source_ip"; then
    if [[ "$block_type" != "UNKNOWN" ]]; then
      block_type="$block_type/DPI"
    else
      block_type="DPI/KEYWORD"
    fi
  fi

  if [[ " ${AI_DOMAINS[*]} " =~ " ${domain} " ]]; then
    local ai_response
    build_curl_args "$source_ip"
    ai_response=$(curl -s -A "$USER_AGENT" \
      -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
      -H "Accept-Language: en-US,en;q=0.5" \
      -H "Upgrade-Insecure-Requests: 1" \
      -H "Sec-Fetch-Dest: document" \
      -H "Sec-Fetch-Mode: navigate" \
      -H "Sec-Fetch-Site: none" \
      -H "Sec-Fetch-User: ?1" \
      -H "Connection: keep-alive" \
      --compressed \
      --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
      "${CURL_EXTRA_ARGS[@]}" \
      "https://$domain" 2>/dev/null | tr -d '\000')
    if echo "$ai_response" | grep -qi "sorry, you have been blocked\|you are unable to access\|not available in your region\|restricted in your country\|access denied due to location\|blocked in your area\|unable to load site\|if you are using a vpn\|Not Available"; then
      block_type="REGIONAL"
      http_code="000"
      https_code="000"
    elif echo "$ai_response" | grep -qi "just a moment\|enable javascript and cookies"; then
      block_type=""
      http_code="200"
      https_code="200"
    fi
  fi

  if [[ "$http_code" == "000" && "$https_code" == "000" ]]; then
    echo "SOURCE_RESULT|$source_name|BLOCKED|$block_type|$cert_status"
  elif [[ "$http_code" =~ [23][0-9][0-9] || "$https_code" =~ [23][0-9][0-9] ]]; then
    echo "SOURCE_RESULT|$source_name|OK||$cert_status"
  else
    echo "SOURCE_RESULT|$source_name|PARTIAL|$block_type|$cert_status"
  fi
}

check_domain() {
  local domain="$1"
  local ips
  local source_ip
  local source_status=""
  local ok_count=0
  local blocked_count=0
  local partial_count=0
  local detail_lines=()
  local overall_status=""
  local source_total=${#SOURCE_IPS[@]}
  local result_source=""
  local result_block_type=""
  local result_cert_status=""
  local single_block_type=""
  local single_cert_status=""

  ips=$(timeout "$TIMEOUT" nslookup "$domain" 2>/dev/null | awk '/^Address: / && !/#/ {print $2}')

  if [[ -z "$ips" ]]; then
    printf "%-${DOMAIN_WIDTH}s  ${RED_ITALIC}%-8s${RESET} ${DIM}%s${RESET}\n" "$domain" "BLOCKED" "DNS resolution failed"
    echo "STATUS:BLOCKED"
    return
  fi

  for ip in $ips; do
    if is_rkn_spoof "$ip"; then
      printf "%-${DOMAIN_WIDTH}s  ${RED_ITALIC}%-8s${RESET} ${DIM}%s${RESET} ${RED}[stub %s]${RESET}\n" \
        "$domain" "BLOCKED" "DNS spoof detected" "$ip"
      echo "STATUS:BLOCKED"
      return
    fi
  done

  for source_ip in "${SOURCE_IPS[@]}"; do
      while IFS= read -r line; do
        case "$line" in
        SOURCE_RESULT\|*)
          IFS='|' read -r _ result_source source_status result_block_type result_cert_status <<< "$line"
          local badge
          badge=$(status_badge "$source_status")
          case "$source_status" in
            OK)
              (( ok_count++ ))
              ;;
            BLOCKED)
              (( blocked_count++ ))
              ;;
            PARTIAL)
              (( partial_count++ ))
              ;;
          esac
          if (( source_total == 1 )); then
            single_block_type="$result_block_type"
            single_cert_status="$result_cert_status"
          else
            case "$source_status" in
              BLOCKED)
                detail_lines+=("    ${DIM}[$result_source]${RESET} ${badge} ${DIM}($result_block_type${result_cert_status:+, $result_cert_status})${RESET}")
                ;;
              PARTIAL)
                detail_lines+=("    ${DIM}[$result_source]${RESET} ${badge} ${DIM}($result_block_type${result_cert_status:+, $result_cert_status})${RESET}")
                ;;
            esac
          fi
          ;;
      esac
    done < <(evaluate_domain_from_source "$domain" "$source_ip" "$ips")
  done

  if (( blocked_count == ${#SOURCE_IPS[@]} )); then
    overall_status="BLOCKED"
    if (( source_total == 1 )); then
      printf "%-${DOMAIN_WIDTH}s  %b  ${DIM}(%s%s)${RESET}\n" \
        "$domain" "$(status_badge "$overall_status")" "$single_block_type" "${single_cert_status:+, $single_cert_status}"
    else
      printf "%-${DOMAIN_WIDTH}s  %b\n" "$domain" "$(status_badge "$overall_status")"
    fi
    echo "STATUS:BLOCKED"
  elif (( ok_count == ${#SOURCE_IPS[@]} )); then
    overall_status="OK"
    printf "%-${DOMAIN_WIDTH}s  %b\n" "$domain" "$(status_badge "$overall_status")"
    echo "STATUS:OK"
  else
    overall_status="PARTIAL"
    if (( source_total == 1 )); then
      printf "%-${DOMAIN_WIDTH}s  %b  ${DIM}(%s%s)${RESET}\n" \
        "$domain" "$(status_badge "$overall_status")" "$single_block_type" "${single_cert_status:+, $single_cert_status}"
    else
      printf "%-${DOMAIN_WIDTH}s  %b\n" "$domain" "$(status_badge "$overall_status")"
    fi
    echo "STATUS:PARTIAL"
  fi

  if (( source_total > 1 && ${#detail_lines[@]} > 0 )); then
    for line in "${detail_lines[@]}"; do
      echo "$line"
    done
  fi
}
animate() {
  local total=$1
  local tmpdir=$2
  local bar_width=50
  local spin_index=0

  tput civis 2>/dev/null

  while true; do
    local done_count=$(ls "$tmpdir"/*.txt 2>/dev/null | wc -l)
    local percent=$(( done_count * 100 / total ))
    (( percent > 100 )) && percent=100

    local filled=$(( done_count * bar_width / total ))
    (( filled > bar_width )) && filled=$bar_width
    local remaining=$(( bar_width - filled ))
    (( remaining < 0 )) && remaining=0

    local fill_str empty_str
    printf -v fill_str  '%*s' "$filled"    ''
    printf -v empty_str '%*s' "$remaining" ''
    fill_str="${fill_str// /#}"
    empty_str="${empty_str// /-}"
    local spinner="${SPINNER_FRAMES[$(( spin_index % ${#SPINNER_FRAMES[@]} ))]}"

    printf "\r  ${CYAN}${BOLD}%s Scanning${RESET}  [${GREEN}%s${DIM}%s${RESET}]  ${YELLOW}${BOLD}%3d%%${RESET}  ${DIM}%d/%d${RESET}\e[K" \
      "$spinner" "$fill_str" "$empty_str" "$percent" "$done_count" "$total"

    spin_index=$(( spin_index + 1 ))
    sleep 0.1
  done
}

install_missing_deps
init_log_files

print_banner

discover_source_ips
if [[ ${#SOURCE_IPS[@]} -eq 0 ]]; then
  echo "No global IPv4 addresses found on active interfaces."
  exit 1
fi

select_source_ip

start_time=$(date +%s)

print_banner

if [[ -n "$FORCED_SOURCE_IP" ]]; then
  source_org=$(lookup_ip_org "${SOURCE_IPS[0]}")
  echo -e " ${DIM}Source IP:${RESET} ${GREEN}${BOLD}${SOURCE_IPS[0]}${RESET} ${DIM}(forced, ${source_org})${RESET}"
  append_log_line "$MAIN_LOG_FILE" "Source IP: ${SOURCE_IPS[0]} (forced, ${source_org})"
else
  source_org=$(lookup_ip_org "${SOURCE_IPS[0]}")
  echo -e " ${DIM}Source IP:${RESET} ${GREEN}${BOLD}${SOURCE_IPS[0]}${RESET} ${DIM}(${source_org})${RESET}"
  append_log_line "$MAIN_LOG_FILE" "Source IP: ${SOURCE_IPS[0]} (${source_org})"
fi
echo -e "${BLUE}${BOLD}${LINE_SEP}${RESET}"
echo
append_log_line "$MAIN_LOG_FILE" "$LINE_SEP"

TMPDIR_RESULTS=$(mktemp -d)

animate "${#DOMAINS[@]}" "$TMPDIR_RESULTS" &
ANIM_PID=$!

job_pids=()

for i in "${!DOMAINS[@]}"; do
  d="${DOMAINS[$i]}"
  check_domain "$d" > "$TMPDIR_RESULTS/$i.txt" &
  job_pids+=($!)

  while (( $(jobs -p | wc -l) > MAX_PARALLEL )); do
    wait -n 2>/dev/null
  done
done

wait "${job_pids[@]}" 2>/dev/null

kill "$ANIM_PID" 2>/dev/null
wait "$ANIM_PID" 2>/dev/null
printf "\r\e[K"
tput cnorm 2>/dev/null

count_ok=0
count_blocked=0
count_partial=0
ok_hosts=()

print_section "Results"
append_log_line "$MAIN_LOG_FILE" "Results"

for i in "${!DOMAINS[@]}"; do
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf "%s\n" "$line"
    append_log_line "$MAIN_LOG_FILE" "$line"
    sleep "$REVEAL_DELAY"
  done < <(grep -v "^STATUS:" "$TMPDIR_RESULTS/$i.txt")
  status=$(grep "^STATUS:" "$TMPDIR_RESULTS/$i.txt" | cut -d: -f2)
  case "$status" in
    OK)
      (( count_ok++ ))
      ok_hosts+=("${DOMAINS[$i]}")
      ;;
    BLOCKED) (( count_blocked++ )) ;;
    PARTIAL) (( count_partial++ )) ;;
  esac
done

rm -rf "$TMPDIR_RESULTS"

total_domains=${#DOMAINS[@]}

# Определяем текущий внешний IP и ASN/организацию
CURRENT_IP=$(curl -s -4 --connect-timeout 3 https://api.ipify.org 2>/dev/null)
CURRENT_ASN=""
if [[ -n "$CURRENT_IP" ]]; then
  CURRENT_ASN=$(curl -s --connect-timeout 3 "https://ipinfo.io/${CURRENT_IP}/org" 2>/dev/null | tr -d '\r\n')
fi

print_section "Summary"
printf " ${GREEN}OK:${RESET}%d  ${RED}BLOCKED:${RESET}%d  ${YELLOW}PARTIAL:${RESET}%d  ${DIM}Total:${RESET}%d" \
  "$count_ok" "$count_blocked" "$count_partial" "$total_domains"
if [[ -n "$CURRENT_ASN" ]]; then
  printf " ${DIM}|${RESET} ${CYAN}%s${RESET}" "$CURRENT_ASN"
fi
echo
append_log_line "$MAIN_LOG_FILE" "Summary"
append_log_line "$MAIN_LOG_FILE" "Summary: OK=${count_ok} BLOCKED=${count_blocked} PARTIAL=${count_partial} TOTAL=${total_domains} ASN=${CURRENT_ASN}"
if (( ${#ok_hosts[@]} > 0 )); then
  print_section "Unblocked Hosts"
  append_log_line "$MAIN_LOG_FILE" "Unblocked Hosts"
  for host in "${ok_hosts[@]}"; do
    printf "  ${GREEN}- %s${RESET}\n" "$host"
    append_log_line "$MAIN_LOG_FILE" "UNBLOCKED ${host}"
    sleep "$REVEAL_DELAY"
  done
fi

echo -e "${CYAN}${LINE_SEP}${RESET}"

end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
elapsed_minutes=$((elapsed_time / 60))
elapsed_seconds=$((elapsed_time % 60))

if (( elapsed_minutes > 0 )); then
  echo "Test completed in ${elapsed_minutes}m ${elapsed_seconds}s."
  append_log_line "$MAIN_LOG_FILE" "Elapsed: ${elapsed_minutes}m ${elapsed_seconds}s"
else
  echo "Test completed in ${elapsed_seconds}s."
  append_log_line "$MAIN_LOG_FILE" "Elapsed: ${elapsed_seconds}s"
fi

if $DEBUG; then
  echo "$LINE_SEP"
  echo -e "${CYAN}=== DEBUG INFO ===${RESET}"
  append_log_line "$DEBUG_LOG_FILE" "$LINE_SEP"
  append_log_line "$DEBUG_LOG_FILE" "=== DEBUG INFO ==="
  log_debug_line "Script:        $0"
  log_debug_line "Bash version:  $BASH_VERSION"
  log_debug_line "OS:            $(uname -a 2>/dev/null || echo 'n/a')"
  log_debug_line "Date:          $(date)"
  log_debug_line "Public IP:     ${CURRENT_IP:-not detected}"
  log_debug_line "Total domains: ${#DOMAINS[@]}"
  log_debug_line "Max parallel:  $MAX_PARALLEL"
  log_debug_line "Timeout:       ${TIMEOUT}s"
  log_debug_line "Retries:       $RETRIES"
  log_debug_line "Elapsed:       ${elapsed_time}s"
  log_debug_line ""
  log_debug_line "--- Listening ports (ss -tlnp | head -20) ---"
  while IFS= read -r line; do
    log_debug_line "$line"
  done < <(ss -tlnp 2>/dev/null | head -20 || echo 'ss not available')
  log_debug_line ""
  log_debug_line "--- Tools versions ---"
  log_debug_line "curl:    $(curl --version 2>/dev/null | head -1)"
  log_debug_line "openssl: $(openssl version 2>/dev/null)"
  log_debug_line "python3: $(python3 --version 2>/dev/null)"
  log_debug_line "nc:      $(nc -h 2>&1 | head -1)"
  log_debug_line ""
  log_debug_line "--- DNS test (nslookup google.com) ---"
  while IFS= read -r line; do
    log_debug_line "$line"
  done < <(nslookup google.com 2>&1 | head -10)
  log_debug_line ""
  log_debug_line "--- Ping test (1.1.1.1) ---"
  while IFS= read -r line; do
    log_debug_line "$line"
  done < <(ping -c 2 -W 2 1.1.1.1 2>&1 | tail -5)
fi
