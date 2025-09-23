# Pangolin Newt Supervisor (PNS)

Installer per il client **Pangolin `newt`** su Linux con:
- **servizio systemd** sempre attivo (restart automatico + hardening)
- **wrapper** con retry/backoff e **logging**
- **health-check timer** (rialza il servizio se cade)
- **installazione interattiva** (chiede `NEWT_ID`, `NEWT_SECRET`, `NEWT_ENDPOINT`)
- flag integrati `--native --accept-clients`
- supporto **non-interattivo** e **disinstallazione** pulita

> Requisiti: Debian/Ubuntu (o derivate) con `systemd`, permessi `root` (o `sudo`), connettività Internet.

---

## Installazione (minimale)

### Metodo A — Ho già i file localmente
Esegui dalla cartella dove si trova `pangolin-newt-setup.sh`:
```bash
bash pangolin-newt-setup.sh --install
