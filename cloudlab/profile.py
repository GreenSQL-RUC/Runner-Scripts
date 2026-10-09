"""GreenSQL benchmark node(s): Ubuntu 24.04 server with PostgreSQL 16 held at
the repository's pinned minor (build/bootstrap_ubuntu.sh), set up the same way
as the two benchmark laptops.

Instructions:
On first boot every node sets itself up once, as root:
  1. automatic upgrades off (no package update can restart PostgreSQL mid-run);
  2. PostgreSQL's data directory on the node's local blockstore (/mydata);
  3. clones the GreenSQL repository to /mydata/GreenSQL (linked as ~/GreenSQL);
  4. build/bootstrap_ubuntu.sh: PostgreSQL at the pinned minor, apt-pinned so
     it never moves;
  5. make (the runners), then the chosen databases (StackOverflow 1 GB and/or
     TPC-H SF1 + tpch_idx + the SQLStorm TPC-H queries);
  6. make set-parameters (the same testing GUCs as the laptops);
  7. log saving: node disks are WIPED when the experiment ends, so the node
     copies /mydata/GreenSQL/logs (plus its setup log and node_info.txt) to the
     project's persistent NFS share, /proj/<project>/greensql/<experiment>/<node>/,
     every "Save logs every" minutes (incremental rsync at the lowest CPU and
     I/O priority; 0 = off). Run `greensql-save-logs` by hand after a run ends,
     and before the experiment expires;
  8. results to GitHub: every "Push results every" hours the node also commits
     the same files to the results repository (default the private
     GreenSQL-RUC/CloudLab-Results), into <experiment>/<node>/, with that repo's
     deploy key. Nodes only add their own folder, so several nodes can push to
     the same repository. `greensql-push-results` pushes by hand.

The deploy key (private half) is never in a repository. Put it once in the
project's /proj share and every later node picks it up during setup:
    ssh <you>@<node> 'mkdir -p -m 700 /proj/<project>/greensql/.deploy'
    scp ~/.ssh/greensql_results_deploy <you>@<node>:/proj/<project>/greensql/.deploy/results_key
    ssh <you>@<node> 'chmod 600 /proj/<project>/greensql/.deploy/results_key'
If it was not there at setup, install it on a running node with
    sudo install -m 600 <key file> /etc/greensql/results_key

Follow it:      tail -f /mydata/greensql_setup.log
Done when:      /mydata/greensql_setup.done exists (greensql_setup.failed on error)
Then, e.g.:     cd ~/GreenSQL && make warm-stepup DB_NAME=stackoverflow_1gb ...
PGVER is preset to the installed major in login shells, so make targets use it.
Log saving:     /mydata/greensql_save.log, /mydata/greensql_push.log
"""

import base64
import gzip
import io

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
params = pc.bindParameters()

if params.nodeCount < 1:
    pc.reportError(portal.ParameterError("At least one node is needed", ["nodeCount"]))
if params.pgVersion not in ("15", "16", "17", "18"):
    pc.reportError(portal.ParameterError("bootstrap_ubuntu.sh pins 15, 16, 17 and 18 only",
                                         ["pgVersion"]))
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
U="${SUDO_USER:-root}"
PGV=@PGV@
REPO=@REPO@
BRANCH=@BRANCH@
WANT_SO=@SO@
WANT_TPCH=@TPCH@
SAVE_CRON="@SAVECRON@"
PUSH_CRON="@PUSHCRON@"
RESULTS_REPO="@RESULTS@"
DATA=/mydata
mkdir -p "$DATA"
LOG="$DATA/greensql_setup.log"
DONE="$DATA/greensql_setup.done"
exec >> "$LOG" 2>&1
step() { echo "==> $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
if [ -f "$DONE" ]; then step "setup already done ($(cat "$DONE")); remove $DONE to redo"; exit 0; fi
rm -f "$DATA/greensql_setup.failed"
trap 'step "!! setup FAILED (line $LINENO)"; date -u > "$DATA/greensql_setup.failed"' ERR

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

step "6. testing parameters"
make set-parameters PGVER="$PGV"

step "7. login defaults, node identity, ownership"
echo "export PGVER=$PGV" > /etc/profile.d/greensql.sh
home=$(getent passwd "$U" | cut -d: -f6)
[ -n "$home" ] && [ -d "$home" ] && ln -sfn "$DATA/GreenSQL" "$home/GreenSQL"
bash run/node_info.sh | tee "$DATA/node_info.txt"
chown -R "$U": "$DATA/GreenSQL"

step "8. log saving to the project's persistent /proj share"
printf 'GREENSQL_USER=%s\nGREENSQL_DATA=%s\nGREENSQL_RESULTS_REPO=%s\nGREENSQL_RESULTS_KEY=%s\n' \
    "$U" "$DATA" "$RESULTS_REPO" /etc/greensql/results_key > /etc/greensql.conf
cat > /usr/local/bin/greensql-save-logs <<'SAVEEOF'
#!/usr/bin/env bash
# greensql-save-logs: copy this node's GreenSQL logs to the project's persistent
# NFS share (node disks are wiped when the experiment ends). Incremental, at the
# lowest CPU and I/O priority; runs as the experiment user (NFS squashes root).
set -uo pipefail
. /etc/greensql.conf
proj=$(ls -d /proj/*/ 2>/dev/null | head -1)
[ -n "$proj" ] || { echo "$(date -u +%FT%TZ) no /proj share mounted; nothing saved" >&2; exit 1; }
fq=$(hostname -f)                                     # node0.<experiment>.<project>....
phys=$(cat /var/emulab/boot/nodeid 2>/dev/null || true)
dest="${proj%/}/greensql/$(echo "$fq" | cut -d. -f2)/$(echo "$fq" | cut -d. -f1)${phys:+-$phys}"
sudo -u "$GREENSQL_USER" mkdir -p "$dest" || exit 1
sudo -u "$GREENSQL_USER" nice -n 19 ionice -c3 rsync -a \
    "$GREENSQL_DATA/GreenSQL/logs/" "$dest/logs/" || exit 1
for f in greensql_setup.log node_info.txt; do
    [ -r "$GREENSQL_DATA/$f" ] && sudo -u "$GREENSQL_USER" cp "$GREENSQL_DATA/$f" "$dest/"
done
echo "$(date -u +%FT%TZ) saved to $dest ($(du -sh "$dest" | cut -f1))"
SAVEEOF
chmod 755 /usr/local/bin/greensql-save-logs
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
for k in /proj/*/greensql/.deploy/results_key; do
    if [ -f "$k" ] && sudo -u "$U" cat "$k" > /etc/greensql/results_key.tmp 2>/dev/null; then
        chmod 600 /etc/greensql/results_key.tmp && mv /etc/greensql/results_key.tmp /etc/greensql/results_key
        echo "    deploy key from $k"; break
    fi
done
rm -f /etc/greensql/results_key.tmp
[ -f /etc/greensql/results_key ] \
    || echo "    !! no deploy key in /proj/<project>/greensql/.deploy/results_key; pushes fail until one is installed"
cat > /usr/local/bin/greensql-push-results <<'PUSHEOF'
#!/usr/bin/env bash
# greensql-push-results: commit this node's GreenSQL logs to the results repo
# (GitHub, deploy key). Each node writes only its own folder,
# <experiment>/<node>[-<physical id>]/, on top of the newest main, so nodes never
# conflict; a push that loses a race to another node is redone. Fetches are
# shallow and blob-less, so a node never downloads other nodes' results.
set -uo pipefail
. "${GREENSQL_CONF:-/etc/greensql.conf}"   # GREENSQL_DATA GREENSQL_RESULTS_REPO [GREENSQL_RESULTS_KEY]
now() { date -u +%FT%TZ; }
[ -n "${GREENSQL_RESULTS_REPO:-}" ] || { echo "$(now) no results repo configured; nothing pushed"; exit 0; }
case "$GREENSQL_RESULTS_REPO" in
    git@*|ssh://*)
        key="${GREENSQL_RESULTS_KEY:-/etc/greensql/results_key}"
        [ -r "$key" ] || { echo "$(now) no deploy key at $key; nothing pushed" >&2; exit 1; }
        export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=30" ;;
esac
if [ -n "${GREENSQL_NODE:-}" ]; then
    sub="$GREENSQL_NODE"
else
    fq=$(hostname -f)                                 # node0.<experiment>.<project>....
    phys=$(cat /var/emulab/boot/nodeid 2>/dev/null || true)
    sub="$(echo "$fq" | cut -d. -f2)/$(echo "$fq" | cut -d. -f1)${phys:+-$phys}"
fi

R="$GREENSQL_DATA/results"
if [ ! -d "$R/.git" ]; then
    git init -q -b main "$R" || exit 1
    git -C "$R" remote add origin "$GREENSQL_RESULTS_REPO"
    git -C "$R" config remote.origin.promisor true
    git -C "$R" config remote.origin.partialclonefilter blob:none
    git -C "$R" config user.name "greensql node"
    git -C "$R" config user.email "greensql-node@$(hostname -f)"
fi
cd "$R" || exit 1
mkdir -p "$sub"
nice -n 19 ionice -c3 rsync -a --delete "$GREENSQL_DATA/GreenSQL/logs/" "$sub/logs/" || exit 1
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
date -u +%Y-%m-%dT%H:%M:%SZ > "$DONE"
step "setup finished"
"""

script = (SETUP.replace("@PGV@", params.pgVersion)
               .replace("@REPO@", params.repoUrl)
               .replace("@BRANCH@", params.repoBranch)
               .replace("@SO@", "1" if params.stackoverflow else "0")
               .replace("@TPCH@", "1" if params.tpch else "0")
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
for i in range(params.nodeCount):
    node = request.RawPC("node%d" % i)          # bare metal: the whole machine
    node.hardware_type = params.nodeType
    node.disk_image = IMAGE
    bs = node.Blockstore("data%d" % i, "/mydata")
    bs.size = params.dataSize
    node.addService(pg.Execute(shell="bash", command=command))

pc.printRequestRSpec(request)
