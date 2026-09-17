# Machine migration: retiring -> replacing

Moves Claude Code state, claude-mem memory, and the `/data2` working tree to
the replacement machine. Plain bash + rsync + sqlite3; no extra dependencies.

## Files

| File | Purpose |
|---|---|
| `migrate.sh` | Phase driver. Start here. |
| `migrate.conf` | Target host, paths, dotfile and secret lists, JSON keys to strip. |
| `excludes-claude.txt` | Regenerable parts of `~/.claude`, plus the per-install identity marker. |
| `excludes-mem.txt` | Live SQLite files, snapshotted separately instead. |
| `excludes-code.txt` | Build artifacts and the large media/backup trees. |

## One-time setup

The target must accept this machine's SSH key without a password:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub stuart@media2026.local
```

## Running it

```bash
cd ~/migrate
./migrate.sh --dry-run all     # rehearse; transfers nothing
./migrate.sh all               # preflight, claude, mem, code, dotfiles, verify
```

Phases can be run individually and in any order:

```bash
./migrate.sh preflight         # connectivity, remote tools, disk space
./migrate.sh claude mem        # config, projects, skills, memory database
./migrate.sh code              # /data2 source
./migrate.sh verify            # file counts + remote DB integrity check
```

## Repeatability

Every phase is idempotent. rsync ships only changed blocks and nothing is
deleted on either side, so re-running after further work on the old machine
costs only the delta. The intended pattern is one full run now, then
`./migrate.sh claude mem code` again just before the old machine goes away.

## rsync exit codes 23 and 24

`/data2` is owned by `root` on both machines, so rsync cannot stamp the mtime
on the destination root and exits 23:

```
rsync: [generator] failed to set times on "/data2/.": Operation not permitted (1)
```

Nothing is actually wrong — every file and subdirectory inside transfers
correctly, and subdirectory times are preserved because those are owned by
`stuart`. `push()` therefore treats two specific cases as benign and keeps
going: an attribute failure on the **transfer root** (rsync writes that path
as `/.`, so a failure on a real subdirectory is still fatal) and a file that
vanished mid-run. Every other rsync error, including disk-full and permission
denied, still aborts the migration.

To silence the warning entirely, give `stuart` ownership of the destination
root on the target — optional, and it needs a sudo password:

```bash
ssh media2026 'sudo chown stuart:stuart /data2'
```

## Final cutover

`~/.claude/projects/.../<session>.jsonl` and `~/.claude-mem/supervisor.json`
are written continuously while Claude Code is running, so `verify` will always
show one or two pending items during an active session. That is expected.

For the last sync, quit Claude Code on this machine first, then:

```bash
cd ~/migrate && ./migrate.sh claude mem code && ./migrate.sh verify
```

`verify` should then report everything in sync.

## What gets excluded, and why

| Excluded | Size | Reason |
|---|---|---|
| `~/.claude/plugins/{cache,marketplaces}` | 3.4G | Reinstalled from the transferred manifests on first launch. |
| `target/`, `node_modules/`, `.venv/`, caches | ~82G | Rebuilt by cargo / npm / uv. |
| `backup062926`, `nacks`, `source_rips`, `vinyl_rips`, `music`, `pre-prep-music`, `backhome` | ~360G | Media and backup archives, not code. |

Result: **35.3G across 300,172 files**, down from 534G.

To bring a media tree along later, delete its line from `excludes-code.txt`
and re-run `./migrate.sh code`.

## Databases

`~/.claude-mem/claude-mem.db` and the two Chroma stores are live SQLite
databases in WAL mode; copying those files while the worker runs can yield an
unreadable database. The `mem` phase therefore stops the claude-mem worker and
its Chroma child, then uses `sqlite3 .backup` to write a consistent snapshot
with the WAL folded in, and integrity-checks it before and after transfer.
Both processes are respawned by the plugin on the next Claude Code session, so
there is nothing to restart manually.

Verified locally: 1618 observations, `integrity_check = ok`.

## Credentials

Two deliberate safeguards, because this is the part that bites:

1. **`machineID` is stripped** from `~/.claude.json`, and
   `~/.claude/.claude.json` is removed on the target. Both hold a per-install
   machine identity; letting the replacement generate its own avoids two
   machines reporting as one.
2. **Secrets are opt-in.** The default run strips `primaryApiKey` from
   `~/.claude.json` and skips SSH keys, `.netrc`, `.git-credentials`,
   `gh` tokens and AWS keys entirely. Account state and all 16 project
   histories still transfer; authenticate on the new machine with `/login`.

To carry credentials across instead:

```bash
./migrate.sh --with-secrets secrets    # SSH keys, git/gh/aws credentials, 0600
./migrate.sh --with-secrets claude     # also keeps primaryApiKey in the config
```

## After the migration

1. Install Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`
2. Start it once, run `/login`.
3. Check `/plugin` lists claude-mem, gopls-lsp, rust-analyzer-lsp,
   mattpocock-skills.
4. Rebuild artifacts per project as needed.

## Note on the 31 no-remote repositories

`/data2` holds 31 git repositories with no configured remote, and almost every
repository there has uncommitted changes. Several are multi-GB
(`rusty-discogs-tagger`, `foou`, `weathom_applet`, `nuachd`, `bcdown`). They
exist nowhere but this disk, so `git clone`-based recovery is not an option for
them; this is why the `code` phase copies working trees wholesale rather than
re-cloning from remotes.
