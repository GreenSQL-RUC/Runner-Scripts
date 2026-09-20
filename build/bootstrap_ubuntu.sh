#!/usr/bin/env bash
#
# bootstrap_ubuntu.sh [pg_versions]
#
# Provision a FRESH Ubuntu box (tested against 24.04 "noble") with everything the
# build + benchmark scripts assume, so build_tpch.sh / build_all.sh work out of
# the box. It installs:
#   - the build toolchain: build-essential (gcc/make) + git - needed to compile
#     tpch-dbgen (build_tpch.sh) and the C runners (`make all`);
#   - the PostgreSQL APT repository (apt.postgresql.org / "PGDG"), because
#     Ubuntu's own repos carry only ONE PostgreSQL major, and this harness
#     compares several side by side;
#   - the requested PostgreSQL majors (default 15 16 17 18; PG14 leaves
#     community support in November 2026 and is no longer built). Installing
#     each one auto-creates and starts its own `main` cluster on its own port,
#     which is exactly what pg_lsclusters / pg_ctlcluster (used everywhere
#     here) expect.
#
# MINOR VERSIONS ARE PINNED. Every major is installed at the exact minor in
# PIN_MINOR below (the newest PGDG release when the pin was set), and an apt
# preferences file keeps it there: if 18.7 appears in the repo, this script
# and `apt-get upgrade` still install / keep 18.6, so every box built from
# this repo runs the same binaries. Bump PIN_MINOR deliberately, then re-run.
# A box that already has a DIFFERENT minor installed is left alone with a
# warning; FORCE_MINOR=1 moves it to the pinned one (apt allows the downgrade
# because the pin has priority 1001). PIN_MINOR=0 disables pinning.
#
# Idempotent: already-installed packages and an already-configured repo are left
# alone, so it is safe to re-run (e.g. to add another version later).
#
# Run as root:
#   sudo bash bootstrap_ubuntu.sh              # PostgreSQL 15, 16, 17 and 18
#   sudo bash bootstrap_ubuntu.sh "18"         # just PG18
#   sudo bash bootstrap_ubuntu.sh "15 16 17 18"
#   sudo FORCE_MINOR=1 bash bootstrap_ubuntu.sh "18"   # move PG18 to the pinned minor
#
# NOTE: the energy runner (`make run`) additionally needs Intel RAPL and the
# 'msr' kernel module at run time (`sudo modprobe msr`); that is a runtime knob,
# not an install step, so it is not done here.
#
set -euo pipefail

VERS="${*:-15 16 17 18}"

# Pinned minor per major: newest PGDG release on 2026-09-18. Keep in step with
# the "PostgreSQL versions" section of README.md when bumping.
declare -A PIN_MINOR=(
    [15]=15.19
    [16]=16.15
    [17]=17.11
    [18]=18.6
)
PIN_FILE=/etc/apt/preferences.d/greensql-postgresql

[ "$(id -u)" = 0 ] || { echo "!! must run as root (apt install); use sudo" >&2; exit 1; }
command -v apt-get >/dev/null 2>&1 || {
    echo "!! no apt-get - this bootstrap targets Debian/Ubuntu (24.04)" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update + build toolchain (build-essential, git, curl, gnupg, lsb-release)"
apt-get update -qq
apt-get install -y build-essential git curl ca-certificates gnupg lsb-release

# --- PostgreSQL APT repository (PGDG) so several majors can coexist ------------
setup_pgdg() {
    if ls /etc/apt/sources.list.d/pgdg*.list \
          /etc/apt/sources.list.d/pgdg*.sources >/dev/null 2>&1; then
        echo "==> PGDG apt repo already configured"
        return 0
    fi
    echo "==> configuring the PostgreSQL APT repository (PGDG)"
    # postgresql-common ships the official repo installer, which picks the right
    # Ubuntu codename and signing key automatically.
    apt-get install -y postgresql-common
    if [ -x /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh ]; then
        /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    else
        # Fallback for older postgresql-common without the helper.
        install -d /usr/share/keyrings
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg]" \
             "http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
        apt-get update -qq
    fi
}
setup_pgdg

# --- pin each major to its minor ---------------------------------------------
# One apt preferences stanza per major, priority 1001: apt then both SELECTS
# that minor on install and REFUSES to upgrade away from it (a newer minor in
# the repo sits at the default priority 500). Server, client, contrib-style
# add-ons (postgresql-18-*) and the -dev package all follow the same pin.
if [ "${PIN_MINOR:-1}" != "0" ]; then
    echo "==> pinning minors in $PIN_FILE"
    : > "$PIN_FILE.tmp"
    for v in $VERS; do
        minor="${PIN_MINOR[$v]:-}"
        if [ -z "$minor" ]; then
            echo "  !! no pinned minor for PG$v in PIN_MINOR - it will float to the newest" >&2
            continue
        fi
        printf 'Package: postgresql-%s postgresql-client-%s postgresql-%s-* postgresql-server-dev-%s\nPin: version %s*\nPin-Priority: 1001\n\n' \
            "$v" "$v" "$v" "$v" "$minor" >> "$PIN_FILE.tmp"
    done
    mv "$PIN_FILE.tmp" "$PIN_FILE"
    apt-get update -qq
fi

# --- the PostgreSQL majors (each creates + starts a 'main' cluster) ------------
pkgs=""
for v in $VERS; do
    minor="${PIN_MINOR[$v]:-}"
    installed="$(dpkg-query -W -f='${Version}' "postgresql-$v" 2>/dev/null || true)"
    candidate="$(apt-cache policy "postgresql-$v" | awk '/Candidate:/ {print $2}')"
    if [ -n "$minor" ] && [ "${PIN_MINOR:-1}" != "0" ]; then
        case "$candidate" in
            "$minor"-*) ;;
            *) echo "!! PG$v: pinned minor $minor is not in the apt repo (candidate: ${candidate:-none})." >&2
               echo "   PGDG keeps only recent minors; bump PIN_MINOR[$v] in $0 or set PIN_MINOR=0." >&2
               exit 1 ;;
        esac
        case "$installed" in
            "") ;;                                   # not installed yet: install pinned
            "$minor"-*) echo "==> PG$v already at pinned minor $installed" ;;
            *) if [ "${FORCE_MINOR:-0}" = "1" ]; then
                   echo "==> PG$v installed at $installed; FORCE_MINOR=1: moving to $minor"
                   pkgs="$pkgs postgresql-$v postgresql-client-$v"
               else
                   echo "  !! PG$v is installed at $installed, pinned minor is $minor." >&2
                   echo "     Left as is (runs may be in progress). Re-run with FORCE_MINOR=1 to move it." >&2
               fi
               continue ;;
        esac
    fi
    pkgs="$pkgs postgresql-$v"
done
if [ -n "$pkgs" ]; then
    echo "==> installing:$pkgs  (pinned:$(for v in $VERS; do printf ' %s' "${PIN_MINOR[$v]:-any}"; done))"
    apt-get install -y --allow-downgrades $pkgs
fi

# Installing several majors in one apt run does NOT reliably auto-create a 'main'
# cluster for each (postgresql-common tends to create one only for the first /
# default version), so explicitly create any that are missing and start them.
# Ports are auto-assigned to the next free one, which is fine - the build scripts
# discover them via pg_lsclusters, never hard-code them.
for v in $VERS; do
    if [ -d "/etc/postgresql/$v/main" ]; then
        echo "==> PG$v 'main' cluster already exists"
    else
        echo "==> creating + starting PG$v 'main' cluster"
        pg_createcluster "$v" main --start
    fi
done

echo
echo "==> clusters now available:"
pg_lsclusters

echo
echo "Bootstrap complete. Next:"
echo "  sudo bash build_all.sh                 # generate + load TPC-H on every cluster"
echo "  sudo bash build_tpch.sh 1 tpch 18      # or one scale factor / db / version"
