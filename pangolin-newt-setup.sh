#!/usr/bin/env bash
set -euo pipefail

# === Percorsi ===
ENV_DIR="/etc/newt"
ENV_FILE="${ENV_DIR}/newt.env"
WRAPPER="/usr/local/bin/newt-client.sh"
HEALTHCHECK="/usr/local/bin/newt-healthcheck.sh"
LOG_FILE="/var/log/newt-client.log"
UNIT_FILE="/etc/systemd/system/newt.service"
TIMER_FILE="/etc/systemd/system/newt-healthcheck.timer"
HC_SERVICE_FILE="/etc/systemd/system/newt-healthcheck.service"

log(){ echo -e "[newt-setup] $*"; }
need_cmd(){
  command -v "$1" >/dev/null 2>&1 || {
    log "Installo $1 ..."
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y "$1"
    else
      apt-get update -y && apt-get install -y "$1"
    fi
  }
}
assert_root(){
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    else
      echo "Serve root o sudo. Interrompo." >&2; exit 1
    fi
  fi
}

print_help(){
cat <<'EOF'
Uso:
  pangolin-newt-setup.sh [--install|--uninstall|--status|--logs] [--non-interactive]

Non-interactive richiede:
  NEWT_ID, NEWT_SECRET, NEWT_ENDPOINT

Azioni:
  --install    Installa/aggiorna newt + servizio systemd (default)
  --uninstall  Rimuove servizio/timer/script (lascia .env e log)
  --status     Mostra lo stato dei servizi
  --logs       Segue i log del servizio
EOF
}

ACTION="install"; NON_INTERACTIVE="false"
for a in "$@"; do
  case "$a" in
    --install) ACTION="install";;
    --uninstall) ACTION="uninstall";;
    --status) ACTION="status";;
    --logs) ACTION="logs";;
    --non-interactive) NON_INTERACTIVE="true";;
    -h|--help) print_help; exit 0;;
  esac
done

prompt_nonempty(){
  local p="$1" v
  if [[ "${2:-}" == "silent" ]]; then
    while true; do read -r -s -p "$p" v || true; echo; [[ -n "$v" ]] && break; echo "Il valore non può essere vuoto."; done
  else
    while true; do read -r -p "$p" v || true; [[ -n "$v" ]] && break; echo "Il valore non può essere vuoto."; done
  fi
  REPLY="$v"
}

do_install(){
  assert_root "$@"
  need_cmd curl
  need_cmd bash
  need_cmd systemctl

  # 0) Credenziali: sempre richieste all'inizio (interattivo) o lette da env (non-interattivo)
  local NEWT_ID NEWT_SECRET NEWT_ENDPOINT
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    : "${NEWT_ID:?NEWT_ID mancante}"
    : "${NEWT_SECRET:?NEWT_SECRET mancante}"
    : "${NEWT_ENDPOINT:?NEWT_ENDPOINT mancante}"
  else
    echo "== Configura credenziali Pangolin Newt =="
    prompt_nonempty "NEWT_ID: " ; NEWT_ID="$REPLY"
    prompt_nonempty "NEWT_SECRET (nascosto): " silent ; NEWT_SECRET="$REPLY"
    prompt_nonempty "NEWT_ENDPOINT (es. https://pangolin.vosic.fun): " ; NEWT_ENDPOINT="$REPLY"
    echo "Riepilogo: ID=$NEWT_ID  ENDPOINT=$NEWT_ENDPOINT"
    read -r -p "Confermi? [s/N]: " C; [[ "${C,,}" =~ ^(s|si|sì|y|yes)$ ]] || { echo "Annullato."; exit 1; }
  fi

  # 1) Installa/aggiorna il client newt (script ufficiale)
  log "Installo/aggiorno il client newt..."
  bash -c 'curl -fsSL https://digpangolin.com/get-newt.sh | bash'

  # 2) Scrive env sicuro
  log "Scrivo ${ENV_FILE} ..."
  mkdir -p "$ENV_DIR"; chmod 0750 "$ENV_DIR"; umask 0077
  cat > "$ENV_FILE" <<EOF
NEWT_ID="${NEWT_ID}"
NEWT_SECRET="${NEWT_SECRET}"
NEWT_ENDPOINT="${NEWT_ENDPOINT}"
EOF
  chmod 0640 "$ENV_FILE"

  # 3) Wrapper con retry/backoff + logging (flag: --native --accept-clients)
  log "Creo wrapper ${WRAPPER} ..."
  cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="/etc/newt/newt.env"
LOG_FILE="/var/log/newt-client.log"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[newt-client] Manca $ENV_FILE" >&2; exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if ! command -v newt >/dev/null 2>&1; then
  echo "[newt-client] 'newt' non trovato nel PATH" >&2; exit 2
fi

mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"; chmod 0640 "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

echo "[$(date -Iseconds)] Avvio newt (native, accept-clients) -> ${NEWT_ENDPOINT}"

child_pid=""
cleanup(){
  if [[ -n "${child_pid:-}" ]] && kill -0 "$child_pid" 2>/dev/null; then
    echo "[$(date -Iseconds)] Stop richiesto, termino (SIGTERM) pid=$child_pid"
    kill -TERM "$child_pid" || true
    wait "$child_pid" || true
  fi
  echo "[$(date -Iseconds)] Uscita wrapper"
}
trap cleanup SIGINT SIGTERM

backoff=2; max_backoff=60
while true; do
  set +e
  newt --id "${NEWT_ID}" \
       --secret "${NEWT_SECRET}" \
       --endpoint "${NEWT_ENDPOINT}" \
       --native --accept-clients &
  child_pid=$!; wait "$child_pid"; ec=$?
  set -e

  echo "[$(date -Iseconds)] 'newt' uscito con codice ${ec}"

  if [[ $ec -eq 0 ]]; then
    sleep 2; backoff=2; continue
  fi

  sleep "$backoff"
  if [[ $backoff -lt $max_backoff ]]; then
    backoff=$(( backoff * 2 ))
    (( backoff > max_backoff )) && backoff=$max_backoff
  fi
done
EOF
  chmod 0755 "$WRAPPER"

  # 4) Healthcheck
  log "Creo healthcheck ${HEALTHCHECK} ..."
  cat > "$HEALTHCHECK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
UNIT="newt.service"
if ! systemctl is-active --quiet "$UNIT"; then
  echo "[$(date -Iseconds)] $UNIT non attivo: provo restart"
  systemctl restart "$UNIT" || true
  exit 1
fi
exit 0
EOF
  chmod 0755 "$HEALTHCHECK"

  # 5) Servizio systemd + hardening
  log "Creo unit systemd ${UNIT_FILE} ..."
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Pangolin newt - client persistente
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=${ENV_FILE}
ExecStart=${WRAPPER}
Restart=always
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=50

# Hardening & risorse
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=/var/log /etc/newt
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=6

[Install]
WantedBy=multi-user.target
EOF

  # 6) Timer healthcheck ogni 60s
  log "Creo healthcheck timer ..."
  cat > "$HC_SERVICE_FILE" <<EOF
[Unit]
Description=Pangolin newt - healthcheck

[Service]
Type=oneshot
ExecStart=${HEALTHCHECK}
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Pangolin newt - healthcheck timer

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=$(basename "${HC_SERVICE_FILE}")

[Install]
WantedBy=timers.target
EOF

  # 7) Abilita e avvia
  log "Abilito e avvio servizi ..."
  systemctl daemon-reload
  systemctl enable newt.service newt-healthcheck.timer
  systemctl start newt.service newt-healthcheck.timer

  log "Installazione completata."
  echo "Comandi: systemctl status newt.service | journalctl -u newt.service -f | tail -f ${LOG_FILE}"
}

do_uninstall(){
  assert_root "$@"
  systemctl stop newt-healthcheck.timer newt.service || true
  systemctl disable newt-healthcheck.timer newt.service || true
  rm -f "$UNIT_FILE" "$TIMER_FILE" "$HC_SERVICE_FILE" "$WRAPPER" "$HEALTHCHECK"
  systemctl daemon-reload
  echo "Disinstallazione completata. (Mantengo ${ENV_FILE} e ${LOG_FILE})"
}
do_status(){ systemctl --no-pager status newt.service || true; echo; systemctl --no-pager status newt-healthcheck.timer || true; }
do_logs(){ journalctl -u newt.service -f; }

case "$ACTION" in
  install) do_install "$@";;
  uninstall) do_uninstall "$@";;
  status) do_status;;
  logs) do_logs;;
  *) print_help; exit 1;;
esac
