# temproot

Single bash script (`temproot.sh`) that creates a time-limited sudo account on a Linux server
and schedules its own removal. Must run as root on the target server.

## Testing locally with WSL

WSL Ubuntu 24.04 is available on this machine and is the test bed. Run it as root
(no password needed): `wsl.exe -u root -e bash -c '...'`.

Facts about the WSL box that matter for tests:

- `cron` is installed and active. `at` / `atd` are NOT installed, so creating a
  session exercises the "atd missing, rely on cron sweeper" path.
- `systemd` IS present on this box (`/run/systemd/system` exists, `systemctl` and
  `systemd-run` both work), so the optional systemd timer layer can be tested for real
  here, not just reviewed by reading the code. Don't assume every WSL box has this,
  check `/run/systemd/system` before relying on it.
- User-management tools (`useradd`, `userdel`, `chage`, `gpasswd`) live in
  `/usr/sbin`. Cron's default PATH is `/usr/bin:/bin`, so any scheduled test must
  reproduce that: `env -i PATH=/usr/bin:/bin HOME=/root bash /tmp/temproot.sh --sweep`.
  `systemctl` lives under `/usr/bin` or `/bin`, so it's reachable under that same
  restricted PATH without extra work.
- WSL clock/timezone differs from Windows (shows EEST). Do not compare times
  across the two.

Standard test loop (all inside WSL as root):

1. `cp /mnt/d/Projects/temproot/temproot.sh /tmp/temproot.sh` and lower
   `EXPIRE_HOURS` with sed. Never run the script from `/mnt/d` because
   `realpath "$0"` bakes that path into the cron line. After copying run
   `chown root:root /tmp/temproot.sh && chmod 755 /tmp/temproot.sh`, otherwise
   `--create` refuses (it checks the script is root-owned and not writable by others).
2. Back up root's crontab first: `crontab -l > /tmp/crontab.bak`.
3. `timeout 60 bash /tmp/temproot.sh --create </dev/null`
4. Inspect: `chage -l <user>`, `crontab -l | grep TEMPROOT`,
   `cat /root/.temproot_sessions/<user>/.meta`, and if systemd is present,
   `systemctl list-timers | grep temproot-<user>`.
5. Force expiry: `sed -i 's/^expires=.*/expires=1/' .../.meta`, then either run
   `--sweep` manually under the cron PATH, or wait up to 5 minutes for the real
   cron sweeper to fire (poll `id <user>`).
6. Clean up: purge any leftover `tadmin_*` users (`getent passwd | grep tadmin_`),
   remove `/etc/sudoers.d/temproot_*`, restore crontab, delete
   `/root/.temproot_sessions` and `/var/log/temproot*.log`, and confirm
   `systemctl list-units --all "temproot-*"` prints nothing.

Gotcha seen once: a sweep that exits without purging leaves the Linux user behind
even after the session folder is deleted. Always run the residue check in step 6.

## Lessons from the 2026-09-17 debugging session

These are the mistakes that produced "expires early" and "stays on server" reports. Check
each one before changing anything that touches scheduling, users, or cleanup.

- **Read the man page for date-taking commands.** `chage -E` accepts a date, not a
  time, and locks at 00:00 of that day. Any tool that takes a date where you mean a
  timestamp will round in a direction you didn't choose. Simulate the arithmetic with
  `date -d` for several start times and durations before trusting it.
- **Every scheduled command runs in a different environment.** Cron's PATH is
  `/usr/bin:/bin`, it has no TTY, no user env, and no `HOME` guarantee. Test anything cron
  will run with `env -i PATH=/usr/bin:/bin HOME=/root bash script`. `at` copies the
  submitting shell's environment, so it can pass where cron fails.
- **`|| true` hides the bug you're looking for.** When every line in a function swallows
  its error, the function reports success no matter what. After a destructive step, check
  the state (`id user`, `ls file`) rather than the exit code.
- **Checking a binary exists is not checking the service runs.** `command -v at` passes
  on a box where `atd` is stopped, and `at` still queues the job. Check `pgrep -x atd` or
  `systemctl is-active`.
- **One-shot schedules miss.** A cron line for a single minute is lost if the box is off
  at that minute. A periodic sweeper that reads stored state is the reliable shape.
- **Anything you `source` is code.** Quote values, or better, parse them.
- **Validate names before `rm -rf` and `userdel`.** A purge that takes a free-form
  username can be handed `..` or `root`. Match against the exact pattern you generate.
  The same discipline applies to the systemd unit name: it's built from the same
  validated username, never taken as free-form input.
- **A root cron job that runs a file makes that file's permissions a security boundary.**
  Refuse to schedule from a file that isn't root-owned and 755 or tighter.
- **Test residue, not just output.** The first WSL sweep printed nothing and left a user
  behind, and the only reason it was noticed was a `getent passwd | grep tadmin_` check
  afterward. Always finish a test with a residue check.
- **When a test fails once and passes on rerun, say so.** Don't quietly move on. Write
  it in the notes with what was checked, so the next person knows it's an open question.

## Security docs

- `SECURITY.md` is public: what the script protects, the trade-offs, what users should
  do. Safe to commit.
- `SECURITY-PRIVATE.md` is the owner's decision list with recommendations and tick boxes.
  It is in `.gitignore` and must never be committed or quoted in public docs. When the
  owner decides an item, apply the change to the script and tick the box there.

## Screenshots and README images

- The block-character banner (█ ╗ ║) deforms in some fonts, so the README uses PNGs
  under `assets/` instead of a code block. The script keeps the block banner.
- Screenshots and tutorial images are real captures from WSL runs. Use the
  tutorial-creator skill to produce them. Never describe the capture tooling in the
  README, the tutorial, or any other project document.
- Every image must be masked before it lands in the repo: password, passphrase, zip
  password, IP, port, hostname, generated username suffix, timezone. Check each image by
  eye after every rerender.
- Purge the test session right after capture and run the residue check.

## Timing design (do not regress)

- `chage -E` takes a date and locks at 00:00 of that day. The script therefore
  sets it to the day AFTER the intended expiry as a safety net only. Exact-time
  removal is done by `at` (when atd runs) plus the cron sweeper (`--sweep`,
  every 5 min, self-removing when no sessions remain).
- Never set `chage -M 1`. It forces a password change after one day and breaks
  sessions longer than 24h.
- The script exports a full PATH at the top so it works under cron.
- `.meta` values are single-quoted because the file is `source`d and
  `expire_time` contains spaces.
- **Fourth, optional layer: a systemd timer.** When `/run/systemd/system` exists
  (`systemd_available()`), `--create` also fires `systemd-run --unit=temproot-<user>
  --on-calendar=... --collect -- bash temproot.sh --purge <user>`, which creates a
  transient `temproot-<user>.timer` / `.service` pair. This is redundancy, not a new
  mechanism: it calls the same `--purge` path as `at` and the cron sweeper, and it's
  gated so hard on `systemd_available()` that a box with no systemd behaves exactly as
  it did before this layer existed. Don't make it required anywhere, don't let install
  or quick-start docs imply systemd is needed, and don't let its failure to install stop
  account creation. It only ever adds a `warn` line.
- **What the systemd layer buys you, and what it doesn't.** It buys `systemctl
  list-timers` and `journalctl` visibility on a box that already runs systemd, and it
  doesn't depend on `atd`. It does not close the gap this project has always been
  honest about: a malicious holder of root can `systemctl disable`, `systemctl mask`,
  or delete the unit file exactly as easily as they can edit a crontab or `atrm` a job.
  Say this plainly in any doc that mentions the systemd layer. Don't imply it's more
  secure than `at` or cron, because it isn't.
- **Purge and sweep must clean up the systemd unit too.** `purge_account()` calls
  `remove_systemd_timer()` unconditionally (it no-ops safely when there's nothing to
  remove, or when systemd isn't present), the same way it already touches the cron line
  and any `at` job. `--sweep` purges through the same function, so this is covered for
  free. The residue check in the WSL test loop must include
  `systemctl list-units --all "temproot-*"` printing nothing after a purge.
