#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIGURATION (ADJUST HERE)
############################################

# Container and Service Name
CONTAINER_NAME="syncthing"
SERVICE_BASENAME="container-syncthing"
SERVICE_NAME="${SERVICE_BASENAME}.service"

# Syncthing Image (use :2 to follow major version)
IMAGE="docker.io/syncthing/syncthing:2"

# Ports (exposed on all IPs)
GUI_PORT="8384"
SYNC_TCP_PORT="22000"
SYNC_UDP_PORT="22000"
DISCOVERY_UDP_PORT="21027"

# Persistent Directories
BASE_DIR="${HOME}/.local/share/syncthing"
CONFIG_DIR="${BASE_DIR}/config"
STATE_DIR="${BASE_DIR}/state"

# Systemd User Directory
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

############################################
# UTILITY FUNCTIONS
############################################

log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*"; }
err()  { echo -e "[✗] $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Command '$1' not found"; exit 1; }
}

ensure_prereqs() {
  require_cmd podman
  require_cmd systemctl
}

remove_container_if_exists() {
  if podman ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
      log "Removing old container (${CONTAINER_NAME})..."
      podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

remove_service_if_exists() {
  if [ -f "${SYSTEMD_USER_DIR}/${SERVICE_NAME}" ]; then
      log "Removing service file (${SERVICE_NAME})..."
      systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
      rm -f "${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
  fi
}

install_service_file() {
  log "Creating systemd service file at ${SYSTEMD_USER_DIR}/${SERVICE_NAME}..."
  
  mkdir -p "${SYSTEMD_USER_DIR}"

  # Note: ExecStart explicitly calls podman run
  cat <<EOF > "${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
[Unit]
Description=Syncthing (Podman, explicit config/data)
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
TimeoutStopSec=60
Environment=PODMAN_SYSTEMD_UNIT=%n

ExecStart=/usr/bin/podman run \\
  --name ${CONTAINER_NAME} \\
  --replace \\
  --userns=keep-id \\
  --security-opt label=disable \\
  --unsetenv STHOMEDIR \\
  -v %h/.local/share/syncthing/config:/config \\
  -v %h/.local/share/syncthing/state:/state \\
  -v %h:/data \\
  -p ${GUI_PORT}:8384 \\
  -p ${SYNC_TCP_PORT}:22000/tcp \\
  -p ${SYNC_UDP_PORT}:22000/udp \\
  -p ${DISCOVERY_UDP_PORT}:21027/udp \\
  ${IMAGE} \\
    --config=/config \\
    --data=/state \\
    --gui-address=0.0.0.0:8384

ExecStop=/usr/bin/podman stop -t 10 ${CONTAINER_NAME}
ExecStopPost=/usr/bin/podman rm -f ${CONTAINER_NAME}

[Install]
WantedBy=default.target
EOF
}

check_linger() {
  if loginctl show-user "${USER}" | grep -q "Linger=yes"; then
    log "Linger already enabled for ${USER}."
  else
    warn "Linger is NOT enabled."
    warn "Run as root:"
    warn "  sudo loginctl enable-linger ${USER}"
  fi
}

print_post_install_notes() {
  cat <<EOF

✅ Syncthing configured and started!

🌐 GUI:
   http://localhost:${GUI_PORT}

📁 Folder Structure:
   Config: ${CONFIG_DIR}
   State:  ${STATE_DIR}
   Data:   ${HOME} (Mapped to /data in Syncthing)

⚠️ NOTE:
   Syncthing will see your HOME at /data.
   In Syncthing GUI, when adding folders, use paths starting with /data/
   Example: /data/Documents

EOF
}

############################################
# COMMANDS
############################################

cmd_install() {
  ensure_prereqs
  
  log "Preparing directories..."
  mkdir -p "${CONFIG_DIR}"
  mkdir -p "${STATE_DIR}"
  
  # Remove old artifacts to avoid conflict
  remove_service_if_exists
  remove_container_if_exists # Clean up valid/invalid previous containers

  install_service_file
  
  log "Enabling service..."
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}"
  
  # Wait for container to start (retry loop)
  log "Waiting for initialization..."
  for i in {1..20}; do
      if podman ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
          log "Container started successfully."
          check_linger
          print_post_install_notes
          return 0
      fi
      sleep 1
  done
  
  # If we reach here, it failed (timeout)
  echo ""
  err "FAILURE: Container did not start within 20 seconds."
  log "Container logs (if any):"
  podman logs "${CONTAINER_NAME}" 2>&1 | tail -n 20
  echo ""
  err "Check service status: systemctl --user status ${SERVICE_NAME}"
  exit 1
}

cmd_update() {
  ensure_prereqs
  log "Updating image ${IMAGE}..."
  podman pull "${IMAGE}"
  
  log "Restarting service to apply new image..."
  systemctl --user restart "${SERVICE_NAME}"
  log "Update complete."
}

cmd_start() {
    log "Starting service ${SERVICE_NAME}..."
    systemctl --user start "${SERVICE_NAME}"
    log "Start command sent."
    cmd_check
}

cmd_stop() {
  log "Stopping service ${SERVICE_NAME}..."
  systemctl --user stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  
  # Wait a bit
  sleep 2
  
  # Force stop if still running (though ExecStop should handle it)
  if podman ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
     log "Container still running, forcing stop..."
     podman stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
  
  log "Stop complete."
}

cmd_redeploy() {
    log "Redeploy (reinstall) requested..."
    cmd_install
}

cmd_uninstall() {
    log "Uninstall requested..."
    cmd_stop
    remove_service_if_exists
    
    # ExecStopPost usually removes it, but ensure it's gone
    podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    systemctl --user daemon-reload
    
    log "Uninstall complete."
    warn "Configuration data remains in: ${BASE_DIR}"
}

cmd_destroy() {
  echo -e "\033[0;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m"
  echo -e "\033[0;31m                      WARNING !!!                           \033[0m"
  echo -e "\033[0;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m"
  echo -e "\033[0;31mThis command will REMOVE THE SERVICE, CONTAINER AND\033[0m"
  echo -e "\033[0;31mCONFIG/DB in ${BASE_DIR}\033[0m"
  echo -e "\033[0;31m(Your personal files in HOME will not be touched)\033[0m"
  echo ""
  read -p "Are you absolutely sure? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Aborted."
    exit 1
  fi
  
  cmd_uninstall
  
  if [ -d "${BASE_DIR}" ]; then
    log "Removing config/state directory: ${BASE_DIR}"
    rm -rf "${BASE_DIR}"
    log "Removed."
  fi
}

cmd_check() {
  log "Checking status..."
  
  echo "--- Systemd Service ---"
  systemctl --user status "${SERVICE_NAME}" --no-pager || echo "Service is not running."
  
  echo ""
  echo "--- Container ---"
  podman ps --filter "name=${CONTAINER_NAME}" --format "table {{.ID}} {{.Image}} {{.Status}} {{.Ports}}"
  
  echo ""
  echo "--- Directories ---"
  if [ -d "${CONFIG_DIR}" ]; then echo "Config: OK (${CONFIG_DIR})"; else echo "Config: MISSING"; fi
  if [ -d "${STATE_DIR}" ]; then echo "State:  OK (${STATE_DIR})"; else echo "State:  MISSING"; fi

  echo ""
  echo "--- Configured Folders ---"
  local config_file="${CONFIG_DIR}/config.xml"
  if [ -f "${config_file}" ]; then
      grep "<folder " "${config_file}" | while read -r line; do
          # Extract attributes using regex
          id=$(echo "$line" | grep -o 'id="[^"]*"' | cut -d'"' -f2)
          label=$(echo "$line" | grep -o 'label="[^"]*"' | cut -d'"' -f2)
          path=$(echo "$line" | grep -o 'path="[^"]*"' | cut -d'"' -f2)
          
          # Map /data back to $HOME
          # We use | as delimiter for sed to avoid issues with slashes in path
          real_path=$(echo "$path" | sed "s|^/data|${HOME}|")
          
          echo "Label:     ${label}"
          echo "ID:        ${id}"
          echo "Sync Path: ${path}"
          echo "Real Path: ${real_path}"
          echo "-------------------------"
      done
  else
      echo "Config file not found: ${config_file}"
  fi
}


############################################
# MAIN
############################################

usage() {
  cat <<EOF
Usage:
  $0 install   Install Syncthing (create systemd unit and directories)
  $0 update    Update image and restart
  $0 start     Start the service
  $0 stop      Stop the service
  $0 restart   Restart the service
  $0 status/check Check status
  $0 destroy   Remove EVERYTHING (including configs)
  $0 uninstall Remove service/container (keep configs)

EOF
}

case "${1:-}" in
  install)       cmd_install ;;
  update)        cmd_update  ;;
  start)         cmd_start   ;;
  stop)          cmd_stop    ;;
  restart)       systemctl --user restart "${SERVICE_NAME}"; cmd_check ;;
  check|status)  cmd_check   ;;
  destroy)       cmd_destroy ;;
  uninstall)     cmd_uninstall ;;
  redeploy)      cmd_install ;; # alias
  *)             usage; exit 1 ;;
esac
