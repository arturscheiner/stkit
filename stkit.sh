#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIGURAÇÕES (AJUSTE AQUI)
############################################

# Nome do container e do serviço
CONTAINER_NAME="syncthing"
SERVICE_BASENAME="container-syncthing"
SERVICE_NAME="${SERVICE_BASENAME}.service"

# Imagem do Syncthing (use :2 para seguir major version)
IMAGE="docker.io/syncthing/syncthing:2"

# Portas (expor em todos os IPs)
GUI_PORT="8384"
SYNC_TCP_PORT="22000"
SYNC_UDP_PORT="22000"
DISCOVERY_UDP_PORT="21027"

# Diretório de dados persistente no host
DATA_DIR="${HOME}/.local/share/syncthing"

# Diretório systemd --user
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

# Flags de runtime
USERNS_FLAG="--userns=keep-id"
RESTART_POLICY="unless-stopped"

############################################
# FUNÇÕES UTILITÁRIAS
############################################

log()  { echo -e "[+] $*"; }
warn() { echo -e "[!] $*"; }
err()  { echo -e "[✗] $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Comando '$1' não encontrado"; exit 1; }
}

ensure_prereqs() {
  require_cmd podman
  require_cmd systemctl
}

remove_container_if_exists() {
  podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

remove_service_if_exists() {
  rm -f "${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
}

start_container_once() {
  log "Subindo container (${CONTAINER_NAME}) em modo HOME compartilhado..."
  podman run -d \
    --name "${CONTAINER_NAME}" \
    ${USERNS_FLAG} \
    --restart "${RESTART_POLICY}" \
    --security-opt label=disable \
    -e STDATADIR=/var/syncthing \
    -v "${DATA_DIR}:/var/syncthing" \
    -p "${GUI_PORT}:${GUI_PORT}" \
    -p "${SYNC_TCP_PORT}:${SYNC_TCP_PORT}/tcp" \
    -p "${SYNC_UDP_PORT}:${SYNC_UDP_PORT}/udp" \
    -p "${DISCOVERY_UDP_PORT}:${DISCOVERY_UDP_PORT}/udp" \
    "${IMAGE}"
}

generate_systemd_unit() {
  log "Gerando unit systemd --user a partir do container..."
  podman generate systemd \
    --name "${CONTAINER_NAME}" \
    --files \
    --new

  mkdir -p "${SYSTEMD_USER_DIR}"
  mv "container-${CONTAINER_NAME}.service" "${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
}

enable_and_start_service() {
  log "Habilitando e iniciando serviço systemd --user..."
  systemctl --user daemon-reexec
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}"
}

check_linger() {
  if loginctl show-user "${USER}" | grep -q "Linger=yes"; then
    log "Linger já habilitado para ${USER}."
  else
    warn "Linger NÃO está habilitado."
    warn "Execute como root:"
    warn "  sudo loginctl enable-linger ${USER}"
  fi
}

print_post_install_notes() {
  cat <<EOF

✅ Syncthing instalado como serviço (systemd --user)

🌐 GUI:
   http://localhost:${GUI_PORT}

📁 Dados persistentes:
   ${DATA_DIR}
   (Mapeado para /var/syncthing no container)

⚠️ RECOMENDAÇÕES DE SEGURANÇA:
   Configure IGNORE PATTERNS:
     .cache/
     .local/share/Trash/
     .ssh/
     .gnupg/
     *.sock
     *.lock

🔁 Atualizar:
   ./syncthing update

EOF
}

############################################
# COMANDOS
############################################

cmd_install() {
  ensure_prereqs
  mkdir -p "${DATA_DIR}"
  log "Instalação iniciada..."

  remove_service_if_exists
  remove_container_if_exists
  start_container_once
  generate_systemd_unit
  enable_and_start_service
  check_linger
  print_post_install_notes
}

cmd_update() {
  ensure_prereqs
  log "Atualizando imagem ${IMAGE}..."

  podman pull "${IMAGE}"

  if systemctl --user is-enabled "${SERVICE_NAME}" >/dev/null 2>&1; then
    log "Reiniciando serviço ${SERVICE_NAME}..."
    systemctl --user restart "${SERVICE_NAME}"
  else
    warn "Serviço ${SERVICE_NAME} não está habilitado. Nada para reiniciar."
  fi

  log "Update concluído."
}

cmd_stop() {
  log "Parando serviço ${SERVICE_NAME}..."
  systemctl --user stop "${SERVICE_NAME}"
  
  # Ensure container is stopped if running outside service or stuck
  if podman ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
     log "Parando container ${CONTAINER_NAME} (cleanup)..."
     podman stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
  
  log "Stop concluído."
}

cmd_redeploy() {
  log "Redeploy solicitado. Reiniciando todo o processo de instalação..."
  cmd_install
}

cmd_uninstall() {
  log "Desinstalação solicitada..."
  
  cmd_stop
  remove_service_if_exists
  
  # Clean up systemd
  systemctl --user daemon-reload
  
  # Remove container (cmd_stop does validation, but we force remove here just in case)
  remove_container_if_exists

  log "Desinstalação concluída."
  warn "NOTA: Seus dados EM DISCO não foram removidos."
  warn "Diretório de dados: ${DATA_DIR}"
  warn "Para remover totalmente: rm -rf \"${DATA_DIR}\""
}

############################################
# MAIN
############################################

usage() {
  cat <<EOF
Uso:
  $0 install   Instala Syncthing como serviço systemd --user
  $0 update    Atualiza a imagem e reinicia o serviço
  $0 stop      Para o serviço e o container
  $0 redeploy  Remove e recria o container (reinstala)
  $0 uninstall Remove o serviço e o container (mantém dados)

Configurações:
  Ajuste as variáveis no topo do arquivo.
EOF
}

case "${1:-}" in
  install)  cmd_install ;;
  update)   cmd_update  ;;
  stop)     cmd_stop    ;;
  redeploy) cmd_redeploy ;;
  uninstall) cmd_uninstall ;;
  *)       usage; exit 1 ;;
esac
