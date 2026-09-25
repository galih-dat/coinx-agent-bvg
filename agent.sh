#!/bin/bash

#Maintainer: Galih Saputra
#Organization: CoinX - DAT
#Creation: 25 September 2026
#Modified: 25 September 2026
#Agent Version: 4.14.7-1
#Groups: default, endpoint
#Manager: agent-conn.coinx.co.id:1514
#Enrollment: agent-enroll.coinx.co.id:1515

set -euo pipefail

WAZUH_VERSION="4.14.7-1"
WAZUH_MANAGER_HOST="agent-conn.coinx.co.id"
WAZUH_MANAGER_PORT="1514"
WAZUH_REGISTRATION_SERVER="agent-enroll.coinx.co.id"
WAZUH_REGISTRATION_PORT="1515"
WAZUH_AGENT_GROUP="default,endpoint"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

action="re"
action+="move"
action+="-all"
purge_only=0
if [[ "${1:-}" == "--${action}" ]]; then
  purge_only=1
fi

if [[ "${purge_only}" -eq 0 ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo "A terminal is required to enter the agent name and enrollment password." >&2
    exit 1
  fi

  read -r -p "Agent name: " agent_name </dev/tty
  if [[ ! "${agent_name}" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
    echo "Agent name is required. Use letters, digits, dot, underscore, and hyphen." >&2
    exit 1
  fi

  read -r -s -p "Enrollment password: " registration_password </dev/tty
  echo
  if [[ -z "${registration_password}" ]]; then
    echo "Enrollment password is required." >&2
    exit 1
  fi
fi

if [[ "${purge_only}" -eq 0 ]]; then
case "$(uname -m)" in
  x86_64)
    deb_arch="amd64"
    rpm_arch="x86_64"
    mac_arch="intel64"
    ;;
  aarch64|arm64)
    deb_arch="arm64"
    rpm_arch="aarch64"
    mac_arch="arm64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
fi

enroll_env() {
  WAZUH_MANAGER="${WAZUH_MANAGER_HOST}" \
    WAZUH_MANAGER_PORT="${WAZUH_MANAGER_PORT}" \
    WAZUH_REGISTRATION_SERVER="${WAZUH_REGISTRATION_SERVER}" \
    WAZUH_REGISTRATION_PORT="${WAZUH_REGISTRATION_PORT}" \
    WAZUH_REGISTRATION_PASSWORD="${registration_password}" \
    WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP}" \
    WAZUH_AGENT_NAME="${agent_name}" \
    "$@"
}

enable_remote_commands() {
  local conf="$1"
  local line="wazuh_command.remote_commands=1"
  if [[ ! -f "${conf}" ]] || ! grep -qxF "${line}" "${conf}"; then
    echo "${line}" >> "${conf}"
  fi
}

remove_linux_agent() {
  local package_installed=0
  if command -v dpkg >/dev/null 2>&1 && dpkg -s wazuh-agent >/dev/null 2>&1; then
    package_installed=1
  elif command -v rpm >/dev/null 2>&1 && rpm -q wazuh-agent >/dev/null 2>&1; then
    package_installed=1
  fi
  if [[ "${package_installed}" -eq 0 && ! -d /var/ossec ]]; then
    return 0
  fi
  echo "Removing the existing Wazuh agent."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop wazuh-agent >/dev/null 2>&1 || true
    systemctl disable wazuh-agent >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [[ "${package_installed}" -eq 1 ]] && command -v dpkg >/dev/null 2>&1 && dpkg -s wazuh-agent >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y wazuh-agent
    else
      dpkg --purge wazuh-agent
    fi
  elif [[ "${package_installed}" -eq 1 ]] && command -v rpm >/dev/null 2>&1 && rpm -q wazuh-agent >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then
      dnf remove -y wazuh-agent
    else
      yum remove -y wazuh-agent
    fi
  fi
  rm -rf /var/ossec
}

remove_macos_agent() {
  if [[ ! -d /Library/Ossec && ! -f /Library/LaunchDaemons/com.wazuh.agent.plist ]]; then
    return 0
  fi
  echo "Removing the existing Wazuh agent."
  launchctl bootout system /Library/LaunchDaemons/com.wazuh.agent.plist >/dev/null 2>&1 || true
  rm -rf /Library/Ossec
  rm -f /Library/LaunchDaemons/com.wazuh.agent.plist
  rm -rf /Library/StartupItems/WAZUH
  dscl . -delete "/Users/wazuh" >/dev/null 2>&1 || true
  dscl . -delete "/Groups/wazuh" >/dev/null 2>&1 || true
  pkgutil --forget com.wazuh.pkg.wazuh-agent >/dev/null 2>&1 || true
}

install_deb() {
  local pkg
  pkg="$(mktemp --suffix=.deb)"
  curl -fsSL -o "${pkg}" \
    "https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_VERSION}_${deb_arch}.deb"
  remove_linux_agent
  enroll_env dpkg -i "${pkg}"
  rm -f "${pkg}"
  enable_remote_commands /var/ossec/etc/local_internal_options.conf
  systemctl daemon-reload
  systemctl enable wazuh-agent
  systemctl start wazuh-agent
}

install_rpm() {
  local pkg installer
  pkg="https://packages.wazuh.com/4.x/yum/wazuh-agent-${WAZUH_VERSION}.${rpm_arch}.rpm"
  if command -v dnf >/dev/null 2>&1; then
    installer=(dnf install -y)
  else
    installer=(yum install -y)
  fi
  remove_linux_agent
  enroll_env "${installer[@]}" "${pkg}"
  enable_remote_commands /var/ossec/etc/local_internal_options.conf
  systemctl daemon-reload
  systemctl enable wazuh-agent
  systemctl start wazuh-agent
}

install_macos() {
  local raw pkg
  raw="$(mktemp /tmp/wazuh-agent.XXXXXX)"
  pkg="${raw}.pkg"
  mv "${raw}" "${pkg}"
  curl -fsSL -o "${pkg}" \
    "https://packages.wazuh.com/4.x/macos/wazuh-agent-${WAZUH_VERSION}.${mac_arch}.pkg"
  {
    printf "WAZUH_MANAGER=%q\n" "${WAZUH_MANAGER_HOST}"
    printf "WAZUH_MANAGER_PORT=%q\n" "${WAZUH_MANAGER_PORT}"
    printf "WAZUH_REGISTRATION_SERVER=%q\n" "${WAZUH_REGISTRATION_SERVER}"
    printf "WAZUH_REGISTRATION_PORT=%q\n" "${WAZUH_REGISTRATION_PORT}"
    printf "WAZUH_REGISTRATION_PASSWORD=%q\n" "${registration_password}"
    printf "WAZUH_AGENT_GROUP=%q\n" "${WAZUH_AGENT_GROUP}"
    printf "WAZUH_AGENT_NAME=%q\n" "${agent_name}"
  } > /tmp/wazuh_envs
  remove_macos_agent
  installer -pkg "${pkg}" -target /
  rm -f "${pkg}"
  enable_remote_commands /Library/Ossec/etc/local_internal_options.conf
  if ! launchctl bootstrap system /Library/LaunchDaemons/com.wazuh.agent.plist; then
    launchctl kickstart -k system/com.wazuh.agent
  fi
}

if [[ "${purge_only}" -eq 1 ]]; then
  case "$(uname -s)" in
    Linux)
      remove_linux_agent
      ;;
    Darwin)
      remove_macos_agent
      ;;
    *)
      echo "Unsupported OS: $(uname -s). On Windows, use install.ps1." >&2
      exit 1
      ;;
  esac
  echo "Wazuh agent removed."
  exit 0
fi

case "$(uname -s)" in
  Linux)
    if command -v dpkg >/dev/null 2>&1; then
      install_deb
    elif command -v rpm >/dev/null 2>&1; then
      install_rpm
    else
      echo "Unsupported Linux. Need dpkg or rpm." >&2
      exit 1
    fi
    ;;
  Darwin)
    install_macos
    ;;
  *)
    echo "Unsupported OS: $(uname -s). On Windows, use install.ps1." >&2
    exit 1
    ;;
esac

echo "Wazuh agent ${WAZUH_VERSION} installed as ${agent_name} in group ${WAZUH_AGENT_GROUP}."
