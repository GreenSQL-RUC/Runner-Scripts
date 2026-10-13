# CloudLab

Running the GreenSQL benchmarks on CloudLab bare-metal nodes. `profile.py` is
the CloudLab profile: it asks for the nodes and, on first boot, sets each one
up the way the two benchmark laptops are set up. It also makes sure results
leave the node: node disks are **wiped** when an experiment ends.

Commands below are marked by where they run: **desktop** (Windows PowerShell;
on Linux/macOS drop the `$env:USERPROFILE\` part and use `~/`), **node** (a
shell on the CloudLab node), or **portal** (the CloudLab website).

## What a node gets

| Step | What setup does |
|---|---|
| 0 | works out who you are (the experiment creator), the project share `/proj/<project>` and the results folder `<experiment>/<node>-<physical id>` |
| 1 | turns off automatic upgrades (nothing can restart PostgreSQL mid-run) |
| 2 | puts PostgreSQL's data on the node's blockstore, `/mydata` |
| 3 | clones this repository to `/mydata/GreenSQL`, owned by you, linked as `~/GreenSQL` |
| 4 | `build/bootstrap_ubuntu.sh`: PostgreSQL at the pinned minor (16.15, 18.6, ...), held there by apt |
| 5 | `make`, then the chosen databases (StackOverflow 1 GB and/or TPC-H SF1 + `tpch_idx`) |
| 6 | `make set-parameters`: the laptops' testing settings, with `shared_buffers` and `effective_cache_size` from the profile |
| 7 | exports `PGVER`, `SHARED_BUFFERS`, `EFFECTIVE_CACHE_SIZE` and `CLOCK_KHZ` in login shells, so `make` and `compare/run_compare.sh` pick them up |
| 8 | copies the logs the node makes (not the laptop logs the repository ships) to `/proj/<project>/greensql/<experiment>/<node>/` every 30 min |
| 9 | commits the same files to [GreenSQL-RUC/CloudLab-Results](https://github.com/GreenSQL-RUC/CloudLab-Results), same folder, every 3 h |

Both copies also run as soon as any job started with `run/detach.sh` ends. Logs:
`/mydata/greensql_setup.log`, `/mydata/greensql_save.log`, `/mydata/greensql_push.log`.
Setup leaves `/mydata/greensql_setup.done` (or `greensql_setup.failed`).

CloudLab runs the startup command as its own generic user, `geniuser`. Setup
gives the repository to you and writes `/proj` as `geniuser`, which every node
of every experiment has.

## One-time setup

### 1. An ssh key CloudLab knows (desktop + portal)

Without a passphrase, or one you know. If ssh later asks *"Enter passphrase
for key ..."*, the key has one.

```powershell
ssh-keygen -t ed25519 -N '""' -f "$env:USERPROFILE\.ssh\id_cloudlab"
Get-Content "$env:USERPROFILE\.ssh\id_cloudlab.pub"
```

Portal: your name (top right) → **Manage SSH Keys** → paste the `ssh-ed25519 ...`
line. Keys are copied onto nodes when an experiment starts, so add it **before**
starting one (for a running node, see *Troubleshooting*).

### 2. The results deploy key (desktop + GitHub)

A deploy key lets nodes push to the results repository and nothing else.

```powershell
ssh-keygen -t ed25519 -N '""' -C "greensql-cloudlab-results" -f "$env:USERPROFILE\.ssh\greensql_results_deploy"
Get-Content "$env:USERPROFILE\.ssh\greensql_results_deploy.pub"
```

GitHub: CloudLab-Results → Settings → Deploy keys → **Add deploy key** → paste
the `.pub` line, tick **Allow write access**. The private half
(`greensql_results_deploy`, no `.pub`) never goes in a repository or a profile;
step 4 below puts it in the project share. A repository can hold several deploy
keys, so each machine can have its own; delete one there to revoke it.

### 3. The profile (portal)

Experiments → **Create Experiment Profile** → project `greensql` → paste the
contents of `cloudlab/profile.py` → Save. The portal runs the script and shows
its parameters. A pasted profile does not follow the repository: after
`profile.py` changes, open the profile → **Edit Code** → paste the new version
→ Save (a new profile version). Everything else (scripts, runners) the node
clones from `main` at setup, so push changes before starting an experiment.

## Each experiment

### Start it (portal)

Experiments → **Start Experiment** → the profile → parameters:

| Parameter | Default | Notes |
|---|---|---|
| Node type | `m510` | 8-core Xeon D-1548, 2.0 GHz base, 64 GB |
| Number of nodes | 1 | within your reservation's count |
| PostgreSQL major | 16 | 15–18; the minor is pinned by `bootstrap_ubuntu.sh` |
| StackOverflow / TPC-H | on / off | databases to build |
| shared_buffers | 4GB | laptops: 4GB |
| effective_cache_size | 12GB | laptops: 12GB; a 64 GB m510 could take ~48GB |
| Clock ceiling (kHz) | 2000000 | exported as `CLOCK_KHZ`; m510 = its 2.0 GHz base, turbo off |
| Save logs every (min) | 30 | `/proj` copies; 0 = off |
| Push results every (h) | 3 | GitHub pushes; 0 = off |

Then project **greensql**, cluster **Utah**, and a duration long enough for setup
(~20–40 min) plus the runs. With a **reservation** nothing in the profile
changes: start the experiment yourself in the reserved window, in the reserved
project/cluster/node type. Experiments are not stopped at the reservation's
end, but extending can be refused if someone has the node next.

Wait for the node's status **ready**, then take its ssh command from
**List View** (e.g. `ssh mkmason@ms1126.utah.cloudlab.us`).

### Log in and follow setup (desktop → node)

```powershell
ssh -i "$env:USERPROFILE\.ssh\id_cloudlab" <you>@<node>
```

```bash
tail -f /mydata/greensql_setup.log          # Ctrl-C to stop following
```

When it says `setup finished`:

```bash
ls /mydata/greensql_setup.*                  # .done, not .failed
grep -E 'reports|user .*/proj|deploy key' /mydata/greensql_setup.log
ls /proj                                     # the project share, e.g. greensql-PG0
cat /mydata/greensql_save.log /mydata/greensql_push.log
```

Expect `PG16 on port ... reports 16.15`, the user line (you, `/proj` as
`geniuser`, the share, the results folder), and either `deploy key from ...` or,
the very first time, `no deploy key` (next step).

### First experiment only: the deploy key into the project share

Desktop (replace `<you>@<node>`; `<project>` is what `ls /proj` showed):

```powershell
scp -i "$env:USERPROFILE\.ssh\id_cloudlab" "$env:USERPROFILE\.ssh\greensql_results_deploy" <you>@<node>:/tmp/results_key
```

Node:

```bash
sudo install -m 600 /tmp/results_key /etc/greensql/results_key
sudo cat /tmp/results_key | sudo -u geniuser sh -c 'umask 077; mkdir -p /proj/<project>/greensql/.deploy && cat > /proj/<project>/greensql/.deploy/results_key'
rm /tmp/results_key
sudo greensql-push-results                   # must print "pushed <experiment>/<node>-..."
```

Every later node copies the key from `/proj` during setup. Without `/proj`, do
the first two lines (scp + install) on each new node.

### Hardware check (node)

```bash
ls /sys/class/powercap                       # intel-rapl:0 (package), intel-rapl:0:0 (DRAM)
paste <(cat /sys/class/thermal/thermal_zone*/type) <(cat /sys/class/thermal/thermal_zone*/temp)
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
```

`x86_pkg_temp` is the CPU package in milli-°C (44000 = 44 °C); the compare
test only starts an entry between 40 and 60 °C, so an idle package far outside
that window means long waits. `performance` must be among the governors.

## The compare test

`compare/run_compare.sh` runs the fixed 54-query StackOverflow set, 6 rounds
(324 entries) as a (1,16) warm step-up, and ends with a protocol check. It uses
`PGVER` and `CLOCK_KHZ` from the login shell (the profile's values).

Smoke test, ~4 min, must end in `CHECK OK` (node):

```bash
cd ~/GreenSQL && ENTRIES=6 bash compare/run_compare.sh smoke
```

Full session, ~3.4 h on an m510; survives logging out (node):

```bash
cd ~/GreenSQL && setsid nohup bash run/detach.sh logs/compare/console_s1.log bash compare/run_compare.sh s1 > /dev/null 2>&1 < /dev/null &
tail -f ~/GreenSQL/logs/compare/console_s1.log
tail -3 ~/GreenSQL/logs/compare/console_s1.log      # a quick look later
```

Override per run if needed: `CLOCK_KHZ=2500000`, `PGVER=18` (needs that
cluster and its database), `T_LO`/`T_HI` are fixed at 40/60 in the script.
Results: `logs/compare/warm_stepup/compare_node0_pg16_s1_<stamp>/`.

Other benchmarks work the same way, e.g.

```bash
cd ~/GreenSQL && setsid nohup bash run/detach.sh logs/so_full/console.log \
    make warm-stepup DB_NAME=stackoverflow_1gb DIR=queries/stackoverflow/SQLStorm \
    WARMUP=2 STATEMENT_TIMEOUT=15 WARMUP_FAIL_SKIP=1 THERMAL_EQUALISE=1 T_LO=40 T_HI=60 \
    FIX_CLOCK=1 CLOCK_MAX_KHZ=$CLOCK_KHZ > /dev/null 2>&1 < /dev/null &
```

## Finishing

1. The console ends with `CHECK OK`, then `===== greensql-save-logs` and
   `===== greensql-push-results ... pushed` (detach.sh does both).
2. GitHub shows `<experiment>/<node>-<id>/logs/...` in CloudLab-Results. In
   doubt, once more: `sudo greensql-push-results`.
3. Only then terminate the experiment (portal), or extend it to keep working.

Getting the results onto a laptop (any machine with access to the private repo):

```bash
git clone git@github.com:GreenSQL-RUC/CloudLab-Results.git    # first time
git -C CloudLab-Results pull                                  # later
```

Straight from a running node instead (desktop):

```powershell
scp -r -i "$env:USERPROFILE\.ssh\id_cloudlab" <you>@<node>:/mydata/GreenSQL/logs/compare .
```

## Where things are on a node

| Path | What |
|---|---|
| `/mydata/GreenSQL` (= `~/GreenSQL`) | the repository clone; runs write to its `logs/` |
| `/mydata/greensql_setup.log`, `_save.log`, `_push.log` | setup, `/proj` copies, GitHub pushes |
| `/mydata/node_info.txt` | CPU, microcode, BIOS, kernel, RAPL zones |
| `/etc/greensql.conf` | user, project share, results folder, results repo |
| `/etc/profile.d/greensql.sh` | the exported `PGVER`, `SHARED_BUFFERS`, `EFFECTIVE_CACHE_SIZE`, `CLOCK_KHZ` |
| `/etc/cron.d/greensql-save-logs`, `greensql-push-results` | the schedules |
| `/usr/local/bin/greensql-save-logs`, `greensql-push-results`, `greensql-new-logs` | the copy commands (the last lists the node-made logs) |
| `/proj/<project>/greensql/<experiment>/<node>-<id>/` | the persistent copy |

## Troubleshooting

**`Permission denied (publickey)`.** The node is not ready yet (wait for
**ready**), or it does not have your key: CloudLab copies keys at experiment
start. Check which key ssh offers:

```powershell
ssh -v -i "$env:USERPROFILE\.ssh\id_cloudlab" <you>@<node> 2>&1 | Select-String "Offering|Authentications|denied"
```

To add a key to a running node, open its browser shell: experiment page →
**List View** → the node's gear menu → **Shell** (not *Console*). The browser
shell cannot paste, so type the key and then compare fingerprints (node, then
desktop); they must be identical:

```bash
echo "ssh-ed25519 AAAA...rest of the key..." >> ~/.ssh/authorized_keys
ssh-keygen -lf <(tail -1 ~/.ssh/authorized_keys)
```

```powershell
ssh-keygen -lf "$env:USERPROFILE\.ssh\id_cloudlab.pub"
```

Typing traps: `0` vs `O`, `1` vs `l` vs `I`, and capital letters. Fix one
character in place with `sed -i 's/<wrong part>/<right part>/' ~/.ssh/authorized_keys`,
or drop the last line with `sed -i '$d' ~/.ssh/authorized_keys` and type it again.

**ssh asks for a passphrase.** The private key has one. Remove it if you know it
(`ssh-keygen -p -f <key>`, then Enter twice), or make a new key as in step 1.

**Setup failed.** `tail -40 /mydata/greensql_setup.log` names the step. A
`pinned minor ... is not in the apt repo` means PostgreSQL's repository dropped
that minor: bump `PIN_MINOR` in `build/bootstrap_ubuntu.sh`, push, start a new
experiment. To rerun setup on the same node: `sudo rm /mydata/greensql_setup.done`
and reboot it from the portal.

**`CHECK FAILED: scaling_max_khz not always ...`.** The clock did not reach
`CLOCK_KHZ`. Above the CPU's base frequency it needs turbo; at or below it,
turbo is switched off. Look at the `clock_control:` lines at the start of the
run and set `CLOCK_KHZ` to a value the hardware took.

**Every entry waits at the thermal gate** (`thermal gate: waited ...` or
`pre-heated ...` on each one). The node idles outside 40–60 °C; tell whoever
analyses the run, or adjust `T_LO`/`T_HI` in `compare/run_compare.sh` for that
node type before the session.

**`no deploy key at /etc/greensql/results_key`.** Do the first-experiment key
step. **`not pushed after 5 attempts`** with an ssh error: check the key is a
*write* deploy key on CloudLab-Results; the logs are still on the node and in
`/proj`.

**`no /proj share mounted`.** Only GitHub copies exist then: install the deploy
key on the node (scp + install above) and keep `Push results every` on.

**Repository or `/proj` folder owned by `geniuser`** (nodes set up before the
fix): `sudo chown -R <you>: /mydata/GreenSQL`; the `/proj` files are fine as
they are.
