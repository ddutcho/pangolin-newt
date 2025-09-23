
# Pangolin Newt Supervisor (PNS)

Installer & supervisor per il client **Pangolin `newt`** su Linux:
- **Sceglie la versione** da **release ufficiali** `fosrl/newt`
- Installa `newt` binario (no container), crea **servizio systemd** con hardening
- Wrapper con **retry/backoff** + **logging** dedicato
- **Health-check timer** (riavvia se cade)
- **Interattivo** (chiede `NEWT_ID`, `NEWT_SECRET`, `NEWT_ENDPOINT`)
- Supporta `--native --accept-clients` (Linux-only)  
  *(“Native mode” richiede Linux; con `--accept-clients` abiliti la modalità server)*

---

## Method 1 – Linux (curl|bash) ❤️

Apri il terminale e incolla:

```bash
bash -c 'read -p "GitHub owner/repo (tuo): " REPO; curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/scripts/pangolin-bootstrap.sh" | bash'
