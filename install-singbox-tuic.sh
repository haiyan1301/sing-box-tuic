#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box TUIC quick installer
# References:
# - https://sing-box.sagernet.org/installation/package-manager/
# - https://sing-box.sagernet.org/configuration/inbound/tuic/
# - https://sing-box.sagernet.org/configuration/shared/tls/
# - https://github.com/acmesh-official/acme.sh

SCRIPT_NAME="${0##*/}"
SERVICE_NAME="sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_DIR="${CONFIG_DIR}/certs"
SELF_CERT_FILE="${CERT_DIR}/tuic-selfsigned.crt"
SELF_KEY_FILE="${CERT_DIR}/tuic-selfsigned.key"
ACME_CERT_FILE="${CERT_DIR}/tuic-acme.crt"
ACME_KEY_FILE="${CERT_DIR}/tuic-acme.key"
ACME_RELOAD_SCRIPT="/usr/local/sbin/sing-box-tuic-acme-reload"
INSTALL_URL="https://sing-box.app/install.sh"
LEGACY_RENEW_SCRIPT="/usr/local/sbin/sing-box-tuic-renew"
LEGACY_RENEW_SERVICE="/etc/systemd/system/sing-box-tuic-renew.service"
LEGACY_RENEW_TIMER="/etc/systemd/system/sing-box-tuic-renew.timer"
CLIENT_JSON_FILE="/root/sing-box-tuic-client.json"
CLIENT_JSON_QR_FILE="/root/sing-box-tuic-client-json.png"
CLIENT_URI_QR_FILE="/root/sing-box-tuic-uri.png"

PORT="443"
UUID_VALUE=""
PASSWORD_VALUE=""
CERT_MODE="self"
DOMAIN_VALUE=""
IP_VALUE=""
EMAIL_VALUE=""
CERT_FILE=""
KEY_FILE=""
SERVER_NAME=""
CONGESTION="cubic"
ACME_SH_PATH=""
YES=0
OPEN_FIREWALL=1
START_SERVICE=1
INTERACTIVE_INPUT="/dev/stdin"
INTERACTIVE_FD=""
PACKAGE_INDEX_UPDATED=0

PORT_SET=0
UUID_SET=0
PASSWORD_SET=0
CERT_MODE_SET=0
DOMAIN_SET=0
IP_SET=0
EMAIL_SET=0
CERT_FILE_SET=0
KEY_FILE_SET=0
SERVER_NAME_SET=0
CONGESTION_SET=0
FIREWALL_SET=0
START_SERVICE_SET=0

BACK_CODE=22

BOLD=""
RESET=""
DIM=""
RED=""
GREEN=""
YELLOW=""
BLUE=""
CYAN=""
MAGENTA=""

init_colors() {
  if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
    return 0
  fi
  if [ ! -t 1 ] && [ ! -t 2 ]; then
    return 0
  fi

  BOLD=$'\033[1m'
  RESET=$'\033[0m'
  DIM=$'\033[2m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  CYAN=$'\033[36m'
  MAGENTA=$'\033[35m'
}

info() {
  printf '%s[INFO]%s %s\n' "${BOLD}${BLUE}" "$RESET" "$*" >&2
}

success() {
  printf '%s[ OK ]%s %s\n' "${BOLD}${GREEN}" "$RESET" "$*" >&2
}

warn() {
  printf '%s[WARN]%s %s\n' "${BOLD}${YELLOW}" "$RESET" "$*" >&2
}

error() {
  printf '%s[FAIL]%s %s\n' "${BOLD}${RED}" "$RESET" "$*" >&2
}

die() {
  error "$*"
  exit 1
}

heading() {
  printf '\n%s%s%s\n' "${BOLD}${CYAN}" "$*" "$RESET"
}

section_divider() {
  printf '%s%s%s\n' "$DIM" "------------------------------------------------------------" "$RESET"
}

menu_item() {
  local key="$1"
  local label="$2"
  local value="${3:-}"
  local style="${4:-normal}"
  local key_color="$BLUE"

  case "$style" in
    default) key_color="$GREEN" ;;
    custom) key_color="$CYAN" ;;
    optional) key_color="$MAGENTA" ;;
    nav) key_color="$YELLOW" ;;
    danger) key_color="$RED" ;;
  esac

  if [ -n "$value" ]; then
    printf '  %s%s%s) %s%s%s: %s%s%s\n' "$key_color" "$key" "$RESET" "$BOLD" "$label" "$RESET" "$CYAN" "$value" "$RESET"
  else
    printf '  %s%s%s) %s%s%s\n' "$key_color" "$key" "$RESET" "$BOLD" "$label" "$RESET"
  fi
}

prompt_text() {
  printf '%s%s%s' "${BOLD}${CYAN}" "$*" "$RESET"
}

trim_input() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

label_value() {
  local label="$1"
  local value="$2"
  printf '%s%-18s%s %s%s%s\n' "$BOLD" "${label}:" "$RESET" "$CYAN" "$value" "$RESET"
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Install and configure sing-box as a TUIC-only server on a systemd Linux VPS.

Options:
  --port <1-65535>             TUIC UDP listen port (default: 443)
  --uuid <uuid>                TUIC user UUID (default: auto-generate)
  --password <password>        TUIC user password (default: auto-generate)
  --cert-mode <mode>           self | acme-domain | acme-ip | existing
  --domain <domain>            Domain for ACME domain certificates
  --ip <ip>                    IP address for ACME IP certificates
  --email <email>              Optional ACME account email
  --cert-file <path>           Existing certificate path
  --key-file <path>            Existing private key path
  --server-name <name>         TLS server name for certificate/client example
  --congestion <algorithm>     cubic | new_reno | bbr (default: cubic)
  --yes                        Non-interactive mode; use defaults where safe
  --skip-firewall              Do not modify ufw/firewalld
  --no-start                   Write config but do not start/restart service
  -h, --help                   Show this help

Examples:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --yes
  sudo bash ${SCRIPT_NAME} --cert-mode acme-domain --domain example.com --email admin@example.com
  sudo bash ${SCRIPT_NAME} --cert-mode acme-ip --ip 203.0.113.10 --email admin@example.com
EOF
}

normalize_cert_mode() {
  case "$1" in
    self)
      printf 'self'
      ;;
    acme-domain)
      printf 'acme-domain'
      ;;
    acme-ip)
      printf 'acme-ip'
      ;;
    existing)
      printf 'existing'
      ;;
    *)
      return 1
      ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        [ "$#" -ge 2 ] || die "--port requires a value"
        PORT="$2"; PORT_SET=1; shift 2
        ;;
      --port=*)
        PORT="${1#*=}"; PORT_SET=1; shift
        ;;
      --uuid)
        [ "$#" -ge 2 ] || die "--uuid requires a value"
        UUID_VALUE="$2"; UUID_SET=1; shift 2
        ;;
      --uuid=*)
        UUID_VALUE="${1#*=}"; UUID_SET=1; shift
        ;;
      --password)
        [ "$#" -ge 2 ] || die "--password requires a value"
        PASSWORD_VALUE="$2"; PASSWORD_SET=1; shift 2
        ;;
      --password=*)
        PASSWORD_VALUE="${1#*=}"; PASSWORD_SET=1; shift
        ;;
      --cert-mode)
        [ "$#" -ge 2 ] || die "--cert-mode requires a value"
        CERT_MODE="$(normalize_cert_mode "$2")" || die "Invalid cert mode: $2"
        CERT_MODE_SET=1; shift 2
        ;;
      --cert-mode=*)
        CERT_MODE="$(normalize_cert_mode "${1#*=}")" || die "Invalid cert mode: ${1#*=}"
        CERT_MODE_SET=1; shift
        ;;
      --domain)
        [ "$#" -ge 2 ] || die "--domain requires a value"
        DOMAIN_VALUE="$2"; DOMAIN_SET=1; shift 2
        ;;
      --domain=*)
        DOMAIN_VALUE="${1#*=}"; DOMAIN_SET=1; shift
        ;;
      --ip)
        [ "$#" -ge 2 ] || die "--ip requires a value"
        IP_VALUE="$2"; IP_SET=1; shift 2
        ;;
      --ip=*)
        IP_VALUE="${1#*=}"; IP_SET=1; shift
        ;;
      --email)
        [ "$#" -ge 2 ] || die "--email requires a value"
        EMAIL_VALUE="$2"; EMAIL_SET=1; shift 2
        ;;
      --email=*)
        EMAIL_VALUE="${1#*=}"; EMAIL_SET=1; shift
        ;;
      --cert-file)
        [ "$#" -ge 2 ] || die "--cert-file requires a value"
        CERT_FILE="$2"; CERT_FILE_SET=1; shift 2
        ;;
      --cert-file=*)
        CERT_FILE="${1#*=}"; CERT_FILE_SET=1; shift
        ;;
      --key-file)
        [ "$#" -ge 2 ] || die "--key-file requires a value"
        KEY_FILE="$2"; KEY_FILE_SET=1; shift 2
        ;;
      --key-file=*)
        KEY_FILE="${1#*=}"; KEY_FILE_SET=1; shift
        ;;
      --server-name)
        [ "$#" -ge 2 ] || die "--server-name requires a value"
        SERVER_NAME="$2"; SERVER_NAME_SET=1; shift 2
        ;;
      --server-name=*)
        SERVER_NAME="${1#*=}"; SERVER_NAME_SET=1; shift
        ;;
      --congestion)
        [ "$#" -ge 2 ] || die "--congestion requires a value"
        CONGESTION="$2"; CONGESTION_SET=1; shift 2
        ;;
      --congestion=*)
        CONGESTION="${1#*=}"; CONGESTION_SET=1; shift
        ;;
      --yes|-y)
        YES=1; shift
        ;;
      --skip-firewall)
        OPEN_FIREWALL=0; FIREWALL_SET=1; shift
        ;;
      --no-start)
        START_SERVICE=0; START_SERVICE_SET=1; shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

validate_supplied_args() {
  if [ "$PORT_SET" -eq 1 ]; then
    validate_port "$PORT" || exit 1
  fi
  if [ "$UUID_SET" -eq 1 ]; then
    validate_uuid "$UUID_VALUE" || exit 1
  fi
  if [ "$PASSWORD_SET" -eq 1 ]; then
    validate_password "$PASSWORD_VALUE" || exit 1
  fi
  if [ "$CERT_MODE_SET" -eq 1 ]; then
    validate_cert_mode "$CERT_MODE" || exit 1
  fi
  if [ "$DOMAIN_SET" -eq 1 ]; then
    validate_domain "$DOMAIN_VALUE" || exit 1
  fi
  if [ "$IP_SET" -eq 1 ]; then
    validate_ip "$IP_VALUE" || exit 1
  fi
  if [ "$EMAIL_SET" -eq 1 ]; then
    validate_email "$EMAIL_VALUE" || exit 1
  fi
  if [ "$CERT_FILE_SET" -eq 1 ]; then
    validate_file_exists "$CERT_FILE" || exit 1
  fi
  if [ "$KEY_FILE_SET" -eq 1 ]; then
    validate_file_exists "$KEY_FILE" || exit 1
  fi
  if [ "$CERT_FILE_SET" -eq 1 ] && [ "$KEY_FILE_SET" -eq 1 ]; then
    validate_distinct_cert_key_paths "$CERT_FILE" "$KEY_FILE" || exit 1
  fi
  if [ "$SERVER_NAME_SET" -eq 1 ]; then
    validate_server_name "$SERVER_NAME" || exit 1
  fi
  if [ "$CONGESTION_SET" -eq 1 ]; then
    validate_congestion "$CONGESTION" || exit 1
  fi

  if [ "$YES" -eq 1 ]; then
    case "$CERT_MODE" in
      acme-domain)
        [ -n "$DOMAIN_VALUE" ] || die "--cert-mode acme-domain requires --domain"
        ;;
      existing)
        [ -n "$CERT_FILE" ] || die "--cert-mode existing requires --cert-file"
        [ -n "$KEY_FILE" ] || die "--cert-mode existing requires --key-file"
        ;;
    esac
  fi
}

is_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ]
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_environment() {
  is_root || die "请使用 root 运行: sudo bash ${SCRIPT_NAME}"
  have_cmd systemctl || die "未找到 systemctl；本脚本仅支持 systemd Linux"
  if [ ! -d /run/systemd/system ]; then
    die "未检测到正在运行的 systemd；本脚本不支持 OpenWrt、Docker 容器或非 systemd 环境"
  fi
}

package_manager() {
  if have_cmd apt-get; then
    printf 'apt'
  elif have_cmd dnf; then
    printf 'dnf'
  elif have_cmd yum; then
    printf 'yum'
  elif have_cmd zypper; then
    printf 'zypper'
  elif have_cmd pacman; then
    printf 'pacman'
  else
    return 1
  fi
}

package_update_index() {
  local pm
  pm="$(package_manager 2>/dev/null || true)"
  [ -n "$pm" ] || return 1
  [ "$PACKAGE_INDEX_UPDATED" -eq 0 ] || return 0

  case "$pm" in
    apt)
      info "更新软件包索引: apt-get update"
      apt-get update
      ;;
    dnf)
      info "刷新软件包元数据: dnf makecache"
      dnf makecache
      ;;
    yum)
      info "刷新软件包元数据: yum makecache"
      yum makecache
      ;;
    zypper)
      info "刷新软件包元数据: zypper refresh"
      zypper --non-interactive refresh
      ;;
    pacman)
      info "同步软件包数据库: pacman -Sy"
      pacman -Sy --noconfirm
      ;;
  esac
  PACKAGE_INDEX_UPDATED=1
}

install_or_update_packages() {
  local packages="$*"
  local pm
  [ -n "$packages" ] || return 0
  pm="$(package_manager 2>/dev/null || true)"
  [ -n "$pm" ] || {
    warn "未识别包管理器，无法自动安装/更新:${packages}"
    return 1
  }

  package_update_index || true
  case "$pm" in
    apt)
      info "安装/更新依赖: apt-get install -y ${packages}"
      apt-get install -y $packages
      ;;
    dnf)
      info "安装/更新依赖: dnf install -y ${packages}"
      dnf install -y $packages
      ;;
    yum)
      info "安装/更新依赖: yum install -y ${packages}"
      yum install -y $packages
      ;;
    zypper)
      info "安装/更新依赖: zypper --non-interactive install ${packages}"
      zypper --non-interactive install $packages
      ;;
    pacman)
      info "安装/更新依赖: pacman -S --noconfirm ${packages}"
      pacman -S --noconfirm $packages
      ;;
  esac
}

ensure_base_commands() {
  local missing=""

  info "检查并更新脚本依赖命令"
  package_update_index || warn "未能自动更新软件包索引；将继续检查已安装命令"

  install_or_update_packages curl openssl qrencode || true

  have_cmd curl || have_cmd wget || missing="${missing} curl/wget"
  have_cmd openssl || missing="${missing} openssl"
  have_cmd qrencode || warn "未检测到 qrencode，安装完成后将只输出 JSON 文本和分享链接"
  [ -z "$missing" ] || die "缺少必需命令:${missing}"
}

validate_port() {
  local port_number
  case "$1" in
    ''|*[!0-9]*)
      warn "端口必须是 1-65535 的数字"
      return 1
      ;;
  esac
  [ "${#1}" -le 5 ] || {
    warn "端口必须在 1-65535 之间"
    return 1
  }
  port_number=$((10#$1))
  [ "$port_number" -ge 1 ] && [ "$port_number" -le 65535 ] || {
    warn "端口必须在 1-65535 之间"
    return 1
  }
}

normalize_port_value() {
  printf '%d' "$((10#$1))"
}

validate_uuid() {
  if [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    return 0
  fi
  warn "UUID 格式无效，例如: 01234567-89ab-cdef-0123-456789abcdef"
  return 1
}

validate_password() {
  [ -n "$1" ] || {
    warn "密码不能为空"
    return 1
  }
  [ "${#1}" -ge 8 ] || {
    warn "密码长度不能小于 8 位"
    return 1
  }
  [[ "$1" != *[[:space:]]* ]] || {
    warn "密码不能包含空白字符"
    return 1
  }
}

validate_congestion() {
  case "$1" in
    cubic|new_reno|bbr)
      return 0
      ;;
    *)
      warn "拥塞控制只能是 cubic、new_reno 或 bbr"
      return 1
      ;;
  esac
}

validate_cert_mode() {
  case "$1" in
    self|acme-domain|acme-ip|existing)
      return 0
      ;;
    *)
      warn "证书模式只能是 self、acme-domain、acme-ip 或 existing"
      return 1
      ;;
  esac
}

validate_domain_name() {
  local value="$1"
  local require_dot="$2"
  local label
  local -a labels

  [ -n "$value" ] || {
    warn "域名不能为空"
    return 1
  }
  if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    warn "域名不能是 IPv4 地址格式"
    return 1
  fi
  [ "${#value}" -le 253 ] || {
    warn "域名长度不能超过 253 个字符"
    return 1
  }
  case "$value" in
    *'*'*)
      warn "ACME 域名不支持通配符"
      return 1
      ;;
    *_*)
      warn "域名不能包含下划线"
      return 1
      ;;
    .*|*.)
      warn "域名不能以点开头或结尾"
      return 1
      ;;
    *..*)
      warn "域名不能包含连续点"
      return 1
      ;;
  esac
  [ "$require_dot" -eq 0 ] || [[ "$value" == *.* ]] || {
    warn "ACME 域名必须包含至少一个点"
    return 1
  }
  [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || {
    warn "域名只能包含字母、数字、点和连字符"
    return 1
  }
  IFS='.' read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    [ -n "$label" ] || {
      warn "域名 label 不能为空"
      return 1
    }
    [ "${#label}" -le 63 ] || {
      warn "域名每段长度不能超过 63 个字符"
      return 1
    }
    [[ "$label" =~ ^[A-Za-z0-9-]+$ ]] || {
      warn "域名每段只能包含字母、数字和连字符"
      return 1
    }
    case "$label" in
      -*|*-)
        warn "域名每段不能以连字符开头或结尾"
        return 1
        ;;
    esac
  done
}

validate_domain() {
  validate_domain_name "$1" 1
}

validate_ipv4() {
  local value="$1"
  local part
  local -a parts

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<<"$value"
  for part in "${parts[@]}"; do
    [ "$((10#$part))" -le 255 ] || return 1
  done
}

validate_ipv6() {
  local value="$1"
  local group
  local group_count=0
  local has_compression=0
  local without_first_compression
  local -a groups

  [[ "$value" == *:* ]] || return 1
  [[ "$value" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "$value" != *:::* ]] || return 1

  without_first_compression="${value/::/}"
  [[ "$without_first_compression" != *::* ]] || return 1

  if [[ "$value" == *::* ]]; then
    has_compression=1
  fi
  if [[ "$value" == :* && "$value" != ::* ]]; then
    return 1
  fi
  if [[ "$value" == *: && "$value" != *:: ]]; then
    return 1
  fi

  IFS=':' read -r -a groups <<<"$value"
  for group in "${groups[@]}"; do
    [ -n "$group" ] || continue
    [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    group_count=$((group_count + 1))
  done

  if [ "$has_compression" -eq 1 ]; then
    [ "$group_count" -le 7 ] || return 1
  else
    [ "$group_count" -eq 8 ] || return 1
  fi
}

validate_ip() {
  local value="$1"
  [ -n "$value" ] || {
    warn "IP 不能为空"
    return 1
  }
  if validate_ipv4 "$value"; then
    return 0
  fi
  if validate_ipv6 "$value"; then
    return 0
  fi
  warn "IP 地址格式无效；IPv4 每段必须为 0-255，IPv6 仅允许十六进制和冒号"
  return 1
}

validate_server_name() {
  local value="$1"

  [ -n "$value" ] || {
    warn "server_name 不能为空"
    return 1
  }
  case "$value" in
    *://*|*/*|*\\*|*[[:space:]]*)
      warn "server_name 不能包含空格、路径或 URL scheme"
      return 1
      ;;
    *'*'*)
      warn "server_name 不能使用通配符"
      return 1
      ;;
  esac
  if validate_ip "$value" >/dev/null 2>&1 || validate_domain_name "$value" 0 >/dev/null 2>&1; then
    return 0
  fi
  warn "server_name 必须是合法域名或 IP"
  return 1
}

validate_email() {
  local value="$1"
  local local_part domain_part

  [[ "$value" == *@* ]] || {
    warn "邮箱格式无效"
    return 1
  }
  local_part="${value%@*}"
  domain_part="${value#*@}"
  [ "$local_part" != "$value" ] && [ "$domain_part" != "$value" ] || {
    warn "邮箱格式无效"
    return 1
  }
  [ -n "$local_part" ] && [ -n "$domain_part" ] || {
    warn "邮箱格式无效"
    return 1
  }
  [[ "$local_part" =~ ^[A-Za-z0-9._%+-]+$ ]] || {
    warn "邮箱用户名只能包含字母、数字、点、下划线、百分号、加号和连字符"
    return 1
  }
  case "$local_part" in
    .*|*.|*..*)
      warn "邮箱用户名不能以点开头或结尾，也不能包含连续点"
      return 1
      ;;
  esac
  validate_domain "$domain_part" >/dev/null 2>&1 || {
    warn "邮箱格式无效"
    return 1
  }
}

validate_file_exists() {
  [ -n "$1" ] || {
    warn "文件路径不能为空"
    return 1
  }
  case "$1" in
    /*)
      ;;
    *)
      warn "证书和私钥路径必须使用绝对路径"
      return 1
      ;;
  esac
  [ -f "$1" ] || {
    warn "文件不存在或不是普通文件: $1"
    return 1
  }
  [ -r "$1" ] || {
    warn "文件不可读: $1"
    return 1
  }
}

canonical_file_path() {
  local path="$1"
  local dir base real_dir

  dir="$(dirname -- "$path")" || return 1
  base="$(basename -- "$path")" || return 1
  real_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$real_dir" "$base"
}

validate_distinct_cert_key_paths() {
  local cert="$1"
  local key="$2"
  local cert_real key_real

  if [ "$cert" = "$key" ]; then
    warn "证书路径和私钥路径不能相同"
    return 1
  fi
  if [ "$cert" -ef "$key" ]; then
    warn "证书路径和私钥路径不能指向同一个文件"
    return 1
  fi

  cert_real="$(canonical_file_path "$cert")" || cert_real="$cert"
  key_real="$(canonical_file_path "$key")" || key_real="$key"
  if [ "$cert_real" = "$key_real" ]; then
    warn "证书路径和私钥路径不能指向同一个文件"
    return 1
  fi
}

looks_like_ip() {
  validate_ip "$1" >/dev/null 2>&1
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

url_encode() {
  local value="$1"
  local out="" char hex i
  local LC_ALL=C

  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      [A-Za-z0-9.~_-])
        out+="$char"
        ;;
      *)
        printf -v hex '%%%02X' "'$char"
        out+="$hex"
        ;;
    esac
  done
  printf '%s' "$out"
}

open_interactive_input() {
  if [ -n "$INTERACTIVE_FD" ]; then
    return 0
  fi
  exec 3<"$INTERACTIVE_INPUT" || die "无法读取交互输入: ${INTERACTIVE_INPUT}"
  INTERACTIVE_FD=3
}

read_interactive_line() {
  local var_name="$1"
  local prompt="$2"

  open_interactive_input
  read -r -p "$(prompt_text "$prompt")" "$var_name" <&3 || exit 1
}

openssl_conf_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//,/\\,}
  s=${s//=/\\=}
  printf '%s' "$s"
}

read_menu_choice() {
  local var_name="$1"
  local prompt="$2"
  local menu_choice
  read_interactive_line menu_choice "$prompt"
  menu_choice="$(trim_input "$menu_choice")"
  printf -v "$var_name" '%s' "${menu_choice:-1}"
}

split_prefixed_choice() {
  local input="$1"
  local choice_var="$2"
  local rest_var="$3"
  local rest

  case "$input" in
    2?*)
      rest="${input:1}"
      printf -v "$choice_var" '%s' "2"
      printf -v "$rest_var" '%s' "$(trim_input "$rest")"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

prompt_value() {
  local var_name="$1"
  local title="$2"
  local default_value="$3"
  local validator="$4"
  local input_prompt="$5"
  local choice value

  while true; do
    heading "$title"
    if [ -n "$default_value" ]; then
      menu_item "1" "使用脚本默认值" "$default_value" default
    else
      menu_item "1" "使用脚本默认值" "无可用默认值" default
    fi
    menu_item "2" "自定义输入" "" custom
    menu_item "b" "返回上一步" "" nav
    menu_item "q" "退出" "" danger

    read_menu_choice choice "请选择 [默认: 1]: "
    value=""
    split_prefixed_choice "$choice" choice value || true
    case "$choice" in
      1)
        if [ -z "$default_value" ]; then
          warn "此项没有可用默认值，请选择自定义输入"
          continue
        fi
        if "$validator" "$default_value"; then
          printf -v "$var_name" '%s' "$default_value"
          return 0
        fi
        ;;
      2|c|C)
        while true; do
          if [ -z "$value" ]; then
            read_interactive_line value "$input_prompt"
          fi
          [ "$validator" = "validate_password" ] || value="$(trim_input "$value")"
          if "$validator" "$value"; then
            printf -v "$var_name" '%s' "$value"
            return 0
          fi
          value=""
        done
        ;;
      b|B)
        return "$BACK_CODE"
        ;;
      q|Q)
        exit 0
        ;;
      *)
        warn "请输入 1、2、b 或 q"
        ;;
    esac
  done
}

prompt_optional_value() {
  local var_name="$1"
  local title="$2"
  local default_value="$3"
  local validator="$4"
  local input_prompt="$5"
  local choice value

  while true; do
    heading "$title"
    if [ -n "$default_value" ]; then
      menu_item "1" "使用脚本默认值" "$default_value" default
    else
      menu_item "1" "使用脚本默认值" "跳过" default
    fi
    menu_item "2" "自定义输入" "" custom
    menu_item "s" "跳过本项" "" optional
    menu_item "b" "返回上一步" "" nav
    menu_item "q" "退出" "" danger

    read_menu_choice choice "请选择 [默认: 1]: "
    value=""
    split_prefixed_choice "$choice" choice value || true
    case "$choice" in
      1)
        if [ -n "$default_value" ] && ! "$validator" "$default_value"; then
          continue
        fi
        printf -v "$var_name" '%s' "$default_value"
        return 0
        ;;
      2|c|C)
        while true; do
          if [ -z "$value" ]; then
            read_interactive_line value "$input_prompt"
          fi
          [ "$validator" = "validate_password" ] || value="$(trim_input "$value")"
          if [ -z "$value" ]; then
            printf -v "$var_name" '%s' ""
            return 0
          fi
          if "$validator" "$value"; then
            printf -v "$var_name" '%s' "$value"
            return 0
          fi
          value=""
        done
        ;;
      s|S)
        printf -v "$var_name" '%s' ""
        return 0
        ;;
      b|B)
        return "$BACK_CODE"
        ;;
      q|Q)
        exit 0
        ;;
      *)
        warn "请输入 1、2、s、b 或 q"
        ;;
    esac
  done
}

prompt_bool() {
  local var_name="$1"
  local title="$2"
  local default_value="$3"
  local yes_label="$4"
  local no_label="$5"
  local choice

  while true; do
    heading "$title"
    if [ "$default_value" -eq 1 ]; then
      menu_item "1" "使用脚本默认值" "$yes_label" default
      menu_item "2" "$no_label" "" custom
    else
      menu_item "1" "使用脚本默认值" "$no_label" default
      menu_item "2" "$yes_label" "" custom
    fi
    menu_item "b" "返回上一步" "" nav
    menu_item "q" "退出" "" danger

    read_menu_choice choice "请选择 [默认: 1]: "
    case "$choice" in
      1)
        printf -v "$var_name" '%s' "$default_value"
        return 0
        ;;
      2)
        if [ "$default_value" -eq 1 ]; then
          printf -v "$var_name" '%s' "0"
        else
          printf -v "$var_name" '%s' "1"
        fi
        return 0
        ;;
      b|B)
        return "$BACK_CODE"
        ;;
      q|Q)
        exit 0
        ;;
      *)
        warn "请输入 1、2、b 或 q"
        ;;
    esac
  done
}

prompt_cert_mode() {
  local choice normalized
  if [ "$CERT_MODE_SET" -eq 1 ]; then
    validate_cert_mode "$CERT_MODE"
    return 0
  fi

  while true; do
    heading "证书模式"
    menu_item "1" "使用脚本默认值" "自签证书" default
    menu_item "2" "ACME 域名证书" "" custom
    menu_item "3" "ACME IP 证书" "" custom
    menu_item "4" "已有证书路径" "" custom
    menu_item "b" "返回上一步" "" nav
    menu_item "q" "退出" "" danger
    read_menu_choice choice "请选择 [默认: 1]: "
    case "$choice" in
      1)
        CERT_MODE="self"
        return 0
        ;;
      2)
        CERT_MODE="acme-domain"
        return 0
        ;;
      3)
        CERT_MODE="acme-ip"
        return 0
        ;;
      4)
        CERT_MODE="existing"
        return 0
        ;;
      b|B)
        return "$BACK_CODE"
        ;;
      q|Q)
        exit 0
        ;;
      *)
        normalized="$(normalize_cert_mode "$choice" 2>/dev/null || true)"
        if [ -n "$normalized" ]; then
          CERT_MODE="$normalized"
          return 0
        fi
        warn "请输入 1、2、3、4、b 或 q"
        ;;
    esac
  done
}

generate_uuid() {
  if have_cmd uuidgen; then
    uuidgen | tr 'A-F' 'a-f'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    tr 'A-F' 'a-f' </proc/sys/kernel/random/uuid
  elif have_cmd openssl; then
    local hex
    hex="$(openssl rand -hex 16)"
    printf '%s-%s-%s-%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
  else
    die "无法生成 UUID：请安装 uuidgen 或 openssl"
  fi
}

generate_password() {
  if have_cmd openssl; then
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' | cut -c1-32
  elif [ -r /dev/urandom ]; then
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    printf '\n'
  else
    die "无法生成密码：请安装 openssl"
  fi
}

hostname_default() {
  local value=""
  value="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  case "$value" in
    ""|localhost|localhost.localdomain|*.local)
      return 0
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

detect_public_ip() {
  local value=""
  if have_cmd curl; then
    value="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$value" ] || value="$(curl -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  elif have_cmd wget; then
    value="$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -n "$value" ] && validate_ip "$value" >/dev/null 2>&1; then
    printf '%s' "$value"
  fi
}

prompt_port_step() {
  if [ "$PORT_SET" -eq 1 ]; then
    validate_port "$PORT"
    return 0
  fi
  prompt_value PORT "TUIC 监听端口" "443" validate_port "请输入端口 [1-65535]: "
}

prompt_credentials_step() {
  local substep=1
  local generated
  while [ "$substep" -le 2 ]; do
    case "$substep" in
      1)
        if [ "$UUID_SET" -eq 1 ]; then
          validate_uuid "$UUID_VALUE"
          substep=2
          continue
        fi
        generated="$(generate_uuid)"
        if prompt_value UUID_VALUE "TUIC 用户 UUID" "$generated" validate_uuid "请输入 UUID: "; then
          substep=2
        else
          return "$BACK_CODE"
        fi
        ;;
      2)
        if [ "$PASSWORD_SET" -eq 1 ]; then
          validate_password "$PASSWORD_VALUE"
          substep=3
          continue
        fi
        generated="$(generate_password)"
        if prompt_value PASSWORD_VALUE "TUIC 用户密码" "$generated" validate_password "请输入密码: "; then
          substep=3
        else
          if [ "$UUID_SET" -eq 1 ]; then
            return "$BACK_CODE"
          fi
          substep=1
        fi
        ;;
    esac
  done
}

prompt_certificate_step() {
  local substep=1
  local default_value detected

  while true; do
    case "$substep" in
      1)
        if prompt_cert_mode; then
          substep=2
        else
          return "$BACK_CODE"
        fi
        ;;
      2)
        case "$CERT_MODE" in
          self)
            if [ "$SERVER_NAME_SET" -eq 1 ]; then
              validate_server_name "$SERVER_NAME" || exit 1
              return 0
            fi
            default_value="$(detect_public_ip)"
            [ -n "$default_value" ] || default_value="sing-box-tuic.local"
            if prompt_value SERVER_NAME "自签证书名称" "$default_value" validate_server_name "请输入证书名称或服务器 IP: "; then
              return 0
            fi
            substep=1
            ;;
          acme-domain)
            if [ "$DOMAIN_SET" -eq 1 ]; then
              validate_domain "$DOMAIN_VALUE"
            else
              default_value="$(hostname_default)"
              if ! prompt_value DOMAIN_VALUE "ACME 域名" "$default_value" validate_domain "请输入已解析到本机的域名: "; then
                substep=1
                continue
              fi
            fi
            if [ "$SERVER_NAME_SET" -eq 0 ]; then
              SERVER_NAME="$DOMAIN_VALUE"
            fi
            if [ "$EMAIL_SET" -eq 0 ]; then
              if ! prompt_optional_value EMAIL_VALUE "ACME 邮箱" "" validate_email "请输入邮箱，可留空跳过: "; then
                substep=1
                continue
              fi
            fi
            return 0
            ;;
          acme-ip)
            if [ "$IP_SET" -eq 1 ]; then
              validate_ip "$IP_VALUE"
            else
              detected="$(detect_public_ip)"
              if ! prompt_value IP_VALUE "ACME IP 地址" "$detected" validate_ip "请输入本机公网 IP: "; then
                substep=1
                continue
              fi
            fi
            if [ "$SERVER_NAME_SET" -eq 0 ]; then
              SERVER_NAME="$IP_VALUE"
            fi
            if [ "$EMAIL_SET" -eq 0 ]; then
              if ! prompt_optional_value EMAIL_VALUE "ACME 邮箱" "" validate_email "请输入邮箱，可留空跳过: "; then
                substep=1
                continue
              fi
            fi
            return 0
            ;;
          existing)
            if [ "$CERT_FILE_SET" -eq 1 ]; then
              validate_file_exists "$CERT_FILE" || exit 1
            else
              if ! prompt_value CERT_FILE "已有证书路径" "" validate_file_exists "请输入 certificate_path: "; then
                substep=1
                continue
              fi
            fi
            if [ "$KEY_FILE_SET" -eq 1 ]; then
              validate_file_exists "$KEY_FILE" || exit 1
            else
              if ! prompt_value KEY_FILE "已有私钥路径" "" validate_file_exists "请输入 key_path: "; then
                substep=1
                continue
              fi
            fi
            if ! validate_distinct_cert_key_paths "$CERT_FILE" "$KEY_FILE"; then
              substep=2
              continue
            fi
            if [ "$SERVER_NAME_SET" -eq 0 ]; then
              prompt_optional_value SERVER_NAME "客户端示例使用的 server_name" "" validate_server_name "请输入证书对应域名或 IP，可留空跳过: " || {
                substep=1
                continue
              }
            fi
            return 0
            ;;
        esac
        ;;
    esac
  done
}

prompt_congestion_step() {
  if [ "$CONGESTION_SET" -eq 1 ]; then
    validate_congestion "$CONGESTION"
    return 0
  fi
  prompt_value CONGESTION "QUIC 拥塞控制" "cubic" validate_congestion "请输入 cubic、new_reno 或 bbr: "
}

prompt_firewall_step() {
  if [ "$FIREWALL_SET" -eq 1 ]; then
    return 0
  fi
  prompt_bool OPEN_FIREWALL "防火墙端口放行" 1 "自动放行所需端口" "跳过，仅打印端口提示"
}

prompt_service_step() {
  if [ "$START_SERVICE_SET" -eq 1 ]; then
    return 0
  fi
  prompt_bool START_SERVICE "服务启动方式" 1 "启用并重启 sing-box" "只写配置，不启动服务"
}

interactive_wizard() {
  local step=1
  local rc
  heading "sing-box TUIC 快捷安装向导"
  section_divider
  printf '%s%s%s\n' "$DIM" "每一步按 Enter 使用脚本默认值，输入 2 可自定义，输入 b 返回。" "$RESET"

  while [ "$step" -le 6 ]; do
    rc=0
    case "$step" in
      1) prompt_port_step || rc=$? ;;
      2) prompt_credentials_step || rc=$? ;;
      3) prompt_certificate_step || rc=$? ;;
      4) prompt_congestion_step || rc=$? ;;
      5) prompt_firewall_step || rc=$? ;;
      6) prompt_service_step || rc=$? ;;
    esac

    if [ "$rc" -eq "$BACK_CODE" ]; then
      if [ "$step" -gt 1 ]; then
        step=$((step - 1))
      else
        warn "已经是第一步"
      fi
    elif [ "$rc" -eq 0 ]; then
      step=$((step + 1))
    else
      exit "$rc"
    fi
  done
}

noninteractive_defaults() {
  if [ -z "$UUID_VALUE" ]; then
    UUID_VALUE="$(generate_uuid)"
  fi
  if [ -z "$PASSWORD_VALUE" ]; then
    PASSWORD_VALUE="$(generate_password)"
  fi

  case "$CERT_MODE" in
    self)
      if [ -z "$SERVER_NAME" ]; then
        SERVER_NAME="$(detect_public_ip)"
        [ -n "$SERVER_NAME" ] || SERVER_NAME="sing-box-tuic.local"
      fi
      ;;
    acme-domain)
      [ -n "$DOMAIN_VALUE" ] || die "--cert-mode acme-domain requires --domain"
      [ -n "$SERVER_NAME" ] || SERVER_NAME="$DOMAIN_VALUE"
      ;;
    acme-ip)
      if [ -z "$IP_VALUE" ]; then
        IP_VALUE="$(detect_public_ip)"
      fi
      [ -n "$IP_VALUE" ] || die "--cert-mode acme-ip requires --ip, or public IP auto-detection must work"
      [ -n "$SERVER_NAME" ] || SERVER_NAME="$IP_VALUE"
      ;;
    existing)
      [ -n "$CERT_FILE" ] || die "--cert-mode existing requires --cert-file"
      [ -n "$KEY_FILE" ] || die "--cert-mode existing requires --key-file"
      ;;
  esac
}

validate_final_inputs() {
  validate_port "$PORT" || exit 1
  PORT="$(normalize_port_value "$PORT")"
  validate_uuid "$UUID_VALUE" || exit 1
  validate_password "$PASSWORD_VALUE" || exit 1
  validate_cert_mode "$CERT_MODE" || exit 1
  validate_congestion "$CONGESTION" || exit 1

  case "$CERT_MODE" in
    self)
      [ -n "$SERVER_NAME" ] || SERVER_NAME="sing-box-tuic.local"
      validate_server_name "$SERVER_NAME" || exit 1
      ;;
    acme-domain)
      validate_domain "$DOMAIN_VALUE" || exit 1
      [ -n "$SERVER_NAME" ] || SERVER_NAME="$DOMAIN_VALUE"
      validate_server_name "$SERVER_NAME" || exit 1
      ;;
    acme-ip)
      validate_ip "$IP_VALUE" || exit 1
      [ -n "$SERVER_NAME" ] || SERVER_NAME="$IP_VALUE"
      validate_server_name "$SERVER_NAME" || exit 1
      ;;
    existing)
      validate_file_exists "$CERT_FILE" || exit 1
      validate_file_exists "$KEY_FILE" || exit 1
      validate_distinct_cert_key_paths "$CERT_FILE" "$KEY_FILE" || exit 1
      if [ -n "$SERVER_NAME" ]; then
        validate_server_name "$SERVER_NAME" || exit 1
      fi
      ;;
  esac
  if [ -n "$EMAIL_VALUE" ]; then
    validate_email "$EMAIL_VALUE" || exit 1
  fi
}

download_install_script() {
  if have_cmd curl; then
    curl -fsSL "$INSTALL_URL"
  elif have_cmd wget; then
    wget -qO- "$INSTALL_URL"
  else
    die "需要 curl 或 wget 来下载官方 sing-box 安装脚本"
  fi
}

sing_box_version_number() {
  sing-box version 2>/dev/null | awk 'NR==1 { for (i=1; i<=NF; i++) if ($i ~ /^v?[0-9]+[.][0-9]+[.][0-9]+/) { gsub(/^v/, "", $i); print $i; exit } }'
}

normalize_version_number() {
  local value="$1"
  if [[ "$value" =~ ^v?([0-9]+)[.]([0-9]+)[.]([0-9]+) ]]; then
    printf '%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

version_at_least() {
  local current="$1"
  local required="$2"
  local current_major current_minor current_patch required_major required_minor required_patch
  current="$(normalize_version_number "$current")" || return 1
  required="$(normalize_version_number "$required")" || return 1

  IFS=. read -r current_major current_minor current_patch <<EOF
$current
EOF
  IFS=. read -r required_major required_minor required_patch <<EOF
$required
EOF
  current_major="${current_major:-0}"
  current_minor="${current_minor:-0}"
  current_patch="${current_patch:-0}"
  required_major="${required_major:-0}"
  required_minor="${required_minor:-0}"
  required_patch="${required_patch:-0}"

  [ "$current_major" -gt "$required_major" ] && return 0
  [ "$current_major" -lt "$required_major" ] && return 1
  [ "$current_minor" -gt "$required_minor" ] && return 0
  [ "$current_minor" -lt "$required_minor" ] && return 1
  [ "$current_patch" -ge "$required_patch" ]
}

install_sing_box_package() {
  local channel="$1"
  if [ "$channel" = "beta" ]; then
    download_install_script | sh -s -- --beta
  else
    download_install_script | sh
  fi
}

install_sing_box() {
  if have_cmd sing-box; then
    info "检测到 sing-box: $(sing-box version 2>/dev/null | head -n 1 || printf 'installed')"
    return 0
  fi

  info "未检测到 sing-box，开始使用官方安装脚本安装稳定版"
  install_sing_box_package stable
  have_cmd sing-box || die "sing-box 安装失败：安装后仍找不到 sing-box 命令"
  success "sing-box 安装完成: $(sing-box version 2>/dev/null | head -n 1 || printf 'installed')"
}

make_self_signed_certificate() {
  have_cmd openssl || die "自签证书模式需要 openssl，请先安装 openssl"
  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"

  local cn san_value
  cn="$(openssl_conf_escape "$SERVER_NAME")"
  local san
  if looks_like_ip "$SERVER_NAME"; then
    san="IP:${SERVER_NAME}"
  else
    san_value="$(openssl_conf_escape "$SERVER_NAME")"
    san="DNS:${san_value}"
  fi

  local openssl_conf
  openssl_conf="$(mktemp)"
  cat >"$openssl_conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${cn}

[v3_req]
subjectAltName = ${san}
EOF

  info "生成自签证书: ${SELF_CERT_FILE}"
  openssl req -x509 -nodes -newkey ec \
    -pkeyopt ec_paramgen_curve:prime256v1 \
    -sha256 -days 3650 \
    -keyout "$SELF_KEY_FILE" \
    -out "$SELF_CERT_FILE" \
    -config "$openssl_conf" >/dev/null 2>&1 || {
      rm -f "$openssl_conf"
      die "自签证书生成失败"
    }
  rm -f "$openssl_conf"

  chmod 600 "$SELF_KEY_FILE"
  chmod 644 "$SELF_CERT_FILE"
  CERT_FILE="$SELF_CERT_FILE"
  KEY_FILE="$SELF_KEY_FILE"
}

ensure_acme_standalone_dependency() {
  if have_cmd socat || have_cmd python3 || have_cmd python; then
    return 0
  fi
  die "acme.sh standalone 模式需要 socat 或 python，请先安装 socat"
}

install_acme_runtime_dependencies() {
  local needs_acme_install=0
  local packages=""

  if ! have_cmd acme.sh && [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    needs_acme_install=1
  fi
  if ! have_cmd socat && ! have_cmd python3 && ! have_cmd python; then
    packages="${packages} socat"
  fi
  if [ "$needs_acme_install" -eq 1 ] && ! have_cmd curl; then
    packages="${packages} curl"
  fi

  if [ -n "$packages" ]; then
    install_or_update_packages $packages || true
  fi

  if [ "$needs_acme_install" -eq 1 ]; then
    info "未检测到 acme.sh，开始安装 acme.sh"
    have_cmd curl || die "安装 acme.sh 需要 curl，请先安装 curl"
    if [ -n "$EMAIL_VALUE" ]; then
      curl -fsSL https://get.acme.sh | sh -s email="$EMAIL_VALUE" || die "acme.sh 安装失败"
    else
      curl -fsSL https://get.acme.sh | sh || die "acme.sh 安装失败"
    fi
  fi

  acme_sh_bin >/dev/null || die "acme.sh 安装后仍找不到 acme.sh 命令"
  ensure_acme_standalone_dependency
}

acme_sh_bin() {
  if have_cmd acme.sh; then
    command -v acme.sh
    return 0
  fi
  if [ -x "$HOME/.acme.sh/acme.sh" ]; then
    printf '%s\n' "$HOME/.acme.sh/acme.sh"
    return 0
  fi
  return 1
}

write_acme_reload_script() {
cat >"$ACME_RELOAD_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="$SERVICE_NAME"
CONFIG_DIR="$CONFIG_DIR"
CONFIG_FILE="$CONFIG_FILE"
CERT_DIR="$CERT_DIR"
CERT_FILE="$ACME_CERT_FILE"
KEY_FILE="$ACME_KEY_FILE"

service_user="\$(systemctl show "\$SERVICE_NAME" -p User --value 2>/dev/null || true)"
if [ -z "\$service_user" ] && id -u "\$SERVICE_NAME" >/dev/null 2>&1; then
  service_user="\$SERVICE_NAME"
fi
service_group="\$(systemctl show "\$SERVICE_NAME" -p Group --value 2>/dev/null || true)"
if [ -z "\$service_group" ] && [ -n "\${service_user:-}" ] && [ "\$service_user" != "root" ] && id -g "\$service_user" >/dev/null 2>&1; then
  service_group="\$(id -gn "\$service_user")"
fi
service_group="\${service_group:-root}"

chmod 755 "\$CONFIG_DIR" 2>/dev/null || true
chown root:"\$service_group" "\$CONFIG_FILE" "\$CERT_DIR" "\$CERT_FILE" "\$KEY_FILE" 2>/dev/null || true
chmod 640 "\$CONFIG_FILE" 2>/dev/null || true
chmod 750 "\$CERT_DIR" 2>/dev/null || true
chmod 644 "$ACME_CERT_FILE" 2>/dev/null || true
chmod 600 "$ACME_KEY_FILE" 2>/dev/null || true
chmod 640 "\$KEY_FILE" 2>/dev/null || true
if systemctl is-active --quiet "\$SERVICE_NAME" && sing-box check -c "\$CONFIG_FILE" >/dev/null 2>&1; then
  systemctl restart "\$SERVICE_NAME"
else
  echo "[INFO] \$SERVICE_NAME is not running or config is not ready; skip reload"
fi
EOF
  chmod 755 "$ACME_RELOAD_SCRIPT"
}

verify_acme_certificate() {
  local subject="$1"
  have_cmd openssl || {
    warn "未找到 openssl，跳过证书内容校验"
    return 0
  }

  openssl x509 -in "$ACME_CERT_FILE" -noout -checkend 3600 >/dev/null 2>&1 || {
    die "ACME 证书校验失败：证书不存在、格式无效或即将在 1 小时内过期"
  }

  local cert_text san_pattern
  cert_text="$(openssl x509 -in "$ACME_CERT_FILE" -noout -text 2>/dev/null || true)"
  if [ "$CERT_MODE" = "acme-ip" ]; then
    san_pattern="IP Address:${subject}"
  else
    san_pattern="DNS:${subject}"
  fi
  if [ "$CERT_MODE" = "acme-ip" ] && [[ "$subject" == *:* ]]; then
    printf '%s\n' "$cert_text" | grep -Fq "IP Address:" || {
      die "ACME 证书校验失败：证书 SAN 中未找到 IP Address"
    }
    return 0
  fi
  printf '%s\n' "$cert_text" | grep -Fq "$san_pattern" || {
    die "ACME 证书校验失败：证书 SAN 中未找到 ${san_pattern}"
  }
}

issue_acme_certificate() {
  local acme_bin subject issue_args=() issue_log issue_rc
  subject="$DOMAIN_VALUE"
  [ "$CERT_MODE" = "acme-ip" ] && subject="$IP_VALUE"

  install_acme_runtime_dependencies
  acme_bin="$(acme_sh_bin)" || die "找不到 acme.sh 命令"
  ACME_SH_PATH="$acme_bin"

  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"
  write_acme_reload_script

  "$acme_bin" --set-default-ca --server letsencrypt || die "设置 acme.sh 默认 CA 为 Let's Encrypt 失败"
  "$acme_bin" --install-cronjob >/dev/null 2>&1 || warn "acme.sh cron 安装失败，请稍后手动执行: ${acme_bin} --install-cronjob"
  if [ -n "$EMAIL_VALUE" ]; then
    "$acme_bin" --register-account -m "$EMAIL_VALUE" --server letsencrypt || die "acme.sh 注册 Let's Encrypt 账号失败"
  else
    warn "未填写 ACME 邮箱，acme.sh 将使用无邮箱账号注册"
    "$acme_bin" --register-account --server letsencrypt || true
  fi

  issue_args=(--issue --standalone --server letsencrypt --keylength ec-256 -d "$subject")
  if [ "$CERT_MODE" = "acme-ip" ]; then
    issue_args+=(--cert-profile shortlived --days 3)
    warn "ACME IP 证书使用 Let's Encrypt shortlived profile；请确认 TCP 80 可被公网访问到本机"
  else
    warn "ACME 域名证书 standalone 验证需要 TCP 80 可被公网访问到本机"
  fi

  info "开始用 acme.sh 申请证书: ${subject}"
  issue_log="$(mktemp)"
  if "$acme_bin" "${issue_args[@]}" 2>&1 | tee "$issue_log"; then
    issue_rc=0
  else
    issue_rc=$?
  fi
  if [ "$issue_rc" -ne 0 ]; then
    if grep -Eq "Skipping\\. Next renewal time|Domains not changed|Add '--force' to force renewal" "$issue_log"; then
      warn "acme.sh 检测到已有证书且未到续签时间，继续安装已有证书"
    else
      rm -f "$issue_log"
      die "acme.sh 证书申请失败：请检查域名/IP、DNS 解析、公网 TCP 80、防火墙和 CA 返回日志"
    fi
  fi
  rm -f "$issue_log"

  info "安装证书到 sing-box 读取路径"
  "$acme_bin" --install-cert -d "$subject" --ecc \
    --fullchain-file "$ACME_CERT_FILE" \
    --key-file "$ACME_KEY_FILE" \
    --reloadcmd "$ACME_RELOAD_SCRIPT" || die "acme.sh 证书安装失败"

  validate_file_exists "$ACME_CERT_FILE" || exit 1
  validate_file_exists "$ACME_KEY_FILE" || exit 1
  verify_acme_certificate "$subject"
  chmod 644 "$ACME_CERT_FILE"
  chmod 600 "$ACME_KEY_FILE"
  CERT_FILE="$ACME_CERT_FILE"
  KEY_FILE="$ACME_KEY_FILE"
  success "ACME 证书已申请并安装: ${ACME_CERT_FILE}"
}

prepare_certificate() {
  case "$CERT_MODE" in
    self)
      make_self_signed_certificate
      ;;
    acme-domain|acme-ip)
      issue_acme_certificate
      ;;
    existing)
      validate_file_exists "$CERT_FILE" || exit 1
      validate_file_exists "$KEY_FILE" || exit 1
      validate_distinct_cert_key_paths "$CERT_FILE" "$KEY_FILE" || exit 1
      ;;
  esac
}

write_tls_block() {
  cat <<EOF
      "tls": {
        "enabled": true,
        "certificate_path": $(json_string "$CERT_FILE"),
        "key_path": $(json_string "$KEY_FILE")
      }
EOF
}

write_config_file() {
  local tmp_file backup_file timestamp
  mkdir -p "$CONFIG_DIR"
  tmp_file="$(mktemp)"

  {
    cat <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
EOF
    cat <<EOF
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "tuic",
          "uuid": $(json_string "$UUID_VALUE"),
          "password": $(json_string "$PASSWORD_VALUE")
        }
      ],
      "congestion_control": $(json_string "$CONGESTION"),
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
EOF
    write_tls_block
    cat <<EOF
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
  } >"$tmp_file"

  if [ -f "$CONFIG_FILE" ]; then
    timestamp="$(date +%Y%m%d%H%M%S)"
    backup_file="${CONFIG_FILE}.bak.${timestamp}"
    cp -a "$CONFIG_FILE" "$backup_file"
    info "已备份旧配置: ${backup_file}"
  else
    backup_file=""
  fi

  mv "$tmp_file" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  printf '%s' "$backup_file"
}

service_run_user() {
  local user
  user="$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)"
  if [ -n "$user" ]; then
    printf '%s' "$user"
  elif id -u "$SERVICE_NAME" >/dev/null 2>&1; then
    printf '%s' "$SERVICE_NAME"
  else
    printf '%s' "root"
  fi
}

service_run_group() {
  local user="$1"
  local group
  group="$(systemctl show "$SERVICE_NAME" -p Group --value 2>/dev/null || true)"
  if [ -n "$group" ]; then
    printf '%s' "$group"
  elif [ "$user" != "root" ] && id -g "$user" >/dev/null 2>&1; then
    id -gn "$user"
  else
    printf '%s' "root"
  fi
}

can_user_read_file() {
  local user="$1"
  local file="$2"
  if [ "$user" = "root" ]; then
    return 0
  fi
  if have_cmd runuser; then
    runuser -u "$user" -- test -r "$file" >/dev/null 2>&1
    return $?
  fi
  if have_cmd sudo; then
    sudo -u "$user" test -r "$file" >/dev/null 2>&1
    return $?
  fi
  [ -r "$file" ]
}

fix_runtime_permissions() {
  local service_user service_group
  service_user="$(service_run_user)"
  service_group="$(service_run_group "$service_user")"

  chmod 755 "$CONFIG_DIR"
  chown root:"$service_group" "$CONFIG_FILE" 2>/dev/null || chown root:root "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"

  if [ "$CERT_MODE" = "self" ] || [ "$CERT_MODE" = "acme-domain" ] || [ "$CERT_MODE" = "acme-ip" ]; then
    chown root:"$service_group" "$CERT_DIR" 2>/dev/null || chown root:root "$CERT_DIR"
    chmod 750 "$CERT_DIR"
    chown root:"$service_group" "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
    chmod 644 "$CERT_FILE"
    chmod 640 "$KEY_FILE"
  elif [ "$CERT_MODE" = "existing" ]; then
    if ! can_user_read_file "$service_user" "$CERT_FILE"; then
      warn "${SERVICE_NAME} 服务用户 ${service_user} 可能无法读取证书文件: ${CERT_FILE}"
    fi
    if ! can_user_read_file "$service_user" "$KEY_FILE"; then
      warn "${SERVICE_NAME} 服务用户 ${service_user} 可能无法读取私钥文件: ${KEY_FILE}"
    fi
  fi
}

restore_backup() {
  local backup_file="$1"
  if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
    cp -a "$backup_file" "$CONFIG_FILE"
    warn "已恢复旧配置: ${backup_file}"
  else
    rm -f "$CONFIG_FILE"
    warn "未发现旧配置备份，已移除本次生成的无效配置"
  fi
}

check_config_or_rollback() {
  local backup_file="$1"
  info "校验 sing-box 配置"
  if sing-box check -c "$CONFIG_FILE"; then
    success "配置校验通过"
    return 0
  fi
  restore_backup "$backup_file"
  die "配置校验失败，已停止安装流程"
}

configure_firewall() {
  if [ "$OPEN_FIREWALL" -ne 1 ]; then
    warn "已跳过防火墙配置；请确保放行 UDP ${PORT}"
    if [ "$CERT_MODE" = "acme-domain" ] || [ "$CERT_MODE" = "acme-ip" ]; then
      warn "ACME standalone 验证还需要 TCP 80 可被公网访问"
      [ "$CERT_MODE" = "acme-ip" ] && warn "ACME IP 证书验证使用 TCP 80；TUIC 业务使用 UDP ${PORT}"
    fi
    return 0
  fi

  local handled=0
  if have_cmd ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    info "检测到 ufw，放行端口"
    if ! ufw allow "${PORT}/udp"; then
      warn "ufw 放行 UDP ${PORT} 失败，请手动检查防火墙"
      return 0
    fi
    if [ "$CERT_MODE" = "acme-domain" ] || [ "$CERT_MODE" = "acme-ip" ]; then
      ufw allow "80/tcp" || warn "ufw 放行 TCP 80 失败，请手动检查防火墙"
    fi
    handled=1
  fi

  if have_cmd firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    info "检测到 firewalld，放行端口"
    if ! firewall-cmd --permanent --add-port="${PORT}/udp"; then
      warn "firewalld 放行 UDP ${PORT} 失败，请手动检查防火墙"
      return 0
    fi
    if [ "$CERT_MODE" = "acme-domain" ] || [ "$CERT_MODE" = "acme-ip" ]; then
      firewall-cmd --permanent --add-port="80/tcp" || warn "firewalld 放行 TCP 80 失败，请手动检查防火墙"
    fi
    firewall-cmd --reload || warn "firewalld reload 失败，请手动执行 firewall-cmd --reload"
    handled=1
  fi

  if [ "$handled" -eq 0 ]; then
    warn "未检测到已启用的 ufw/firewalld；请手动放行 UDP ${PORT}"
    if [ "$CERT_MODE" = "acme-domain" ] || [ "$CERT_MODE" = "acme-ip" ]; then
      warn "ACME standalone 验证还需要手动放行 TCP 80"
      [ "$CERT_MODE" = "acme-ip" ] && warn "ACME IP 证书验证使用 TCP 80；TUIC 业务使用 UDP ${PORT}"
    fi
  fi
}

cleanup_legacy_renewal_helper() {
  if [ -f "$LEGACY_RENEW_SCRIPT" ] || [ -f "$LEGACY_RENEW_SERVICE" ] || [ -f "$LEGACY_RENEW_TIMER" ]; then
    warn "清理旧版本遗留的自建续签 timer，证书续签改由 acme.sh 自带 cron 处理"
    systemctl disable --now "$(basename "$LEGACY_RENEW_TIMER")" >/dev/null 2>&1 || true
    rm -f "$LEGACY_RENEW_SCRIPT" "$LEGACY_RENEW_SERVICE" "$LEGACY_RENEW_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

restart_service_or_rollback() {
  local backup_file="$1"
  if [ "$START_SERVICE" -ne 1 ]; then
    warn "已按选择跳过服务启动；可稍后运行: systemctl enable --now ${SERVICE_NAME}"
    return 0
  fi

  info "启用并重启 ${SERVICE_NAME} 服务"
  if ! systemctl enable "$SERVICE_NAME" >/dev/null; then
    restore_backup "$backup_file"
    die "systemctl enable ${SERVICE_NAME} 失败，请确认官方安装包已安装 systemd 服务"
  fi
  if systemctl restart "$SERVICE_NAME"; then
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      success "${SERVICE_NAME} 服务已运行"
      return 0
    fi
  fi

  warn "${SERVICE_NAME} 服务启动失败，尝试恢复旧配置"
  restore_backup "$backup_file"
  if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  journalctl -u "$SERVICE_NAME" --no-pager -n 50 || true
  die "服务启动失败，请根据日志排查"
}

client_server_value() {
  case "$CERT_MODE" in
    acme-domain)
      printf '%s' "$DOMAIN_VALUE"
      ;;
    acme-ip)
      printf '%s' "$IP_VALUE"
      ;;
    self)
      if looks_like_ip "$SERVER_NAME"; then
        printf '%s' "$SERVER_NAME"
      else
        printf '<your-server-ip>'
      fi
      ;;
    existing)
      if [ -n "$SERVER_NAME" ]; then
        printf '%s' "$SERVER_NAME"
      else
        printf '<your-server>'
      fi
      ;;
  esac
}

client_share_server_value() {
  local server
  server="$(client_server_value)"
  case "$server" in
    *:*)
      if looks_like_ip "$server"; then
        printf '[%s]' "$server"
      else
        printf '%s' "$server"
      fi
      ;;
    *)
      printf '%s' "$server"
      ;;
  esac
}

server_value_is_placeholder() {
  case "$(client_server_value)" in
    \<*\>)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

build_tuic_uri() {
  local server query tag
  server="$(client_share_server_value)"
  tag="sing-box-tuic"
  query="congestion_control=$(url_encode "$CONGESTION")&udp_relay_mode=native&alpn=h3"

  if [ -n "$SERVER_NAME" ]; then
    query="${query}&sni=$(url_encode "$SERVER_NAME")"
  fi
  if [ "$CERT_MODE" = "self" ]; then
    query="${query}&allow_insecure=1"
  fi

  printf 'tuic://%s:%s@%s:%s?%s#%s' \
    "$(url_encode "$UUID_VALUE")" \
    "$(url_encode "$PASSWORD_VALUE")" \
    "$server" \
    "$PORT" \
    "$query" \
    "$(url_encode "$tag")"
}

install_qrencode_if_missing() {
  if have_cmd qrencode; then
    return 0
  fi
  warn "未检测到 qrencode，跳过二维码生成"
  return 1
}

write_client_json() {
  local server tls_extra server_name_line
  server="$(client_server_value)"
  tls_extra=""
  server_name_line=""

  if [ -n "$SERVER_NAME" ]; then
    server_name_line=",
        \"server_name\": $(json_string "$SERVER_NAME")"
  fi
  if [ "$CERT_MODE" = "self" ]; then
    tls_extra=",
        \"insecure\": true"
  fi

  cat <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "tuic",
      "tag": "tuic-out",
      "server": $(json_string "$server"),
      "server_port": ${PORT},
      "uuid": $(json_string "$UUID_VALUE"),
      "password": $(json_string "$PASSWORD_VALUE"),
      "congestion_control": $(json_string "$CONGESTION"),
      "tls": {
        "enabled": true${server_name_line}${tls_extra}
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "tuic-out"
  }
}
EOF
}

save_client_json() {
  mkdir -p "$(dirname -- "$CLIENT_JSON_FILE")"
  write_client_json >"$CLIENT_JSON_FILE"
  chmod 600 "$CLIENT_JSON_FILE"
}

print_client_qr() {
  local client_json

  if server_value_is_placeholder; then
    warn "客户端配置中的服务器地址仍是占位符，替换为真实 IP/域名后再生成二维码"
    return 0
  fi

  heading "客户端配置二维码 (sing-box JSON)"
  if install_qrencode_if_missing; then
    client_json="$(write_client_json)"
    qrencode -t UTF8 "$client_json" || warn "终端 JSON 二维码生成失败，请使用保存的 JSON 文件"
    mkdir -p "$(dirname -- "$CLIENT_JSON_QR_FILE")"
    if qrencode -t PNG -o "$CLIENT_JSON_QR_FILE" "$client_json"; then
      chmod 600 "$CLIENT_JSON_QR_FILE"
      label_value "JSON 二维码 PNG" "$CLIENT_JSON_QR_FILE"
    else
      warn "JSON 二维码 PNG 保存失败"
    fi
  else
    warn "无法自动安装 qrencode，已只输出客户端 JSON 文本"
  fi
}

print_tuic_share() {
  local uri
  uri="$(build_tuic_uri)"

  heading "TUIC 兼容分享链接"
  printf '%s\n' "$uri"
  warn "TUIC URI 不是所有客户端都支持；sing-box 客户端请优先使用上方 JSON 配置。"

  if server_value_is_placeholder; then
    warn "分享链接中的 <your-server-ip> 需要替换为服务器 IP 或域名后再导入客户端"
    return 0
  fi

  if install_qrencode_if_missing; then
    mkdir -p "$(dirname -- "$CLIENT_URI_QR_FILE")"
    if qrencode -t PNG -o "$CLIENT_URI_QR_FILE" "$uri"; then
      chmod 600 "$CLIENT_URI_QR_FILE"
      label_value "URI 二维码 PNG" "$CLIENT_URI_QR_FILE"
    else
      warn "URI 二维码 PNG 保存失败"
    fi
  else
    warn "无法自动安装 qrencode，已只输出 TUIC 兼容链接文本"
  fi
}

print_client_example() {
  heading "客户端 sing-box 完整 config.json"
  write_client_json
  label_value "JSON 文件" "$CLIENT_JSON_FILE"
}

print_summary() {
  heading "sing-box TUIC 配置完成"
  section_divider
  save_client_json
  label_value "配置文件" "$CONFIG_FILE"
  label_value "协议" "TUIC only"
  label_value "监听" "0.0.0.0:${PORT}/udp"
  label_value "UUID" "$UUID_VALUE"
  label_value "Password" "$PASSWORD_VALUE"
  label_value "拥塞控制" "$CONGESTION"
  label_value "证书模式" "$CERT_MODE"
  case "$CERT_MODE" in
    self)
      label_value "证书" "$CERT_FILE"
      warn "自签证书模式下，客户端需启用 tls.insecure=true，或自行导入证书信任。"
      ;;
    acme-domain)
      label_value "ACME 域名" "$DOMAIN_VALUE"
      label_value "证书" "$CERT_FILE"
      label_value "私钥" "$KEY_FILE"
      label_value "续签方式" "acme.sh 自动续签，续签后执行 ${ACME_RELOAD_SCRIPT}"
      ;;
    acme-ip)
      label_value "ACME IP" "$IP_VALUE"
      label_value "证书 Profile" "shortlived"
      label_value "证书" "$CERT_FILE"
      label_value "私钥" "$KEY_FILE"
      label_value "续签方式" "acme.sh 自动 cron，续签后执行 ${ACME_RELOAD_SCRIPT}"
      ;;
    existing)
      label_value "证书" "$CERT_FILE"
      label_value "私钥" "$KEY_FILE"
      ;;
  esac

  if [ "$START_SERVICE" -eq 1 ]; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      label_value "服务状态" "active"
    else
      label_value "服务状态" "inactive"
    fi
    label_value "查看日志" "journalctl -u ${SERVICE_NAME} --output cat -e"
  else
    label_value "启动服务" "systemctl enable --now ${SERVICE_NAME}"
  fi

  print_client_example
  print_client_qr
  print_tuic_share
}

main() {
  init_colors
  parse_args "$@"
  validate_supplied_args
  ensure_environment
  ensure_base_commands

  if [ "$YES" -eq 1 ]; then
    noninteractive_defaults
  else
    if [ ! -t 0 ]; then
      if [ -r /dev/tty ]; then
        INTERACTIVE_INPUT="/dev/tty"
        warn "检测到脚本来自管道输入，交互将改从 /dev/tty 读取"
      else
        die "非交互环境请使用: bash -s -- --yes，并通过参数提供必需值"
      fi
    fi
    interactive_wizard
  fi

  validate_final_inputs
  install_sing_box
  cleanup_legacy_renewal_helper
  configure_firewall
  prepare_certificate

  local backup_file
  backup_file="$(write_config_file)"
  fix_runtime_permissions
  check_config_or_rollback "$backup_file"
  restart_service_or_rollback "$backup_file"
  print_summary
}

main "$@"
