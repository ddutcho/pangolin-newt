#!/usr/bin/env bash
# remove-newt.sh - Rimuove installazioni del CLI "newt" (fosrl/newt) con selezione interattiva.
# Uso:
#   bash remove-newt.sh            # modalità interattiva (scegli cosa rimuovere)
#   bash remove-newt.sh --all      # rimuovi tutte le copie senza chiedere
#   bash remove-newt.sh --dry-run  # mostra cosa farebbe (mantiene interattivo)
#   bash remove-newt.sh --all --dry-run
#
# Note:
# - Identifica il "vero" newt cercando l'output "Newt version ..." a --version/version.
# - Check finale: verifica residui in PATH, percorsi comuni e scansione /opt (max depth 3).

set -euo pipefail

# --- Stampa istruzioni/indicazioni d'uso in terminale ---
cat <<'__USAGE__' >&2
remove-newt.sh - Rimuove installazioni del CLI "newt" (fosrl/newt) con selezione interattiva.
Uso:
  bash remove-newt.sh            # modalità interattiva (scegli cosa rimuovere)
  bash remove-newt.sh --all      # rimuovi tutte le copie senza chiedere
  bash remove-newt.sh --dry-run  # mostra cosa farebbe (mantiene interattivo)
  bash remove-newt.sh --all --dry-run

Note:
- Identifica il "vero" newt cercando l'output "Newt version ..." a --version/version.
- Check finale: verifica residui in PATH, percorsi comuni e scansione /opt (max depth 3).
__USAGE__

DRY_RUN=0
AUTO_ALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --all) AUTO_ALL=1 ;;
    *) printf '[ERR ] Argomento non riconosciuto: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR ] %s\n' "$*" >&2; }

is_newt_cli() {
  local bin="$1" out
  [[ -n "$bin" && -x "$bin" ]] || return 1
  if out="$("$bin" --version 2>&1)" || true; then
    if grep -qiE '(^|[^[:alnum:]])newt[[:space:]]+version[[:space:]]+[0-9]+' <<<"$out"; then
      return 0
    fi
  fi
  if out="$("$bin" version 2>&1)" || true; then
    if grep -qiE '(^|[^[:alnum:]])newt[[:space:]]+version[[:space:]]+[0-9]+' <<<"$out"; then
      return 0
    fi
  fi
  if command -v strings >/dev/null 2>&1; then
    if strings "$bin" 2>/dev/null | grep -qi 'Newt version'; then
      return 0
    fi
  fi
  return 1
}

remove_file() {
  local f="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: rimuoverei $f"
    return 0
  fi
  if rm -f -- "$f" 2>/dev/null; then
    log "Rimosso $f"; return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo rm -f -- "$f"; then
    log "Rimosso (con sudo) $f"; return 0
  fi
  err "Impossibile rimuovere $f (permessi?). Esegui lo script con sudo."
  return 1
}

scan_candidates() {
  declare -a c=()

  if command -v -a newt >/dev/null 2>&1; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && c+=("$p")
    done < <(command -v -a newt 2>/dev/null | awk '!seen[$0]++')
  fi

  declare -a COMMON=(
    "$HOME/.local/bin/newt"
    "/usr/local/bin/newt"
    "/usr/bin/newt"
    "/bin/newt"
    "/usr/local/sbin/newt"
    "/usr/sbin/newt"
    "/sbin/newt"
    "/snap/bin/newt"
  )
  for p in "${COMMON[@]}"; do
    [[ -e "$p" && -x "$p" ]] && c+=("$p")
  done

  if [[ -d /opt ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] && c+=("$p")
    done < <(find /opt -maxdepth 3 -type f -name 'newt' -perm -001 2>/dev/null || true)
  fi

  # Dedup/validi
  declare -A seen=()
  declare -a out=()
  for x in "${c[@]}"; do
    if [[ -n "$x" && -e "$x" && -x "$x" && -z "${seen[$x]:-}" ]]; then
      seen[$x]=1
      out+=("$x")
    fi
  done

  # Stampa SOLO se ci sono elementi
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
}

parse_selection() {
  # Legge una riga da STDIN e produce indici selezionati (1..max)
  local max="$1" tok a b i
  declare -A sel=()

  IFS= read -r line || true
  if [[ -z "${line// /}" ]]; then
    for ((i=1; i<=max; i++)); do echo "$i"; done
    return 0
  fi
  if [[ "$line" == "0" ]]; then
    return 10
  fi

  line="${line//,/ }"
  for tok in $line; do
    if [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then
      a="${tok%-*}"; b="${tok#*-}"
      if (( a> b )); then i="$a"; a="$b"; b="$i"; fi
      for ((i=a; i<=b; i++)); do
        (( i>=1 && i<=max )) && sel[$i]=1
      done
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      (( tok>=1 && tok<=max )) && sel[$tok]=1
    else
      warn "Token ignorato: $tok"
    fi
  done

  ((${#sel[@]})) || { err "Nessuna selezione valida."; return 11; }
  for i in "${!sel[@]}"; do echo "$i"; done | sort -n
}

# --- MAIN ---
mapfile -t candidates < <(scan_candidates || true)

if [[ ${#candidates[@]} -eq 0 ]]; then
  log "Nessun binario 'newt' trovato sul sistema."
  exit 0
fi

log "Candidati trovati:"
for idx in "${!candidates[@]}"; do
  printf ' %2d) %s\n' "$((idx+1))" "${candidates[$idx]}" >&2
done

declare -a valid=()
declare -a invalid=()
for p in "${candidates[@]}"; do
  if is_newt_cli "$p"; then
    valid+=("$p")
  else
    # Avvisa solo se abbiamo un path reale
    [[ -n "$p" ]] && invalid+=("$p")
  fi
done
for x in "${invalid[@]:-}"; do
  [[ -n "$x" ]] && warn "Ignoro $x: non sembra il CLI 'Newt version ...'."
done

if [[ ${#valid[@]} -eq 0 ]]; then
  warn "Nessun binario compatibile con 'Newt version ...' da rimuovere."
  exit 0
fi

declare -a to_remove=()
if [[ $AUTO_ALL -eq 1 ]]; then
  to_remove=("${valid[@]}")
else
  # >>> FIX PRINCIPALE: leggi davvero da tastiera, NON usare pipe vuota
  printf '\nSeleziona cosa rimuovere (numeri). Esempi: "1 3", "1-3", "1,4-5". INVIO = tutti. 0 = annulla.\n> ' >&2
  # Leggi l'input dall'utente da /dev/tty (anche se lo script è parte di una pipe)
  user_line=""
  if IFS= read -r user_line </dev/tty; then
    :
  else
    # Se non c'è TTY (esecuzione non-interattiva), default = tutti
    user_line=""
  fi
  mapfile -t sel_idx < <(printf '%s\n' "$user_line" | parse_selection "${#valid[@]}" || true)

  ps_rc=$?
  if [[ $ps_rc -eq 10 ]]; then
    warn "Operazione annullata dall’utente."
    exit 0
  elif [[ $ps_rc -eq 11 ]]; then
    err "Selezione non valida."
    exit 1
  fi

  for i in "${sel_idx[@]}"; do
    to_remove+=("${valid[$((i-1))]}")
  done
fi

log "Rimuovo i seguenti binari di newt:"
for t in "${to_remove[@]}"; do
  printf ' - %s\n' "$t" >&2
done

rc_all=0
for t in "${to_remove[@]}"; do
  if ! remove_file "$t"; then rc_all=1; fi
done

verify() {
  log "Verifica finale: controllo residui di 'newt'..."
  local residual_path="" residual_common="" residual_opt=""
  if command -v -a newt >/dev/null 2>&1; then
    residual_path="$(command -v -a newt 2>/dev/null | awk '!seen[$0]++' || true)"
  fi
  declare -a COMMON=(
    "$HOME/.local/bin/newt"
    "/usr/local/bin/newt"
    "/usr/bin/newt"
    "/bin/newt"
    "/usr/local/sbin/newt"
    "/usr/sbin/newt"
    "/sbin/newt"
    "/snap/bin/newt"
  )
  for p in "${COMMON[@]}"; do
    [[ -e "$p" && -x "$p" ]] && residual_common+="$p"$'\n'
  done
  if [[ -d /opt ]]; then
    residual_opt="$(find /opt -maxdepth 3 -type f -name 'newt' -perm -001 2>/dev/null || true)"
  fi

  if [[ -z "${residual_path// /}" && -z "${residual_common// /}" && -z "${residual_opt// /}" ]]; then
    log "'newt' non è più presente (PATH, comuni, /opt)."
    return 0
  fi

  warn "Trovati possibili residui:"
  [[ -n "${residual_path// /}"  ]] && { printf '[PATH]\n%s\n' "$residual_path" >&2; }
  [[ -n "${residual_common// /}" ]] && { printf '[COMUNI]\n%s\n' "$residual_common" >&2; }
  [[ -n "${residual_opt// /}"   ]] && { printf '[/opt]\n%s\n' "$residual_opt" >&2; }
  return 1
}

verify || true
exit $rc_all
