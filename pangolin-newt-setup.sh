#!/usr/bin/env bash
set -euo pipefail

# setup-newt.sh — Installazione Newt + servizio systemd + healthcheck
# Testato su Ubuntu/Debian systemd. Richiede privilegi root.

assert_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Devi eseguire questo script come root (sudo)." >&2
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Comando richiesto non trovato: $1" >&2; exit 1; }
}

confirm() {
  local prompt="${1:-Confermi?} [s/N]: "
  read -r -p "$prompt" ans || true
  [[ "${ans,,}" == "s" || "${ans,,}" == "si" || "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

install_newt_if_missing() {
  if ! command -v newt >/dev/null 2>&1; then
    echo "Newt non trovato, procedo con l'installer ufficiale..."
    curl -fsSL https://digpangolin.com/get-newt.sh | bash
    if ! command -v newt >/dev/null 2>&1; then
      echo "Errore: installazione di Newt fallita." >&2
      exit 1
    fi
  else
    echo "Newt è già installato in $(command -v newt)"
  fi
}

prompt_inputs() {
  echo "== Parametri di connessione a Pangolin/Newt =="
  read -r -p "Endpoint (es. https://pangolin.tuodominio.tld): " PANGOLIN_ENDPOINT
  read -r -p "Newt ID: " NEWT_ID
  read -r -s -p "Newt Secret: " NEWT_SECRET; echo

  # Opzioni avanzate
  echo "== Opzioni avanzate =="
  if confirm "Abilitare --accept-clients (consente connessioni client al tuo Newt)?"; then
    ACCEPT_CLIENTS=true
  else
    ACCEPT_CLIENTS=false
  fi

  if confirm "Usare modalità --native (interfaccia WireGuard del kernel, Linux only, richiede privilegi elevati)?"; then
    USE_NATIVE=true
  else
    USE_NATIVE=false
  fi

  read -r -p "Percorso file di health (default: /run/newt/healthy): " HEALTH_FILE_INPUT || true
  HEALTH_FILE="${HEALTH_FILE_INPUT:-/run/newt/healthy}"

  # Validazioni minime
  if [[ -z "$PANGOLIN_ENDPOINT" || -z "$NEWT_ID" || -z "$NEWT_SECRET" ]]; then
    echo "Endpoint/ID/Secret non possono essere vuoti." >&2
    exit 1
  fi
  if [[ ! "$PANGOLIN_ENDPOINT" =~ ^https?:// ]]; then
    echo "Endpoint deve iniziare con http:// o https://." >&2
    exit 1
  fi
}

create_system_user() {
  if ! id -u newt >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d /var/lib/newt newt
  fi
  mkdir -p /var/lib/newt /etc/newt /var/log/newt
  chown -R newt:newt /var/lib/newt /var/log/newt
  chmod 0750 /var/lib/newt /var/log/newt
}

write_config() {
  # Conserviamo credenziali in /etc/newt/config.json e le passiamo con CONFIG_FILE
  cat >/etc/newt/config.json <<JSON
{
  "id": "$(printf '%s' "$NEWT_ID")",
  "secret": "$(printf '%s' "$NEWT_SECRET")",
  "endpoint": "$(printf '%s' "$PANGOLIN_ENDPOINT")",
  "tlsClientCert": ""
}
JSON
  chmod 0600 /etc/newt/config.json
  chown root:root /etc/newt/config.json

  # Environment file per flag opzionali
  cat >/etc/newt/newt.env <<ENV
CONFIG_FILE=/etc/newt/config.json
HEALTH_FILE=${HEALTH_FILE}
# Log level (DEBUG, INFO, WARN, ERROR, FATAL)
LOG_LEVEL=INFO
# Abilita accettazione client se richiesto
ACCEPT_CLIENTS=${ACCEPT_CLIENTS}
# Modalità native (solo Linux; richiede CAP_NET_ADMIN)
USE_NATIVE_INTERFACE=${USE_NATIVE}
# Nome interfaccia WG in native mode (opzionale)
INTERFACE=newt
ENV
  chmod 0640 /etc/newt/newt.env
}

write_service_units() {
  local run_user="newt"
  local caps=""
  local supp_groups=""

  if [[ "${USE_NATIVE}" == "true" ]]; then
    # In native mode servono privilegi (creazione interfaccia WG)
    run_user="root"
    caps="CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW"
  fi

  # Servizio principale
  cat >/etc/systemd/system/newt.service <<UNIT
[Unit]
Description=Newt (Pangolin) client
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
User=${run_user}
Group=${run_user}
EnvironmentFile=/etc/newt/newt.env
# Crea /run/newt/ per HEALTH_FILE
RuntimeDirectory=newt
RuntimeDirectoryMode=0755
# Esegue il binario senza credenziali in argomenti (le prende da CONFIG_FILE)
ExecStart=$(command -v newt)
Restart=always
RestartSec=3
# Limiti e logging
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
${caps}
# Ferma pulito
KillSignal=SIGTERM
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
UNIT

  # Healthcheck script: se HEALTH_FILE manca o è vecchio, riavvia newt
  cat >/usr/local/sbin/newt-healthcheck.sh <<'HCSH'
#!/usr/bin/env bash
set -euo pipefail
HEALTH_FILE="${HEALTH_FILE:-/run/newt/healthy}"
STALE_AFTER="${STALE_AFTER:-45}"

if [[ ! -e "$HEALTH_FILE" ]]; then
  systemctl restart newt.service
  exit 1
fi

now=$(date +%s)
# stat -c %Y (GNU); fallback per BSD/macOS non serve qui
mtime=$(stat -c %Y "$HEALTH_FILE")
age=$(( now - mtime ))
if (( age > STALE_AFTER )); then
  systemctl restart newt.service
  exit 2
fi
exit 0
HCSH
  chmod 0755 /usr/local/sbin/newt-healthcheck.sh

  # Service oneshot del healthcheck
  cat >/etc/systemd/system/newt-healthcheck.service <<HCS
[Unit]
Description=Healthcheck per Newt (riavvia se unhealthy)
After=newt.service

[Service]
Type=oneshot
EnvironmentFile=/etc/newt/newt.env
ExecStart=/usr/local/sbin/newt-healthcheck.sh
HCS

  # Timer ogni 30s
  cat >/etc/systemd/system/newt-healthcheck.timer <<HCT
[Unit]
Description=Esegui healthcheck Newt ogni 30 secondi

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=newt-healthcheck.service

[Install]
WantedBy=timers.target
HCT

  systemctl daemon-reload
  systemctl enable --now newt.service
  systemctl enable --now newt-healthcheck.timer
}

summary() {
  echo
  echo "== Installazione completata =="
  echo "Endpoint:        $PANGOLIN_ENDPOINT"
  echo "Accept clients:  $ACCEPT_CLIENTS"
  echo "Native mode:     $USE_NATIVE"
  echo "Health file:     $HEALTH_FILE"
  echo
  echo "Comandi utili:"
  echo "  systemctl status newt.service"
  echo "  journalctl -u newt.service -f"
  echo "  systemctl list-timers | grep newt-healthcheck"
  echo "  journalctl -u newt-healthcheck.service -f"
  echo
  echo "File:"
  echo "  /etc/newt/config.json     (credenziali)"
  echo "  /etc/newt/newt.env        (opzioni e HEALTH_FILE)"
  echo "  /usr/local/sbin/newt-healthcheck.sh"
  echo "  /etc/systemd/system/newt.service"
  echo "  /etc/systemd/system/newt-healthcheck.service"
  echo "  /etc/systemd/system/newt-healthcheck.timer"
}

main() {
  assert_root
  need_cmd curl
  need_cmd stat
  need_cmd systemctl

  install_newt_if_missing
  prompt_inputs
  create_system_user
  write_config
  write_service_units
  summary
}

main "$@"
