"""GreenSQL benchmark node(s): Ubuntu 24.04 server with PostgreSQL 16 held at
the repository's pinned minor (build/bootstrap_ubuntu.sh), set up the same way
as the two benchmark laptops. Step-by-step use: cloudlab/README.md.

Instructions:
On first boot every node sets itself up once (CloudLab runs this as its
generic `geniuser`, with sudo):
  1. automatic upgrades off (no package update can restart PostgreSQL mid-run);
  2. PostgreSQL's data directory on the node's local blockstore (/mydata);
  3. clones the GreenSQL repository to /mydata/GreenSQL, owned by you and
     linked as ~/GreenSQL;
  4. build/bootstrap_ubuntu.sh: PostgreSQL at the pinned minor, apt-pinned so
     it never moves;
  5. make (the runners), then the chosen databases (StackOverflow 1 GB and/or
     TPC-H SF1 + tpch_idx + the SQLStorm TPC-H queries);
  6. make set-parameters: the laptops' testing GUCs, with shared_buffers and
     effective_cache_size from the parameters below;
  7. login defaults: PGVER, SHARED_BUFFERS, EFFECTIVE_CACHE_SIZE and CLOCK_KHZ
     are exported in login shells, so make targets and compare/run_compare.sh
     use them;
  8. log saving: node disks are WIPED when the experiment ends, so the logs this
     node makes (not the ones the repository already ships), its setup log and
     node_info.txt are copied to /proj/<project>/greensql/<experiment>/<node>/
     every "Save logs every" minutes (0 = off), and
  9. committed to the results repository (default the private
     GreenSQL-RUC/CloudLab-Results), same folder, every "Push results every"
     hours (0 = off). Both also run when a run/detach.sh job ends; by hand:
     `sudo greensql-save-logs`, `sudo greensql-push-results`;
 10. background power log (when "BMC power log" is on and the node's BMC,
     e.g. a Dell iDRAC, answers in-band IPMI): run/power_logger.py as the
     greensql-power-log service, ~1 reading/s of the BMC's whole-node power
     plus the RAPL counters, into logs/power/ (saved and pushed like the other
     logs; match it to runs with compare/match_power.py). Nodes without an
     in-band BMC (the m510) skip it and run exactly as before.

The deploy key (private half) is never in a repository. It is kept once in
/proj/<project>/greensql/.deploy/results_key (owned by geniuser, mode 600),
and every node copies it during setup. cloudlab/README.md has the commands for
putting it there the first time.

Follow it:      tail -f /mydata/greensql_setup.log
Done when:      /mydata/greensql_setup.done exists (greensql_setup.failed on error)
Then, e.g.:     cd ~/GreenSQL && ENTRIES=6 bash compare/run_compare.sh smoke
Log saving:     /mydata/greensql_save.log, /mydata/greensql_push.log
Power log:      systemctl status greensql-power-log; ls ~/GreenSQL/logs/power
"""

import base64
import gzip
import io
import re

import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()
pc.defineParameter("nodeType", "Node type", portal.ParameterType.STRING, "m510")
pc.defineParameter("nodeCount", "Number of nodes", portal.ParameterType.INTEGER, 1)
pc.defineParameter("pgVersion", "PostgreSQL major (minor is pinned by bootstrap_ubuntu.sh)",
                   portal.ParameterType.STRING, "16")
pc.defineParameter("stackoverflow", "Build StackOverflow 1 GB (+ its SQLStorm queries)",
                   portal.ParameterType.BOOLEAN, True)
pc.defineParameter("tpch", "Build TPC-H SF1 + tpch_idx (+ the SQLStorm TPC-H queries)",
                   portal.ParameterType.BOOLEAN, False)
pc.defineParameter("sharedBuffers", "shared_buffers (e.g. 4GB; the laptops use 4GB)",
                   portal.ParameterType.STRING, "4GB")
pc.defineParameter("effectiveCacheSize", "effective_cache_size (e.g. 12GB; the laptops use 12GB)",
                   portal.ParameterType.STRING, "12GB")
pc.defineParameter("clockKhz", "Clock ceiling for compare/run_compare.sh: kHz, or base "
                   "(each node's base frequency, turbo off) or max (top turbo bin). "
                   "2000000 = the m510's base; the laptops use 2500000; c6620 base is 2100000",
                   portal.ParameterType.STRING, "2000000")
pc.defineParameter("powerLog", "BMC power log (whole-node watts ~1/s from the iDRAC via "
                   "in-band IPMI, plus RAPL; only on nodes whose BMC answers, e.g. c6620)",
                   portal.ParameterType.BOOLEAN, True)
pc.defineParameter("saveEvery", "Save logs to /proj every N minutes (0 = off; 1-59 or 60)",
                   portal.ParameterType.INTEGER, 30)
pc.defineParameter("pushEvery", "Push results to GitHub every N hours (0 = off; 1-23)",
                   portal.ParameterType.INTEGER, 3)
pc.defineParameter("resultsRepo", "Results repository (ssh URL; empty = off)",
                   portal.ParameterType.STRING,
                   "git@github.com:GreenSQL-RUC/CloudLab-Results.git", advanced=True)
pc.defineParameter("repoUrl", "GreenSQL repository", portal.ParameterType.STRING,
                   "https://github.com/GreenSQL-RUC/Runner-Scripts.git", advanced=True)
pc.defineParameter("repoBranch", "Branch", portal.ParameterType.STRING, "main", advanced=True)
pc.defineParameter("dataSize", "Local blockstore for PostgreSQL, repo and logs",
                   portal.ParameterType.STRING, "60GB", advanced=True)
pc.defineParameter("nodeTypes", "Mixed node types, one per node, comma-separated (e.g. "
                   "m510,m510,c6620); overrides Node type and Number of nodes when set",
                   portal.ParameterType.STRING, "", advanced=True)
params = pc.bindParameters()

SIZE = re.compile(r"^[0-9]+(MB|GB)$")
TYPES = [t.strip() for t in params.nodeTypes.split(",") if t.strip()] if params.nodeTypes.strip() \
    else [params.nodeType] * params.nodeCount
if params.nodeTypes.strip() and not all(re.match(r"^[a-z0-9][a-z0-9-]*$", t) for t in TYPES):
    pc.reportError(portal.ParameterError("Node type names like m510,m510,c6620", ["nodeTypes"]))
if params.nodeCount < 1 and not params.nodeTypes.strip():
    pc.reportError(portal.ParameterError("At least one node is needed", ["nodeCount"]))
if params.pgVersion not in ("15", "16", "17", "18"):
    pc.reportError(portal.ParameterError("bootstrap_ubuntu.sh pins 15, 16, 17 and 18 only",
                                         ["pgVersion"]))
if not SIZE.match(params.sharedBuffers):
    pc.reportError(portal.ParameterError("Use a size like 4GB or 512MB", ["sharedBuffers"]))
if not SIZE.match(params.effectiveCacheSize):
    pc.reportError(portal.ParameterError("Use a size like 12GB or 512MB", ["effectiveCacheSize"]))
CLOCK = params.clockKhz.strip()
if CLOCK not in ("base", "max") and not (CLOCK.isdigit() and 400000 <= int(CLOCK) <= 6000000):
    pc.reportError(portal.ParameterError("kHz (e.g. 2000000 for 2.0 GHz), base or max", ["clockKhz"]))
if params.saveEvery < 0 or params.saveEvery > 60:
    pc.reportError(portal.ParameterError("Use 0 (off), 1-59 or 60 minutes", ["saveEvery"]))
if params.pushEvery < 0 or params.pushEvery > 23:
    pc.reportError(portal.ParameterError("Use 0 (off) or 1-23 hours", ["pushEvery"]))
pc.verifyParameters()

# CloudLab's standard Ubuntu 24.04 server image (the laptops run 24.04 too).
IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD"

# The one-time setup, run as root by the startup service on every boot; a
# finished setup leaves greensql_setup.done and later boots skip it.
SETUP = r"""#!/usr/bin/env bash
set -euo pipefail
PGV=@PGV@
REPO=@REPO@
BRANCH=@BRANCH@
WANT_SO=@SO@
WANT_TPCH=@TPCH@
SB=@SB@
ECS=@ECS@
CLOCK=@CLOCK@
SAVE_CRON="@SAVECRON@"
PUSH_CRON="@PUSHCRON@"
RESULTS_REPO="@RESULTS@"
POWER_LOG=@POWERLOG@
DATA=/mydata
mkdir -p "$DATA"
LOG="$DATA/greensql_setup.log"
DONE="$DATA/greensql_setup.done"
exec >> "$LOG" 2>&1
step() { echo "==> $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
if [ -f "$DONE" ]; then step "setup already done ($(cat "$DONE")); remove $DONE to redo"; exit 0; fi
rm -f "$DATA/greensql_setup.failed"
trap 'step "!! setup FAILED (line $LINENO)"; date -u > "$DATA/greensql_setup.failed"' ERR

step "0. who and where"
# The startup command runs as CloudLab's generic geniuser, so SUDO_USER is not
# the person: the experiment's creator owns the repository instead. /proj is
# written as geniuser, which every node of every experiment has, so files there
# stay readable by the next node's setup whoever started it.
RUN_USER=""
for u in "$(geni-get user_urn 2>/dev/null | sed 's/.*+//' || true)" \
         "$(cat /var/emulab/boot/creator 2>/dev/null || true)" "${SUDO_USER:-}"; do
    if [ -n "$u" ] && [ "$u" != geniuser ] && getent passwd "$u" > /dev/null; then RUN_USER="$u"; break; fi
done
[ -n "$RUN_USER" ] || RUN_USER=root
PROJ_USER=geniuser
getent passwd geniuser > /dev/null || PROJ_USER="$RUN_USER"
# node0.<experiment>.<project> (hostname -f is the physical name, e.g. ms1126.utah...)
nick=$(cat /var/emulab/boot/nickname 2>/dev/null || hostname -f)
phys=$(cat /var/emulab/boot/nodeid 2>/dev/null || true)
NODE_DIR="$(echo "$nick" | cut -d. -f2)/$(echo "$nick" | cut -d. -f1)${phys:+-$phys}"
PROJ="/proj/$(echo "$nick" | cut -d. -f3)"
[ -d "$PROJ" ] || PROJ="$( (ls -d /proj/*/ 2>/dev/null || true) | head -1)"
PROJ="${PROJ%/}"
echo "    user $RUN_USER, /proj as $PROJ_USER, project share ${PROJ:-none}, results folder $NODE_DIR"

step "1. no automatic upgrades or service restarts during measurements"
systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
mkdir -p /etc/needrestart/conf.d
echo "\$nrconf{restart} = 'l';" > /etc/needrestart/conf.d/90-greensql.conf
while pgrep -x 'apt|apt-get|dpkg' > /dev/null || pgrep -f '^/usr/bin/python3 /usr/bin/unattended-upgrade' > /dev/null; do sleep 5; done

step "2. PostgreSQL data on $DATA (bind mount, before PostgreSQL is installed)"
if ! mountpoint -q /var/lib/postgresql; then
    if [ -n "$(ls -A /var/lib/postgresql 2>/dev/null)" ]; then
        echo "!! /var/lib/postgresql already has data; not moving it" >&2; false
    fi
    mkdir -p "$DATA/postgresql" /var/lib/postgresql
    grep -q ' /var/lib/postgresql ' /etc/fstab \
        || echo "$DATA/postgresql /var/lib/postgresql none bind 0 0" >> /etc/fstab
    mount /var/lib/postgresql
fi

step "3. clone $REPO ($BRANCH) to $DATA/GreenSQL"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git rsync
[ -d "$DATA/GreenSQL/.git" ] || git clone -q -b "$BRANCH" "$REPO" "$DATA/GreenSQL"
cd "$DATA/GreenSQL"
git log -1 --format='    commit %h %s'

step "4. PostgreSQL $PGV at the pinned minor (build/bootstrap_ubuntu.sh)"
bash build/bootstrap_ubuntu.sh "$PGV"
port=$(pg_lsclusters -h | awk -v v="$PGV" '$1==v && $2=="main"{print $3}')
echo "    PG$PGV on port $port reports $(sudo -u postgres psql -p "$port" -Atc 'SHOW server_version')"
echo "    apt pin: $(grep -A1 "postgresql-$PGV " /etc/apt/preferences.d/greensql-postgresql | tail -1)"

step "5. runners and databases"
make
if [ "$WANT_SO" = 1 ]; then
    make build-stackoverflow PGVER="$PGV"
fi
if [ "$WANT_TPCH" = 1 ]; then
    bash build/build_tpch.sh 1 tpch "$PGV"
    bash build/build_tpch_indexed.sh tpch "$PGV"
    make fetch-sqlstorm SQLSTORM_DATASET=tpch
fi

step "6. testing parameters (shared_buffers=$SB, effective_cache_size=$ECS)"
make set-parameters PGVER="$PGV" SHARED_BUFFERS="$SB" EFFECTIVE_CACHE_SIZE="$ECS"

step "7. login defaults, node identity, ownership"
# msr: query_runner's RAPL fallback when the kernel has no powercap zones for
# this CPU (too new for the kernel) reads the MSRs directly.
echo msr > /etc/modules-load.d/greensql-msr.conf
modprobe msr || echo "    !! could not load the msr module"
printf 'export PGVER=%s\nexport SHARED_BUFFERS=%s\nexport EFFECTIVE_CACHE_SIZE=%s\nexport CLOCK_KHZ=%s\n' \
    "$PGV" "$SB" "$ECS" "$CLOCK" > /etc/profile.d/greensql.sh
home=$(getent passwd "$RUN_USER" | cut -d: -f6 || true)
if [ -n "$home" ] && [ -d "$home" ]; then ln -sfn "$DATA/GreenSQL" "$home/GreenSQL"; fi
bash run/node_info.sh | tee "$DATA/node_info.txt"
chown -R "$RUN_USER": "$DATA/GreenSQL"

step "8. log saving to the project's persistent /proj share"
{
    echo "GREENSQL_USER=$RUN_USER"
    echo "GREENSQL_PROJ_USER=$PROJ_USER"
    echo "GREENSQL_PROJ=$PROJ"
    echo "GREENSQL_NODE=$NODE_DIR"
    echo "GREENSQL_DATA=$DATA"
    echo "GREENSQL_RESULTS_REPO=$RESULTS_REPO"
    echo "GREENSQL_RESULTS_KEY=/etc/greensql/results_key"
} > /etc/greensql.conf
cat > /usr/local/bin/greensql-new-logs <<'NEWEOF'
#!/usr/bin/env bash
# greensql-new-logs: the log files this node made or changed - not the ones the
# repository already ships - NUL-separated, relative to the repository root.
set -uo pipefail
. /etc/greensql.conf
git -c safe.directory='*' -C "$GREENSQL_DATA/GreenSQL" ls-files -z --others --modified -- logs
NEWEOF
cat > /usr/local/bin/greensql-save-logs <<'SAVEEOF'
#!/usr/bin/env bash
# greensql-save-logs: copy this node's own logs, its setup log and node_info.txt
# to the project's persistent NFS share (node disks are wiped when the
# experiment ends). Incremental, at the lowest CPU and I/O priority; written as
# GREENSQL_PROJ_USER (geniuser), since NFS squashes root.
set -uo pipefail
. /etc/greensql.conf
now() { date -u +%FT%TZ; }
[ -n "${GREENSQL_PROJ:-}" ] && [ -d "$GREENSQL_PROJ" ] \
    || { echo "$(now) no /proj share mounted; nothing saved" >&2; exit 1; }
dest="$GREENSQL_PROJ/greensql/$GREENSQL_NODE"
list=$(mktemp); chmod 644 "$list"; trap 'rm -f "$list"' EXIT
/usr/local/bin/greensql-new-logs > "$list" || exit 1
as() { sudo -u "$GREENSQL_PROJ_USER" "$@"; }
as mkdir -p "$dest" || exit 1
as nice -n 19 ionice -c3 rsync -a --from0 --files-from="$list" "$GREENSQL_DATA/GreenSQL/" "$dest/" || exit 1
for f in greensql_setup.log node_info.txt; do
    [ -r "$GREENSQL_DATA/$f" ] && as cp "$GREENSQL_DATA/$f" "$dest/"
done
echo "$(now) saved $(tr -cd '\0' < "$list" | wc -c) log files to $dest ($(du -sh "$dest" | cut -f1))"
SAVEEOF
chmod 755 /usr/local/bin/greensql-new-logs /usr/local/bin/greensql-save-logs
if [ -n "$SAVE_CRON" ]; then
    echo "$SAVE_CRON root /usr/local/bin/greensql-save-logs >> $DATA/greensql_save.log 2>&1" \
        > /etc/cron.d/greensql-save-logs
fi
/usr/local/bin/greensql-save-logs >> "$DATA/greensql_save.log" 2>&1 \
    || echo "    !! first save failed (see $DATA/greensql_save.log); logs stay on this node only"

step "9. results to GitHub ($RESULTS_REPO)"
# GitHub's published ed25519 host key, so the first push cannot be redirected.
grep -q '^github.com ssh-ed25519 ' /etc/ssh/ssh_known_hosts 2>/dev/null \
    || echo 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
        >> /etc/ssh/ssh_known_hosts
install -d -m 700 /etc/greensql
key="$PROJ/greensql/.deploy/results_key"
if [ -n "$PROJ" ] && sudo -u "$PROJ_USER" cat "$key" > /etc/greensql/results_key.tmp 2>/dev/null \
        && [ -s /etc/greensql/results_key.tmp ]; then
    chmod 600 /etc/greensql/results_key.tmp && mv /etc/greensql/results_key.tmp /etc/greensql/results_key
    echo "    deploy key from $key"
else
    rm -f /etc/greensql/results_key.tmp
    echo "    !! no deploy key at $key; pushes fail until one is installed (cloudlab/README.md)"
fi
cat > /usr/local/bin/greensql-push-results <<'PUSHEOF'
#!/usr/bin/env bash
# greensql-push-results: commit this node's own logs, its setup log and
# node_info.txt to the results repo (GitHub, deploy key), in
# <experiment>/<node>-<physical id>/. Each node writes only its own folder on
# top of the newest main, so nodes never conflict; a push that loses a race to
# another node is redone. Fetches are shallow and blob-less, so a node never
# downloads other nodes' results.
set -uo pipefail
. "${GREENSQL_CONF:-/etc/greensql.conf}"   # GREENSQL_DATA GREENSQL_NODE GREENSQL_RESULTS_REPO [GREENSQL_RESULTS_KEY]
now() { date -u +%FT%TZ; }
[ -n "${GREENSQL_RESULTS_REPO:-}" ] || { echo "$(now) no results repo configured; nothing pushed"; exit 0; }
case "$GREENSQL_RESULTS_REPO" in
    git@*|ssh://*)
        key="${GREENSQL_RESULTS_KEY:-/etc/greensql/results_key}"
        [ -r "$key" ] || { echo "$(now) no deploy key at $key; nothing pushed" >&2; exit 1; }
        export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=30" ;;
esac
sub="${GREENSQL_NODE:?GREENSQL_NODE not set in the config}"

R="$GREENSQL_DATA/results"
if [ ! -d "$R/.git" ]; then
    git init -q -b main "$R" || exit 1
    git -C "$R" remote add origin "$GREENSQL_RESULTS_REPO"
    git -C "$R" config remote.origin.promisor true
    git -C "$R" config remote.origin.partialclonefilter blob:none
    git -C "$R" config user.name "greensql node"
    git -C "$R" config user.email "greensql-node@$(hostname -f)"
fi
list=$(mktemp); trap 'rm -f "$list"' EXIT
"${GREENSQL_NEW_LOGS:-/usr/local/bin/greensql-new-logs}" > "$list" || exit 1
cd "$R" || exit 1
mkdir -p "$sub"
nice -n 19 ionice -c3 rsync -a --from0 --files-from="$list" "$GREENSQL_DATA/GreenSQL/" "$sub/" || exit 1
for f in greensql_setup.log node_info.txt; do
    [ -r "$GREENSQL_DATA/$f" ] && cp "$GREENSQL_DATA/$f" "$sub/"
done

err=""
for try in 1 2 3 4 5; do
    [ "$try" -gt 1 ] && sleep $((RANDOM % 30 + 10))
    # Start from the newest main: its tree in the index, this node's folder on
    # top. An empty repo has no main yet, so the first commit starts it.
    if ! tip=$(git ls-remote origin refs/heads/main 2>&1); then err="$tip"; continue; fi
    parent=(); base=""
    if [ -n "$tip" ]; then
        if ! err=$(git fetch -q --depth=1 --filter=blob:none origin main 2>&1); then continue; fi
        git read-tree FETCH_HEAD || exit 1
        parent=(-p FETCH_HEAD); base=$(git rev-parse FETCH_HEAD^{tree})
    else
        git read-tree --empty
    fi
    git add -A -- "$sub"
    # Plumbing, not `git commit`: commit checks every blob in the tree exists
    # and would download all the other nodes' files to do so.
    tree=$(git write-tree --missing-ok) || exit 1
    if [ "$tree" = "$base" ]; then echo "$(now) $sub: nothing new"; exit 0; fi
    c=$(git commit-tree "$tree" "${parent[@]}" -m "$sub $(now)") && git update-ref HEAD "$c" || exit 1
    if err=$(nice -n 19 git push -q origin HEAD:main 2>&1); then
        echo "$(now) pushed $sub ($(git rev-parse --short HEAD), $(du -sh "$sub" | cut -f1))"
        exit 0
    fi
    echo "$(now) push attempt $try failed (another node first?); retrying"
done
echo "$(now) !! not pushed after 5 attempts; logs stay on this node: $err" >&2
exit 1
PUSHEOF
chmod 755 /usr/local/bin/greensql-push-results
if [ -n "$PUSH_CRON" ] && [ -n "$RESULTS_REPO" ]; then
    echo "$PUSH_CRON root /usr/local/bin/greensql-push-results >> $DATA/greensql_push.log 2>&1" \
        > /etc/cron.d/greensql-push-results
fi
if [ -n "$RESULTS_REPO" ]; then
    /usr/local/bin/greensql-push-results >> "$DATA/greensql_push.log" 2>&1 \
        || echo "    !! first push failed (see $DATA/greensql_push.log)"
fi
step "10. background power log (BMC via in-band IPMI)"
if [ "$POWER_LOG" = 1 ]; then
    apt-get install -y -qq ipmitool || echo "    !! ipmitool did not install"
    # The driver's kipmi0 thread busy-waits on the BMC by default, which would
    # put CPU load (and package power) under every measurement; capped at 100 us.
    echo "options ipmi_si kipmid_max_busy_us=100" > /etc/modprobe.d/greensql-ipmi.conf
    modprobe ipmi_si 2>/dev/null || true
    modprobe ipmi_devintf 2>/dev/null || true
    if python3 "$DATA/GreenSQL/run/power_logger.py" --check; then
        printf 'ipmi_si\nipmi_devintf\n' > /etc/modules-load.d/greensql-ipmi.conf
        cat > /etc/systemd/system/greensql-power-log.service <<UNITEOF
[Unit]
Description=GreenSQL background power log (BMC DCMI + RAPL, ~1/s) into $DATA/GreenSQL/logs/power
After=multi-user.target

[Service]
ExecStart=/usr/bin/nice -n 10 /usr/bin/python3 $DATA/GreenSQL/run/power_logger.py $DATA/GreenSQL/logs/power
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
        systemctl daemon-reload
        systemctl enable --now greensql-power-log.service || echo "    !! the power log service did not start"
        echo "    logging to $DATA/GreenSQL/logs/power (systemctl status greensql-power-log)"
    else
        echo "    no BMC power reading on this node (no in-band IPMI); no power log"
    fi
else
    echo "    off (profile parameter)"
fi

date -u +%Y-%m-%dT%H:%M:%SZ > "$DONE"
step "setup finished"
"""

script = (SETUP.replace("@PGV@", params.pgVersion)
               .replace("@REPO@", params.repoUrl)
               .replace("@BRANCH@", params.repoBranch)
               .replace("@SO@", "1" if params.stackoverflow else "0")
               .replace("@TPCH@", "1" if params.tpch else "0")
               .replace("@SB@", params.sharedBuffers)
               .replace("@ECS@", params.effectiveCacheSize)
               .replace("@CLOCK@", CLOCK)
               .replace("@POWERLOG@", "1" if params.powerLog else "0")
               .replace("@SAVECRON@", "" if params.saveEvery == 0 else
                        ("0 * * * *" if params.saveEvery == 60 else "*/%d * * * *" % params.saveEvery))
               .replace("@PUSHCRON@", "" if params.pushEvery == 0 else "17 */%d * * *" % params.pushEvery)
               .replace("@RESULTS@", params.resultsRepo))
# gzip + base64 keeps the startup command short and free of quoting problems.
buf = io.BytesIO()
with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
    gz.write(script.encode("utf-8"))
encoded = base64.b64encode(buf.getvalue()).decode("ascii")
command = ("echo %s | base64 -d | gunzip > /tmp/greensql_setup.sh && sudo bash /tmp/greensql_setup.sh"
           % encoded)

request = pc.makeRequestRSpec()
for i, ntype in enumerate(TYPES):
    node = request.RawPC("node%d" % i)          # bare metal: the whole machine
    node.hardware_type = ntype
    node.disk_image = IMAGE
    bs = node.Blockstore("data%d" % i, "/mydata")
    bs.size = params.dataSize
    node.addService(pg.Execute(shell="bash", command=command))

pc.printRequestRSpec(request)
