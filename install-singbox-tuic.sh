#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box TUIC quick installer
# References:
# - https://sing-box.sagernet.org/installation/package-manager/
# - https://sing-box.sagernet.org/configuration/inbound/tuic/
# - https://sing-box.sagernet.org/configuration/shared/tls/
# - https://sing-box.sagernet.org/configuration/shared/certificate-provider/acme/

SCRIPT_NAME="${0##*/}"
SERVICE_NAME="sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_DIR="${CONFIG_DIR}/certs"
SELF_CERT_FILE="${CERT_DIR}/tuic-selfsigned.crt"
SELF_KEY_FILE="${CERT_DIR}/tuic-selfsigned.key"
ACME_DATA_DIR="/var/lib/sing-box/acme"
INSTALL_URL="https://sing-box.app/install.sh"
RENEW_SCRIPT="/usr/local/sbin/sing-box-tuic-renew"
RENEW_SERVICE="/etc/systemd/system/sing-box-tuic-renew.service"
RENEW_TIMER="/etc/systemd/system/sing-box-tuic-renew.timer"

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
YES=0
OPEN_FIREWALL=1
START_SERVICE=1

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

info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2
}

success() {
  printf '\033[1;32m[ OK ]\033[0m %s\n' "$*" >&2
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

error() {
  printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
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
    self|self-signed|selfsigned)
      printf 'self'
      ;;
    acme-domain|acme_domain|domain)
      printf 'acme-domain'
      ;;
    acme-ip|acme_ip|ip)
      printf 'acme-ip'
      ;;
    existing|path|file)
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

validate_port() {
  case "$1" in
    ''|*[!0-9]*)
      warn "端口必须是 1-65535 的数字"
      return 1
      ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || {
    warn "端口必须在 1-65535 之间"
    return 1
  }
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

validate_domain() {
  [ -n "$1" ] || {
    warn "域名不能为空"
    return 1
  }
  [[ "$1" =~ ^[A-Za-z0-9*.-]+$ ]] || {
    warn "域名只能包含字母、数字、点、连字符或通配符"
    return 1
  }
}

validate_ip() {
  local value="$1"
  local part
  local -a parts
  [ -n "$value" ] || {
    warn "IP 不能为空"
    return 1
  }
  if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a parts <<<"$value"
    for part in "${parts[@]}"; do
      [ "$((10#$part))" -le 255 ] || {
        warn "IPv4 地址无效"
        return 1
      }
    done
    return 0
  fi
  if [[ "$value" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$value" == *:* ]]; then
    return 0
  fi
  warn "IP 地址格式无效"
  return 1
}

validate_server_name() {
  [ -n "$1" ] || {
    warn "server_name 不能为空"
    return 1
  }
  [[ "$1" =~ ^[A-Za-z0-9*.:-]+$ ]] || {
    warn "server_name 只能包含字母、数字、点、冒号、连字符或通配符"
    return 1
  }
}

validate_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || {
    warn "邮箱格式无效"
    return 1
  }
}

validate_file_exists() {
  [ -f "$1" ] || {
    warn "文件不存在: $1"
    return 1
  }
}

looks_like_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ ^[0-9A-Fa-f:]+$ && "$1" == *:* ]]
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

read_menu_choice() {
  local prompt="$1"
  local choice
  read -r -p "$prompt" choice || exit 1
  printf '%s' "${choice:-1}"
}

prompt_value() {
  local var_name="$1"
  local title="$2"
  local default_value="$3"
  local validator="$4"
  local input_prompt="$5"
  local choice value

  while true; do
    printf '\n%s\n' "$title"
    if [ -n "$default_value" ]; then
      printf '  1) 使用脚本默认值: %s\n' "$default_value"
    else
      printf '  1) 使用脚本默认值: 无可用默认值\n'
    fi
    printf '  2) 自定义输入\n'
    printf '  b) 返回上一步\n'
    printf '  q) 退出\n'

    choice="$(read_menu_choice "请选择 [默认: 1]: ")"
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
          read -r -p "$input_prompt" value || exit 1
          if "$validator" "$value"; then
            printf -v "$var_name" '%s' "$value"
            return 0
          fi
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
    printf '\n%s\n' "$title"
    if [ -n "$default_value" ]; then
      printf '  1) 使用脚本默认值: %s\n' "$default_value"
    else
      printf '  1) 使用脚本默认值: 跳过\n'
    fi
    printf '  2) 自定义输入\n'
    printf '  s) 跳过本项\n'
    printf '  b) 返回上一步\n'
    printf '  q) 退出\n'

    choice="$(read_menu_choice "请选择 [默认: 1]: ")"
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
          read -r -p "$input_prompt" value || exit 1
          if "$validator" "$value"; then
            printf -v "$var_name" '%s' "$value"
            return 0
          fi
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
    printf '\n%s\n' "$title"
    if [ "$default_value" -eq 1 ]; then
      printf '  1) 使用脚本默认值: %s\n' "$yes_label"
      printf '  2) %s\n' "$no_label"
    else
      printf '  1) 使用脚本默认值: %s\n' "$no_label"
      printf '  2) %s\n' "$yes_label"
    fi
    printf '  b) 返回上一步\n'
    printf '  q) 退出\n'

    choice="$(read_menu_choice "请选择 [默认: 1]: ")"
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
    printf '\n证书模式\n'
    printf '  1) 使用脚本默认值: 自签证书\n'
    printf '  2) ACME 域名证书\n'
    printf '  3) ACME IP 证书\n'
    printf '  4) 已有证书路径\n'
    printf '  b) 返回上一步\n'
    printf '  q) 退出\n'
    choice="$(read_menu_choice "请选择 [默认: 1]: ")"
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
              validate_file_exists "$CERT_FILE"
            else
              if ! prompt_value CERT_FILE "已有证书路径" "" validate_file_exists "请输入 certificate_path: "; then
                substep=1
                continue
              fi
            fi
            if [ "$KEY_FILE_SET" -eq 1 ]; then
              validate_file_exists "$KEY_FILE"
            else
              if ! prompt_value KEY_FILE "已有私钥路径" "" validate_file_exists "请输入 key_path: "; then
                substep=1
                continue
              fi
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
  printf '\n'
  info "sing-box TUIC 快捷安装向导"
  info "每一步按 Enter 使用脚本默认值，输入 2 可自定义，输入 b 返回。"

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

install_sing_box() {
  if have_cmd sing-box; then
    info "检测到 sing-box: $(sing-box version 2>/dev/null | head -n 1 || printf 'installed')"
    return 0
  fi

  info "未检测到 sing-box，开始使用官方安装脚本安装稳定版"
  download_install_script | sh
  have_cmd sing-box || die "sing-box 安装失败：安装后仍找不到 sing-box 命令"
  success "sing-box 安装完成: $(sing-box version 2>/dev/null | head -n 1 || printf 'installed')"
}

make_self_signed_certificate() {
  have_cmd openssl || die "自签证书模式需要 openssl，请先安装 openssl"
  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"

  local cn="$SERVER_NAME"
  local san
  if looks_like_ip "$SERVER_NAME"; then
    san="IP:${SERVER_NAME}"
  else
    san="DNS:${SERVER_NAME}"
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

prepare_certificate() {
  case "$CERT_MODE" in
    self)
      make_self_signed_certificate
      ;;
    acme-domain|acme-ip)
      mkdir -p "$ACME_DATA_DIR"
      chmod 700 "$ACME_DATA_DIR"
      ;;
    existing)
      validate_file_exists "$CERT_FILE" || exit 1
      validate_file_exists "$KEY_FILE" || exit 1
      ;;
  esac
}

write_tls_block() {
  case "$CERT_MODE" in
    self|existing)
      cat <<EOF
      "tls": {
        "enabled": true,
        "certificate_path": $(json_string "$CERT_FILE"),
        "key_path": $(json_string "$KEY_FILE")
      }
EOF
      ;;
    acme-domain|acme-ip)
      cat <<EOF
      "tls": {
        "enabled": true,
        "certificate_provider": "tuic-cert"
      }
EOF
      ;;
  esac
}

write_certificate_provider_block() {
  local subject="$DOMAIN_VALUE"
  [ "$CERT_MODE" = "acme-ip" ] && subject="$IP_VALUE"

  cat <<EOF
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "tuic-cert",
      "domain": [
        $(json_string "$subject")
      ],
      "data_directory": $(json_string "$ACME_DATA_DIR"),
      "default_server_name": $(json_string "$subject"),
      "provider": "letsencrypt"
EOF
  if [ -n "$EMAIL_VALUE" ]; then
    cat <<EOF
      ,
      "email": $(json_string "$EMAIL_VALUE")
EOF
  fi
  if [ "$CERT_MODE" = "acme-ip" ]; then
    cat <<EOF
      ,
      "profile": "shortlived"
EOF
  fi
  cat <<EOF
      ,
      "key_type": "p256"
    }
  ],
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
    if [ "$CERT_MODE" = "acme-domain" ] || [ "$CERT_MODE" = "acme-ip" ]; then
      write_certificate_provider_block
    fi
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
      warn "ACME 模式还需要 TCP 80 和 TCP 443 可被公网访问"
      [ "$CERT_MODE" = "acme-ip" ] && warn "ACME IP 证书验证使用 TCP 80/443；TUIC 业务使用 UDP ${PORT}"
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
      ufw allow "443/tcp" || warn "ufw 放行 TCP 443 失败，请手动检查防火墙"
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
      firewall-cmd --permanent --add-port="443/tcp" || warn "firewalld 放行 TCP 443 失败，请手动检查防火墙"
    fi
    firewall-cmd --reload || warn "firewalld reload 失败，请手动执行 firewall-cmd --reload"
    handled=1
  fi

  if [ "$handled" -eq 0 ]; then
    warn "未检测到已启用的 ufw/firewalld；请手动放行 UDP ${PORT}"
    if [ "$CERT_MODE" = "acme-domain" ] || [ "$CERT_MODE" = "acme-ip" ]; then
      warn "ACME 模式还需要手动放行 TCP 80 和 TCP 443"
      [ "$CERT_MODE" = "acme-ip" ] && warn "ACME IP 证书验证使用 TCP 80/443；TUIC 业务使用 UDP ${PORT}"
    fi
  fi
}

install_ip_certificate_renewal_helper() {
  if [ "$CERT_MODE" != "acme-ip" ]; then
    return 0
  fi

  info "安装 ACME IP 证书自动验证/续签检查命令"
  cat >"$RENEW_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE=$(json_string "$CONFIG_FILE")
SERVICE_NAME=$(json_string "$SERVICE_NAME")

echo "[INFO] checking sing-box configuration: \${CONFIG_FILE}"
sing-box check -c "\${CONFIG_FILE}"

echo "[INFO] restarting \${SERVICE_NAME} to trigger ACME IP certificate check/renewal"
systemctl restart "\${SERVICE_NAME}"

echo "[INFO] service status"
systemctl --no-pager --full status "\${SERVICE_NAME}" || true

echo "[INFO] recent logs"
journalctl -u "\${SERVICE_NAME}" --no-pager -n 80
EOF
  chmod 755 "$RENEW_SCRIPT"

  cat >"$RENEW_SERVICE" <<EOF
[Unit]
Description=Check and trigger sing-box TUIC ACME IP certificate renewal
Documentation=https://sing-box.sagernet.org/configuration/shared/certificate-provider/acme/
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RENEW_SCRIPT}
EOF

  cat >"$RENEW_TIMER" <<EOF
[Unit]
Description=Daily sing-box TUIC ACME IP certificate renewal check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$(basename "$RENEW_TIMER")" >/dev/null || {
    warn "自动续签检查 timer 启用失败，可手动运行: ${RENEW_SCRIPT}"
    return 0
  }
  success "已安装自动续签检查: $(basename "$RENEW_TIMER")"
}

remove_ip_certificate_renewal_helper() {
  if [ "$CERT_MODE" != "acme-ip" ]; then
    return 0
  fi

  systemctl disable --now "$(basename "$RENEW_TIMER")" >/dev/null 2>&1 || true
  rm -f "$RENEW_SCRIPT" "$RENEW_SERVICE" "$RENEW_TIMER"
  systemctl daemon-reload >/dev/null 2>&1 || true
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
  remove_ip_certificate_renewal_helper
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

print_client_example() {
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

客户端 TUIC outbound 示例:
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
}
EOF
}

print_summary() {
  printf '\n'
  success "sing-box TUIC 配置完成"
  printf '配置文件: %s\n' "$CONFIG_FILE"
  printf '协议: TUIC only\n'
  printf '监听: 0.0.0.0:%s/udp\n' "$PORT"
  printf 'UUID: %s\n' "$UUID_VALUE"
  printf 'Password: %s\n' "$PASSWORD_VALUE"
  printf '拥塞控制: %s\n' "$CONGESTION"
  printf '证书模式: %s\n' "$CERT_MODE"
  case "$CERT_MODE" in
    self)
      printf '证书: %s\n' "$CERT_FILE"
      warn "自签证书模式下，客户端需启用 tls.insecure=true，或自行导入证书信任。"
      ;;
    acme-domain)
      printf 'ACME 域名: %s\n' "$DOMAIN_VALUE"
      ;;
    acme-ip)
      printf 'ACME IP: %s\n' "$IP_VALUE"
      printf '证书 Profile: shortlived\n'
      printf '手动触发验证/续签检查: %s\n' "$RENEW_SCRIPT"
      printf '查看自动续签检查 timer: systemctl list-timers %s\n' "$(basename "$RENEW_TIMER")"
      printf '查看续签检查日志: journalctl -u %s --output cat -e\n' "$(basename "$RENEW_SERVICE")"
      ;;
    existing)
      printf '证书: %s\n' "$CERT_FILE"
      printf '私钥: %s\n' "$KEY_FILE"
      ;;
  esac

  if [ "$START_SERVICE" -eq 1 ]; then
    printf '服务状态: '
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      printf 'active\n'
    else
      printf 'inactive\n'
    fi
    printf '查看日志: journalctl -u %s --output cat -e\n' "$SERVICE_NAME"
  else
    printf '启动服务: systemctl enable --now %s\n' "$SERVICE_NAME"
  fi

  print_client_example
}

main() {
  parse_args "$@"
  validate_supplied_args
  ensure_environment

  if [ "$YES" -eq 1 ]; then
    noninteractive_defaults
  else
    [ -t 0 ] || die "非交互环境请使用 --yes，并通过参数提供必需值"
    interactive_wizard
  fi

  validate_final_inputs
  install_sing_box
  prepare_certificate

  local backup_file
  backup_file="$(write_config_file)"
  check_config_or_rollback "$backup_file"
  configure_firewall
  install_ip_certificate_renewal_helper
  restart_service_or_rollback "$backup_file"
  print_summary
}

main "$@"
