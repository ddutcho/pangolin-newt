# Pangolin Newt Supervisor (PNS)

Open-source installer per il client **Pangolin `newt`** su Linux con:
- **servizio systemd** sempre attivo (restart automatico, hardening)
- **wrapper** con retry/backoff e **logging** dedicato
- **health-check timer** (rialza il servizio se cade)
- **installazione interattiva** (chiede `NEWT_ID`, `NEWT_SECRET`, `NEWT_ENDPOINT`)
- flag integrati `--native --accept-clients`
- modalità **non-interattiva** via variabili d’ambiente e **uninstall** pulita

---

## Method 1 – Linux (curl|bash) ❤️

Apri il terminale su Debian/Ubuntu (con `systemd`) e incolla:

```bash
bash -c 'read -p "GitHub owner/repo (tuo): " REPO; curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/scripts/pangolin-bootstrap.sh" | bash'
