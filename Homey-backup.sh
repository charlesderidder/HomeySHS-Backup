#!/usr/bin/env bash
# =============================================================================
#  Homey-backup.sh  (v2)
#  Backup, verificatie en restore van Homey Self-Hosted Server (/root/.homey-shs)
#  in een Proxmox LXC-container. Draai dit script als root op de Proxmox HOST.
#
#  DRAAIEN VANAF GITHUB (zonder het bestand eerst handmatig te downloaden):
#    bash <(curl -fsSL https://raw.githubusercontent.com/charlesderidder/HomeySHS-Backup/refs/heads/main/Homey-backup.sh) backup
#
#  Of eerst downloaden en daarna draaien (aanbevolen, dan kun je het eerst lezen):
#    curl -fsSL https://raw.githubusercontent.com/charlesderidder/HomeySHS-Backup/refs/heads/main/Homey-backup.sh -o Homey-backup.sh
#    chmod +x Homey-backup.sh
#    ./Homey-backup.sh backup
#
#  Commando's:
#    ./Homey-backup.sh backup              # backup maken
#    ./Homey-backup.sh list                # toon beschikbare backups
#    ./Homey-backup.sh verify <bestand>    # controleer een backup (zonder herstel)
#    ./Homey-backup.sh restore <bestand>   # herstel een backup
#    ./Homey-backup.sh help
#
#  Let op: de container wordt tijdens backup en restore gestopt. Plan dit dus
#  op een moment dat Homey niet nodig is.
# =============================================================================

# #############################################################################
#  >>> PAS DEZE VARIABELEN AAN NAAR JOUW SITUATIE <<<
# #############################################################################

CTID="${CTID:-100}"                                    # ID van de Homey-container (pct list)
SRC_DIR="${SRC_DIR:-/root/.homey-shs}"                 # map met Homey-data binnen de container
BACKUP_DIR="${BACKUP_DIR:-/var/lib/vz/dump/homey}"     # waar backups op de host worden opgeslagen
KEEP="${KEEP:-14}"                                     # aantal backups bewaren (0 = alles bewaren)
MOUNT_CHECK="${MOUNT_CHECK:-}"                         # bv. /mnt/nas; leeg = niet controleren
ROOTFS_BASE="${ROOTFS_BASE:-/var/lib/lxc}"             # waar pct mount de container koppelt
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"            # seconden wachten op nette afsluiting
ASSUME_YES="${ASSUME_YES:-0}"                          # 1 = restore zonder bevestiging (voor cron)
LOG_FILE="${LOG_FILE:-/var/log/homey-backup.log}"      # logbestand op de host
LOCK_FILE="${LOCK_FILE:-/run/homey-backup.lock}"       # voorkomt dat twee runs tegelijk draaien

# #############################################################################
#  Vanaf hier niets meer aanpassen, tenzij je weet wat je doet
# #############################################################################

set -Eeuo pipefail


ARCHIVE_PREFIX="homey-shs-ct${CTID}"
DATE="$(date +%Y%m%d-%H%M%S)"
ROOTFS="$ROOTFS_BASE/$CTID/rootfs"
INFO_DIR="$BACKUP_DIR/info"

# Status voor opruimen bij fouten
WANT_RUNNING=0      # 1 = container moet na afloop draaien
CT_MOUNTED=0        # 1 = rootfs is gemount
TMP_OUT=""          # tijdelijk archief (wordt bij fout verwijderd)
RESTORE_OLD=""      # pad van de oude data bij restore (voor het hint-bericht)

# ---------- logging ----------------------------------------------------------
log()  { printf '%s [INFO]  %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '%s [FOUT]  %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "=== Start: $*  (CT $CTID) ==="
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Er draait al een backup of restore (lock: $LOCK_FILE)"
}

# ---------- opruimen (altijd, ook bij fouten) --------------------------------
cleanup() {
  local rc=$?
  set +e
  [[ -n "$TMP_OUT" && -f "$TMP_OUT" ]] && rm -f -- "$TMP_OUT"

  if [[ "$CT_MOUNTED" == 1 ]]; then
    if pct unmount "$CTID" >/dev/null 2>&1; then
      CT_MOUNTED=0
    else
      warn "Kon container $CTID niet unmounten. Doe handmatig: pct unmount $CTID"
    fi
  fi

  if [[ "$WANT_RUNNING" == 1 && "$(ct_state)" != "running" ]]; then
    log "Container $CTID weer starten..."
    pct start "$CTID" >/dev/null 2>&1 || warn "Container kon niet starten. Doe: pct start $CTID"
  fi

  if [[ "$rc" -ne 0 ]]; then
    warn "Afgebroken met foutcode $rc"
    [[ -n "$RESTORE_OLD" ]] && warn "Oude data staat nog in: $RESTORE_OLD"
  fi
  exit "$rc"
}
trap cleanup EXIT

# ---------- hulpfuncties -----------------------------------------------------
ct_state() {
  pct status "$CTID" 2>/dev/null | awk '{print $2}'
}

preflight() {
  command -v pct >/dev/null 2>&1 \
    || die "'pct' niet gevonden. Draai dit script op de Proxmox host."
  pct status "$CTID" >/dev/null 2>&1 \
    || die "Container $CTID bestaat niet op deze host."
  if [[ -n "$MOUNT_CHECK" ]]; then
    mountpoint -q "$MOUNT_CHECK" || die "$MOUNT_CHECK is niet gemount. Backup afgebroken."
  fi
  mkdir -p "$BACKUP_DIR" "$INFO_DIR"
  [[ -w "$BACKUP_DIR" ]] || die "Geen schrijfrechten op $BACKUP_DIR"
}

stop_ct() {
  if [[ "$(ct_state)" == "running" ]]; then
    WANT_RUNNING=1
    log "Container $CTID netjes afsluiten (timeout ${SHUTDOWN_TIMEOUT}s)..."
    pct shutdown "$CTID" --timeout "$SHUTDOWN_TIMEOUT"
  fi
}

mount_ct() {
  [[ "$(ct_state)" == "running" ]] && die "Container $CTID draait nog, kan niet mounten."
  log "Container $CTID mounten..."
  pct mount "$CTID" >/dev/null
  CT_MOUNTED=1
  [[ -d "$ROOTFS" ]] || die "Rootfs niet gevonden: $ROOTFS"
}

unmount_ct() {
  pct unmount "$CTID" >/dev/null
  CT_MOUNTED=0
}

start_ct() {
  log "Container $CTID starten..."
  pct start "$CTID" >/dev/null
}

check_space() {
  local need avail
  need="$(du -sm "$1" | awk '{print $1}')"
  avail="$(df -Pm "$BACKUP_DIR" | awk 'NR==2{print $4}')"
  (( avail > need + 200 )) \
    || die "Te weinig vrije ruimte: ongeveer ${need} MB nodig, ${avail} MB beschikbaar."
}

# Verwijder oudere bestanden, behoud de nieuwste $KEEP
prune() {
  local dir="$1" pattern="$2"
  (( KEEP > 0 )) || return 0
  find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' \
    | sort -rn \
    | tail -n +"$((KEEP + 1))" \
    | cut -d' ' -f2- \
    | while IFS= read -r f; do
        rm -f -- "$f" "$f.sha256"
        log "Oude bestand verwijderd: $(basename "$f")"
      done
  return 0
}

verify_archive() {
  local f="$1" list
  [[ -n "$f" && -f "$f" ]] || die "Geef een bestaand backupbestand op."

  if [[ -f "$f.sha256" ]]; then
    (cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" >/dev/null) \
      || die "Checksum klopt niet. Het bestand is beschadigd of gewijzigd."
    log "Checksum OK"
  else
    warn "Geen .sha256-bestand, checksum overgeslagen."
  fi

  list="$(mktemp)"
  if ! tar -tzf "$f" > "$list"; then
    rm -f "$list"
    die "Geen geldig tar.gz-archief: $f"
  fi
  if ! grep -q "^$(basename "$SRC_DIR")/" "$list"; then
    rm -f "$list"
    die "Dit lijkt geen Homey-backup (map $(basename "$SRC_DIR")/ ontbreekt)."
  fi
  rm -f "$list"
  log "Archief OK: $(basename "$f")"
}

confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  local answer
  printf 'Doorgaan? Container %s wordt gestopt. [j/N] ' "$CTID"
  read -r answer || answer=""
  [[ "$answer" =~ ^[jJyY]$ ]] || { log "Afgebroken door gebruiker."; exit 0; }
}

# ---------- backup -----------------------------------------------------------
cmd_backup() {
  preflight
  stop_ct
  mount_ct

  [[ -d "$ROOTFS$SRC_DIR" ]] || die "Map $SRC_DIR niet gevonden in container $CTID."
  check_space "$ROOTFS$SRC_DIR"

  local out="$BACKUP_DIR/${ARCHIVE_PREFIX}-${DATE}.tar.gz"
  TMP_OUT="$out.partial"

  log "Archief maken van $SRC_DIR..."
  tar --numeric-owner -czf "$TMP_OUT" \
      -C "$ROOTFS$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")"

  # Container-config bewaren, nodig om de CT later opnieuw op te bouwen
  pct config "$CTID" > "$INFO_DIR/ct${CTID}-config-${DATE}.conf"

  # Downtime eindigt hier: eerst unmounten, dan starten
  unmount_ct
  if [[ "$WANT_RUNNING" == 1 ]]; then
    start_ct
  fi

  mv -- "$TMP_OUT" "$out"
  TMP_OUT=""
  (cd "$BACKUP_DIR" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")

  log "Archief controleren..."
  tar -tzf "$out" >/dev/null || die "Archief is ongeldig: $out"

  # Systeeminformatie erbij (handig bij een volledig herstel van de host)
  {
    echo "=== DATUM ==="; date
    echo; echo "=== PROXMOX ==="; pveversion 2>/dev/null || true
    echo; echo "=== CONTAINERS ==="; pct list 2>/dev/null || true
    echo; echo "=== OPSLAG ==="; df -h "$BACKUP_DIR" || true
  } > "$INFO_DIR/ct${CTID}-system-${DATE}.txt"

  prune "$BACKUP_DIR" "${ARCHIVE_PREFIX}-*.tar.gz"
  prune "$INFO_DIR" "ct${CTID}-config-*.conf"
  prune "$INFO_DIR" "ct${CTID}-system-*.txt"

  log "Backup klaar: $out"
  log "Grootte: $(du -h "$out" | cut -f1)"
  echo
  log "Downloaden naar je pc:"
  echo "    scp root@<proxmox-ip>:\"$out\" ."
  echo "    (of WinSCP / FileZilla via SFTP)"
}

# ---------- restore ----------------------------------------------------------
cmd_restore() {
  local file="${1:-}"
  [[ -n "$file" && -f "$file" ]] || die "Geef een bestaand backupbestand op."
  preflight
  verify_archive "$file"
  confirm

  WANT_RUNNING=1          # na herstel moet de container weer draaien
  stop_ct
  mount_ct

  local parent="$ROOTFS$(dirname "$SRC_DIR")"
  if [[ -e "$ROOTFS$SRC_DIR" ]]; then
    RESTORE_OLD="$ROOTFS$SRC_DIR.voor-restore-${DATE}"
    mv -- "$ROOTFS$SRC_DIR" "$RESTORE_OLD"
    log "Bestaande data veiliggesteld: $SRC_DIR.voor-restore-${DATE}"
  fi

  mkdir -p "$parent"
  log "Backup uitpakken..."
  tar --numeric-owner -xzf "$file" -C "$parent"

  unmount_ct
  start_ct
  RESTORE_OLD=""

  log "Restore klaar. Controleer of Homey Self-Hosted Server weer werkt."
}

# ---------- list -------------------------------------------------------------
cmd_list() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    warn "Nog geen backupmap: $BACKUP_DIR"
    return 0
  fi
  log "Backups in $BACKUP_DIR:"
  ls -lh "$BACKUP_DIR"/${ARCHIVE_PREFIX}-*.tar.gz 2>/dev/null || warn "Geen backups gevonden."
  return 0
}

# ---------- menu -------------------------------------------------------------
interactive_menu() {
  while true; do
    cat <<'EOF'

========================================
 Homey Backup Menu
========================================
  1) Backup maken
  2) Backups tonen
  3) Backup verifiëren
  4) Restore uitvoeren
  5) Help tonen
  0) Afsluiten
========================================
EOF
    printf 'Maak een keuze [0-5]: '
    read -r choice || choice=""

    case "$choice" in
      1)
        setup_logging "backup"
        acquire_lock
        cmd_backup
        return 0
        ;;
      2)
        cmd_list
        ;;
      3)
        printf 'Pad naar backupbestand: '
        read -r file || file=""
        [[ -n "$file" ]] || { warn "Geen bestand opgegeven."; continue; }
        verify_archive "$file"
        ;;
      4)
        printf 'Pad naar backupbestand: '
        read -r file || file=""
        [[ -n "$file" ]] || { warn "Geen bestand opgegeven."; continue; }
        setup_logging "restore $file"
        acquire_lock
        cmd_restore "$file"
        return 0
        ;;
      5)
        usage
        ;;
      0|q|Q|quit|exit)
        log "Afgesloten."
        return 0
        ;;
      *)
        warn "Ongeldige keuze: $choice"
        ;;
    esac
  done
}

# ---------- main -------------------------------------------------------------
usage() {
  cat <<EOF
Gebruik: $0 <commando> [bestand]

  backup              Maak een backup van ${SRC_DIR} in container ${CTID}
  list                Toon beschikbare backups
  verify <bestand>    Controleer een backup zonder te herstellen
  restore <bestand>   Herstel een backup (container wordt gestopt en herstart)
  help                Toon deze hulp
  menu                Start het interactieve menu

Als je geen commando meegeeft, start het interactieve menu.

Omgevingsvariabelen: CTID, SRC_DIR, BACKUP_DIR, KEEP, MOUNT_CHECK,
                     LOG_FILE, SHUTDOWN_TIMEOUT, ASSUME_YES
EOF
}

main() {
  local cmd="${1:-menu}"
  shift || true
  case "$cmd" in
    backup)  setup_logging "backup"; acquire_lock; cmd_backup ;;
    restore) setup_logging "restore $*"; acquire_lock; cmd_restore "${1:-}" ;;
    verify)  verify_archive "${1:-}" ;;
    list)    cmd_list ;;
    menu|"")
      interactive_menu
      ;;
    help|-h|--help) usage ;;
    *) die "Onbekend commando: $cmd (gebruik: backup | list | verify | restore | help | menu)" ;;
  esac
}

main "$@"
