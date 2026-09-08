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
#   - the requested PostgreSQL majors (default 14 16 18). Installing each one
#     auto-creates and starts its own `main` cluster on its own port, which is
#     exactly what pg_lsclusters / pg_ctlcluster (used everywhere here) expect.
#
# Idempotent: already-installed packages and an already-configured repo are left
# alone, so it is safe to re-run (e.g. to add another version later).
#
# Run as root:
#   sudo bash bootstrap_ubuntu.sh              # PostgreSQL 14, 16 and 18
#   sudo bash bootstrap_ubuntu.sh "16"         # just PG16 (24.04's own default major)
#   sudo bash bootstrap_ubuntu.sh "14 16 18"
#
# NOTE: the energy runner (`make run`) additionally needs Intel RAPL and the
# 'msr' kernel module at run time (`sudo modprobe msr`); that is a runtime knob,
# not an install step, so it is not done here.
#
set -euo pipefail

VERS="${*:-14 16 18}"

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

# --- the PostgreSQL majors (each creates + starts a 'main' cluster) ------------
pkgs=""
for v in $VERS; do pkgs="$pkgs postgresql-$v"; done
echo "==> installing:$pkgs"
apt-get install -y $pkgs

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
echo "  sudo bash build_tpch.sh 1 tpch 16      # or one scale factor / db / version"
