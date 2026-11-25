#!/usr/bin/env bash
# Copy the toolkit into /opt and the host config into /etc.
# DESTDIR stages a tree without root, used to check the layout.
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
DESTDIR=${DESTDIR:-}
PREFIX=${PREFIX:-/opt/infrawatch}
CONFDIR=${CONFDIR:-/etc/infrawatch}

if [[ "$PREFIX" != /* ]]; then
  printf 'PREFIX must be an absolute path\n' >&2
  exit 1
fi
if [[ -n "$DESTDIR" && "$DESTDIR" != /* ]]; then
  printf 'DESTDIR must be an absolute path\n' >&2
  exit 1
fi
if [[ -z "$DESTDIR" && "$(id -u)" -ne 0 ]]; then
  printf 'install needs root, or set DESTDIR to stage a tree\n' >&2
  exit 1
fi

stage() {
  printf '%s%s\n' "$DESTDIR" "$1"
}

install -d "$(stage "$PREFIX/bin/lib")"
install -d "$(stage "$PREFIX/docs/runbooks")"
install -d "$(stage "$PREFIX/sql")"
install -d -m 0750 "$(stage "$CONFDIR")"
install -d -m 0755 "$(stage /etc/systemd/system)"
install -d -m 0755 "$(stage /etc/cron.d)"
install -d -m 0755 "$(stage /etc/logrotate.d)"
install -d -m 0750 "$(stage /var/backups/infrawatch)"
install -d -m 0755 "$(stage /var/log/infrawatch)"
install -d -m 0750 "$(stage /var/lib/infrawatch)"

install -m 0755 "$ROOT/bin/infrawatch" "$(stage "$PREFIX/bin/infrawatch")"
install -m 0755 "$ROOT/bin/install.sh" "$(stage "$PREFIX/bin/install.sh")"
for f in "$ROOT"/bin/lib/*.sh; do
  install -m 0644 "$f" "$(stage "$PREFIX/bin/lib/$(basename "$f")")"
done
for f in "$ROOT"/docs/runbooks/*.md; do
  install -m 0644 "$f" "$(stage "$PREFIX/docs/runbooks/$(basename "$f")")"
done
for f in "$ROOT"/sql/*.sql; do
  install -m 0644 "$f" "$(stage "$PREFIX/sql/$(basename "$f")")"
done

conf_dest=$(stage "$CONFDIR/infrawatch.conf")
if [[ ! -f "$conf_dest" ]]; then
  install -m 0644 "$ROOT/config/infrawatch.system.conf" "$conf_dest"
else
  printf 'keeping existing %s\n' "$conf_dest"
fi
install -m 0644 "$ROOT/.env.example" "$(stage "$CONFDIR/infrawatch.env.example")"

# Rewrite the default prefix when the operator passes a different PREFIX.
for unit in \
  infrawatch-backup.service infrawatch-backup.timer \
  infrawatch-restore-test.service infrawatch-restore-test.timer \
  infrawatch-healthcheck.service infrawatch-healthcheck.timer
do
  sed "s#/opt/infrawatch#${PREFIX}#g" "$ROOT/systemd/$unit" \
    > "$(stage "/etc/systemd/system/$unit")"
  chmod 0644 "$(stage "/etc/systemd/system/$unit")"
done

sed "s#/opt/infrawatch#${PREFIX}#g" "$ROOT/cron/infrawatch" \
  > "$(stage /etc/cron.d/infrawatch)"
chmod 0644 "$(stage /etc/cron.d/infrawatch)"

install -m 0644 "$ROOT/config/logrotate/infrawatch" "$(stage /etc/logrotate.d/infrawatch)"

if [[ -z "$DESTDIR" ]] && id postgres >/dev/null 2>&1; then
  chown postgres:postgres \
    /var/backups/infrawatch \
    /var/log/infrawatch \
    /var/lib/infrawatch
  chown root:postgres "$CONFDIR"
  chmod 0750 "$CONFDIR"
  chown root:postgres "$CONFDIR/infrawatch.conf" || true
  chmod 0640 "$CONFDIR/infrawatch.conf" || true
fi

if [[ -z "$DESTDIR" ]]; then
  systemctl daemon-reload
fi

cat <<EOF
Installed under ${DESTDIR}${PREFIX}

Edit ${DESTDIR}${CONFDIR}/infrawatch.conf if the database name or paths differ.
Create the env file (mode 640, root:postgres) with the password:

  cp ${DESTDIR}${CONFDIR}/infrawatch.env.example ${DESTDIR}${CONFDIR}/infrawatch.env

Apply sql/grants.sql as a superuser if the role does not exist yet.
Enable one scheduler, not both:

  systemctl enable --now infrawatch-backup.timer infrawatch-restore-test.timer infrawatch-healthcheck.timer

The cron file is already in /etc/cron.d/infrawatch. Remove it if you use the timers.
EOF
