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

# Diretórios persistentes
BASE_DIR="${HOME}/.local/share/syncthing"
CONFIG_DIR="${BASE_DIR}/config"
STATE_DIR="${BASE_DIR}/state"

# Diretório systemd --user
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

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
  if podman ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
      log "Removendo container antigo (${CONTAINER_NAME})..."
      podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

remove_service_if_exists() {
  if [ -f "${SYSTEMD_USER_DIR}/${SERVICE_NAME}" ]; then
      log "Removendo arquivo de serviço (${SERVICE_NAME})..."
      systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
      rm -f "${SYSTEMD_USER_DIR}/${SERVICE_NAME}"
  fi
}

install_service_file() {
  log "Criando arquivo de serviço systemd em ${SYSTEMD_USER_DIR}/${SERVICE_NAME}..."
  
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
    log "Linger já habilitado para ${USER}."
  else
    warn "Linger NÃO está habilitado."
    warn "Execute como root:"
    warn "  sudo loginctl enable-linger ${USER}"
  fi
}

print_post_install_notes() {
  cat <<EOF

✅ Syncthing configurado e iniciado!

🌐 GUI:
   http://localhost:${GUI_PORT}

📁 Estrutura de Pastas:
   Config: ${CONFIG_DIR}
   State:  ${STATE_DIR}
   Data:   ${HOME} (Mapeado para /data no Syncthing)

⚠️ NOTA:
   O Syncthing verá seu HOME em /data.
   Na GUI do Syncthing, ao adicionar pastas, use caminhos iniciando com /data/
   Exemplo: /data/Documents

EOF
}

############################################
# COMANDOS
############################################

cmd_install() {
  ensure_prereqs
  
  log "Preparando diretórios..."
  mkdir -p "${CONFIG_DIR}"
  mkdir -p "${STATE_DIR}"
  
  # Remove old artifacts to avoid conflict
  remove_service_if_exists
  remove_container_if_exists # Clean up valid/invalid previous containers

  install_service_file
  
  log "Habilitando serviço..."
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}"
  
  # Wait for container to start
  log "Aguardando inicialização..."
  sleep 3
  
  # Check if container is actually running
  if ! podman ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
      echo ""
      err "FALHA: O container não iniciou corretamente."
      log "Logs do container:"
      podman logs "${CONTAINER_NAME}" 2>&1 | tail -n 20
      echo ""
      err "Verifique o status do serviço: systemctl --user status ${SERVICE_NAME}"
      exit 1
  fi
  
  check_linger
  print_post_install_notes
}

cmd_update() {
  ensure_prereqs
  log "Atualizando imagem ${IMAGE}..."
  podman pull "${IMAGE}"
  
  log "Reiniciando serviço para aplicar nova imagem..."
  systemctl --user restart "${SERVICE_NAME}"
  log "Update concluído."
}

cmd_start() {
    log "Iniciando serviço ${SERVICE_NAME}..."
    systemctl --user start "${SERVICE_NAME}"
    log "Comando start enviado."
    cmd_check
}

cmd_stop() {
  log "Parando serviço ${SERVICE_NAME}..."
  systemctl --user stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  
  # Wait a bit
  sleep 2
  
  # Force stop if still running (though ExecStop should handle it)
  if podman ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
     log "Container ainda rodando, forçando stop..."
     podman stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
  
  log "Stop concluído."
}

cmd_redeploy() {
    log "Redeploy (reinstall) solicitado..."
    cmd_install
}

cmd_uninstall() {
    log "Desinstalação solicitada..."
    cmd_stop
    remove_service_if_exists
    
    # ExecStopPost usually removes it, but ensure it's gone
    podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    systemctl --user daemon-reload
    
    log "Desinstalação concluída."
    warn "Os dados de configuração permanecem em: ${BASE_DIR}"
}

cmd_destroy() {
  echo -e "\033[0;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m"
  echo -e "\033[0;31m                      CUIDADO !!!                           \033[0m"
  echo -e "\033[0;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m"
  echo -e "\033[0;31mEste comando irá REMOVER O SERVIÇO, CONTAINER E AS\033[0m"
  echo -e "\033[0;31mCONFIGURAÇÕES/DB EM ${BASE_DIR}\033[0m"
  echo -e "\033[0;31m(Seus arquivos pessoais no HOME não serão tocados)\033[0m"
  echo ""
  read -p "Tem certeza absoluta? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Aborted."
    exit 1
  fi
  
  cmd_uninstall
  
  if [ -d "${BASE_DIR}" ]; then
    log "Removendo diretório de config/state: ${BASE_DIR}"
    rm -rf "${BASE_DIR}"
    log "Removido."
  fi
}

cmd_check() {
  log "Verificando status..."
  
  echo "--- Systemd Service ---"
  systemctl --user status "${SERVICE_NAME}" --no-pager || echo "Serviço não está rodando."
  
  echo ""
  echo "--- Container ---"
  podman ps --filter "name=${CONTAINER_NAME}" --format "table {{.ID}} {{.Image}} {{.Status}} {{.Ports}}"
  
  echo ""
  echo "--- Diretórios ---"
  if [ -d "${CONFIG_DIR}" ]; then echo "Config: OK (${CONFIG_DIR})"; else echo "Config: MISSING"; fi
  if [ -d "${STATE_DIR}" ]; then echo "State:  OK (${STATE_DIR})"; else echo "State:  MISSING"; fi
}


############################################
# MAIN
############################################

usage() {
  cat <<EOF
Uso:
  $0 install   Instala Syncthing (cria unit systemd e diretórios)
  $0 update    Atualiza imagem e reinicia
  $0 start     Inicia o serviço
  $0 stop      Para o serviço
  $0 restart   Reinicia o serviço
  $0 status/check Verifica status
  $0 destroy   Remove TUDO (inclusive configs)
  $0 uninstall Remove serviço/container (mantém configs)

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
