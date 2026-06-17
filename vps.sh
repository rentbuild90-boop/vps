#!/usr/bin/env bash
#
# gearrent_backup_toolkit.sh
# Discovery + Backup + Cleanup-report toolkit for the gearrent.cloud VPS stack
# (nginx, certbot/SSL, docker, n8n, ollama, website files under /var/www)
#
# USAGE (run as root, directly on the VPS — e.g. via your provider's web console):
#   ./gearrent_backup_toolkit.sh discover         # scan & report only, copies nothing
#   ./gearrent_backup_toolkit.sh backup           # scan, copy everything found, zip it
#   ./gearrent_backup_toolkit.sh cleanup-report   # list disk/cleanup candidates (no deletion)
#
# Nothing is ever deleted by this script. cleanup-report only lists candidates for YOU to review.

set -uo pipefail

DOMAIN="gearrent.cloud"
TS="$(date +%Y%m%d_%H%M%S)"
BASE="/root/gearrent_backup_${TS}"
REPORT="${BASE}/discovery_report.txt"
ZIPFILE="/root/gearrent_cloud_backup_${TS}.zip"
MODE="${1:-discover}"

mkdir -p "$BASE"
: > "$REPORT"

log() { echo "$@" | tee -a "$REPORT" ; }

section() {
  log ""
  log "=================================================="
  log "  $1"
  log "=================================================="
}

# ---------- DISCOVERY ----------

discover() {
  section "Discovery report for $DOMAIN — $(date)"

  section "1. Website directory"
  if [ -d "/var/www/$DOMAIN" ]; then
    du -sh "/var/www/$DOMAIN" 2>/dev/null | tee -a "$REPORT"
    find "/var/www/$DOMAIN" -maxdepth 2 2>/dev/null | tee -a "$REPORT"
  else
    log "NOT FOUND: /var/www/$DOMAIN"
  fi

  section "2. Nginx"
  command -v nginx >/dev/null 2>&1 && nginx -v 2>&1 | tee -a "$REPORT"
  log "-- config files referencing $DOMAIN --"
  grep -rl "$DOMAIN" /etc/nginx/ 2>/dev/null | tee -a "$REPORT"
  log "-- sites-enabled --"
  ls -la /etc/nginx/sites-enabled/ 2>/dev/null | tee -a "$REPORT"

  section "3. SSL certificates (Certbot)"
  if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    ls -la "/etc/letsencrypt/live/$DOMAIN" | tee -a "$REPORT"
  else
    log "NOT FOUND: /etc/letsencrypt/live/$DOMAIN"
  fi
  command -v certbot >/dev/null 2>&1 && certbot certificates 2>/dev/null | tee -a "$REPORT"

  section "4. Docker"
  if command -v docker >/dev/null 2>&1; then
    docker --version | tee -a "$REPORT"
    log "-- containers --"
    docker ps -a | tee -a "$REPORT"
    log "-- volumes --"
    docker volume ls | tee -a "$REPORT"
    log "-- images --"
    docker images | tee -a "$REPORT"
    log "-- compose files found on disk --"
    find / -xdev -iname "docker-compose*.y*ml" 2>/dev/null | grep -v -E "^/(proc|sys)" | tee -a "$REPORT"
  else
    log "docker not installed"
  fi

  section "5. n8n"
  log "-- files/dirs matching *n8n* --"
  find / -xdev -iname "*n8n*" -not -path "/proc/*" -not -path "/sys/*" 2>/dev/null | tee -a "$REPORT"

  section "6. Ollama"
  command -v ollama >/dev/null 2>&1 && ollama --version 2>&1 | tee -a "$REPORT"
  log "-- model storage --"
  find / -xdev -ipath "*ollama*" -not -path "/proc/*" -not -path "/sys/*" 2>/dev/null | tee -a "$REPORT"

  section "7. Databases (sqlite / postgres / mysql)"
  log "-- sqlite files --"
  find / -xdev -iname "*.sqlite" -not -path "/proc/*" 2>/dev/null | tee -a "$REPORT"
  log "-- postgres --"
  command -v psql >/dev/null 2>&1 && psql --version | tee -a "$REPORT"
  [ -d /etc/postgresql ] && ls -la /etc/postgresql | tee -a "$REPORT"
  log "-- mysql/mariadb --"
  command -v mysql >/dev/null 2>&1 && mysql --version | tee -a "$REPORT"
  [ -d /etc/mysql ] && ls -la /etc/mysql | tee -a "$REPORT"

  section "8. Logs"
  log "-- nginx logs --"
  ls -la /var/log/nginx/ 2>/dev/null | tee -a "$REPORT"
  log "-- docker container logs (sizes) --"
  if command -v docker >/dev/null 2>&1; then
    for c in $(docker ps -aq 2>/dev/null); do
      f=$(docker inspect --format='{{.LogPath}}' "$c" 2>/dev/null)
      [ -f "$f" ] && du -sh "$f" 2>/dev/null | tee -a "$REPORT"
    done
  fi

  section "9. Crontabs & scheduled tasks"
  crontab -l 2>/dev/null | tee -a "$REPORT"
  ls /etc/cron.d/ 2>/dev/null | tee -a "$REPORT"

  section "10. Custom systemd services"
  find /etc/systemd/system -iname "*n8n*" -o -iname "*ollama*" -o -iname "*gearrent*" 2>/dev/null | tee -a "$REPORT"

  section "11. Firewall / SSH status (since SSH is currently refusing connections)"
  log "-- sshd status --"
  systemctl status ssh 2>/dev/null | tee -a "$REPORT" || systemctl status sshd 2>/dev/null | tee -a "$REPORT"
  log "-- ufw status --"
  command -v ufw >/dev/null 2>&1 && ufw status verbose | tee -a "$REPORT"
  log "-- iptables rules mentioning 22/ssh --"
  iptables -L -n 2>/dev/null | grep -E "22|ssh" | tee -a "$REPORT"
  log "-- fail2ban sshd jail --"
  command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd 2>/dev/null | tee -a "$REPORT"

  echo "Discovery report saved to: $REPORT"
}

# ---------- BACKUP ----------

backup() {
  discover

  section "Copying files into backup staging area: $BASE"

  copy_if_exists() {
    src="$1"; dest="$2"
    if [ -e "$src" ]; then
      mkdir -p "$(dirname "$dest")"
      cp -a "$src" "$dest" 2>/dev/null && log "Copied: $src -> $dest"
    fi
  }

  copy_if_exists "/var/www/$DOMAIN" "$BASE/var_www/$DOMAIN"
  copy_if_exists "/etc/nginx/sites-available" "$BASE/nginx/sites-available"
  copy_if_exists "/etc/nginx/sites-enabled" "$BASE/nginx/sites-enabled"
  copy_if_exists "/etc/nginx/nginx.conf" "$BASE/nginx/nginx.conf"
  copy_if_exists "/etc/nginx/conf.d" "$BASE/nginx/conf.d"
  copy_if_exists "/var/log/nginx" "$BASE/logs/nginx"
  copy_if_exists "/etc/letsencrypt/live/$DOMAIN" "$BASE/letsencrypt/live/$DOMAIN"
  copy_if_exists "/etc/letsencrypt/archive/$DOMAIN" "$BASE/letsencrypt/archive/$DOMAIN"
  copy_if_exists "/etc/letsencrypt/renewal/${DOMAIN}.conf" "$BASE/letsencrypt/renewal/${DOMAIN}.conf"
  copy_if_exists "/root/.n8n" "$BASE/n8n_data"
  copy_if_exists "/etc/crontab" "$BASE/crontab"
  copy_if_exists "/etc/cron.d" "$BASE/cron.d"

  find / -xdev -iname "docker-compose*.y*ml" -not -path "/proc/*" -not -path "/sys/*" 2>/dev/null | while read -r f; do
    copy_if_exists "$f" "$BASE/docker-compose/$(basename "$f")"
  done

  if command -v docker >/dev/null 2>&1; then
    for v in $(docker volume ls -q 2>/dev/null | grep -i -E "n8n|ollama|postgres|mysql|gearrent"); do
      mp=$(docker volume inspect --format '{{.Mountpoint}}' "$v" 2>/dev/null)
      copy_if_exists "$mp" "$BASE/docker_volumes/$v"
    done
  fi

  section "Creating zip archive"
  if ! command -v zip >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y zip >/dev/null 2>&1
  fi

  if command -v zip >/dev/null 2>&1; then
    (cd /root && zip -r -q "$ZIPFILE" "$(basename "$BASE")")
    log "Zip created at: $ZIPFILE"
  else
    ZIPFILE="${ZIPFILE%.zip}.tar.gz"
    tar -czf "$ZIPFILE" -C /root "$(basename "$BASE")"
    log "zip unavailable, created tar.gz instead at: $ZIPFILE"
  fi

  echo ""
  echo "=================================================="
  echo " BACKUP COMPLETE"
  echo " Archive location: $ZIPFILE"
  echo " Size: $(du -sh "$ZIPFILE" | cut -f1)"
  echo "=================================================="
}

# ---------- CLEANUP REPORT (no deletion) ----------

cleanup_report() {
  section "Cleanup candidates (REPORT ONLY — nothing will be deleted)"

  log "-- Disk usage by top-level dirs --"
  du -sh /var/* /opt/* /root/* 2>/dev/null | sort -rh | head -30 | tee -a "$REPORT"

  if command -v docker >/dev/null 2>&1; then
    log ""
    log "-- Dangling/unused docker images --"
    docker images -f "dangling=true" | tee -a "$REPORT"
    log "-- Stopped containers --"
    docker ps -a -f "status=exited" | tee -a "$REPORT"
    log "-- Unused volumes (not attached to any container) --"
    docker volume ls -f "dangling=true" | tee -a "$REPORT"
  fi

  log ""
  log "-- apt cache size --"
  du -sh /var/cache/apt/archives 2>/dev/null | tee -a "$REPORT"

  log ""
  log "-- Large log files (>50MB) --"
  find /var/log -type f -size +50M 2>/dev/null | tee -a "$REPORT"

  log ""
  log "-- Old backup folders left by this script in /root --"
  ls -dt /root/gearrent_backup_* 2>/dev/null | tail -n +2 | tee -a "$REPORT"

  echo ""
  echo "Review $REPORT, then decide what to remove manually."
  echo "Nothing was deleted automatically."
}

case "$MODE" in
  discover) discover ;;
  backup) backup ;;
  cleanup-report) cleanup_report ;;
  *) echo "Usage: $0 {discover|backup|cleanup-report}"; exit 1 ;;
esac
