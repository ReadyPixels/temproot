# Security

temproot creates a root-equivalent account on purpose. This page says what the script does
to keep that safe, what it deliberately doesn't do, and what you should do on your side.

## What the script does

- **Runs only as root.** It refuses otherwise.
- **Refuses to schedule itself from an unsafe file.** The cron sweeper and the `at` job
  run the script as root later, so if anyone else could edit the file they'd get root.
  Create won't proceed unless the script is owned by root and not writable by group or
  others.
- **Only purges names it generated.** `--purge` accepts `tadmin_` plus six lowercase
  alphanumerics and nothing else, so it can never be pointed at `root`, `..` or a real
  account.
- **Random credentials.** A 32-character password from `/dev/urandom` and a 4096-bit RSA
  key with its own passphrase.
- **Three layers of expiry.** An `at` job at the exact minute, a cron sweeper every five
  minutes that survives reboots, and a `chage -E` hard lock the day after as a backstop.
- **Full wipe on purge.** Processes killed, sudoers drop-in removed, group membership
  removed, user and home deleted, session folder and archives deleted, scheduler entries
  removed.
- **Restrictive permissions on everything it writes.** Session folders are mode 700 under
  `/root`, credential files and archives are mode 600.
- **No secrets in logs.** `/var/log/temproot.log` records usernames, times and the server
  address. Never a password or passphrase.

## What it deliberately doesn't do

These are trade-offs, not oversights. Know them before you hand a bundle to someone.

- **The bundle contains everything.** Private key, its passphrase and the account password
  travel together in one archive. That's convenient for the recipient and means the
  archive itself is the secret. Treat it like a root password: send it over a channel you
  trust, and delete it when the session ends.
- **sudo is passwordless.** The recipient runs `sudo -i` and is root. There's no second
  factor beyond the SSH credential.
- **Password login over SSH works** for the account unless your `sshd_config` already
  disables it. If you want key-only access, set `PasswordAuthentication no` on the server.
- **The optional zip uses classic zip encryption**, which is weak. Prefer the `.tar.gz`
  and protect it in transit.

## What you should do

- Keep the script somewhere root-owned, such as `/usr/local/sbin/`, with mode 755.
- Send the archive through an encrypted channel, not email.
- Download the archive and then delete it from the server if you don't need it there.
- Run `--list` occasionally. A session that shows EXPIRED but still exists means the
  sweeper isn't running. Check `crontab -l` for the `TEMPROOT_SWEEP` line.
- Purge early with `--purge <user>` the moment the work is done. Don't wait for expiry.

## Reporting a problem

If you find something that lets a temproot account outlive its expiry, escape its sudo
scope, or expose a credential it shouldn't, open an issue with the script version and
the distribution you ran it on. Don't include real credentials or server addresses.
