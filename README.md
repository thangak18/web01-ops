# web01 Operations Toolkit

This project implements the four homework tasks: health monitoring, verified rotating backups, precise error trapping, and cron scheduling.

## 1. Prepare the Linux VM

```bash
mkdir -p ~/web01-data ~/logs
echo "hello from web01" > ~/web01-data/index.html
cd ~/web01-data
python3 -m http.server 8080 &
```

For the local backup fallback:

```bash
sudo mkdir -p /srv/backup-target
sudo chown "$USER":"$USER" /srv/backup-target
```

## 2. Install the project and configs

```bash
sudo cp -a web01-ops /opt/web01-ops
sudo chmod +x /opt/web01-ops/*.sh
sudo touch /var/log/web01-alerts.log /var/log/web01-health.log /var/log/web01-backup.log
sudo chmod 640 /var/log/web01-alerts.log /var/log/web01-health.log /var/log/web01-backup.log

sudo cp /opt/web01-ops/examples/monitoring.env.example /etc/monitoring.env
sudo cp /opt/web01-ops/examples/backup.env.example /etc/backup.env
sudo chown root:root /etc/monitoring.env /etc/backup.env
sudo chmod 600 /etc/monitoring.env /etc/backup.env
sudo nano /etc/monitoring.env
sudo nano /etc/backup.env
```

Do not commit the real `/etc/*.env` files. Only commit the examples.

## 3. Email choice

The examples use `MAIL_MODE="log"`, which writes observable email messages to `/var/log/web01-alerts.log`. This satisfies the no-SMTP fallback. For real email, configure `msmtp` or `mail`, then set `MAIL_MODE="msmtp"` or `MAIL_MODE="mail"`.

The absolute log path also avoids cron changing `$HOME` when the job runs as root.

## 4. Run manually

```bash
sudo /opt/web01-ops/health-check.sh
sudo /opt/web01-ops/backup.sh
sudo /opt/web01-ops/restore-test.sh
```

A healthy health check intentionally prints nothing and sends nothing.

## 5. Demonstrate each failure

### Health alert

Temporarily set `DISK_THRESHOLD=1` in `/etc/monitoring.env`, or stop the Python endpoint. Run the health check and inspect the mail log. Restore the threshold afterward.

```bash
pkill -f 'python3 -m http.server 8080' || true
sudo /opt/web01-ops/health-check.sh || true
sudo tail -n 30 /var/log/web01-alerts.log
```

### Backup cleanup failure

Temporarily set `DATA_DIR=/no/such/path`, run `backup.sh`, and capture the failure alert. The temporary directory under `/tmp/web01-backup.*` should be absent afterward.

```bash
sudo /opt/web01-ops/backup.sh || true
ls -d /tmp/web01-backup.* 2>/dev/null || echo "temporary directory cleaned"
```

### Task 3 precise ERR trap

Set `FORCE_FAILURE=true` in `/etc/backup.env`. The script runs a real failing `tar` command. The alert includes hostname, line, exact command, and exit code. The line after the fault must not appear. Restore `FORCE_FAILURE=false` afterward.

## 6. ShellCheck

```bash
shellcheck /opt/web01-ops/*.sh
```

Expected clean output: no text and exit code `0`.

## 7. Install cron

```bash
sudo cp /opt/web01-ops/cron/web01-ops.cron /etc/cron.d/web01-ops
sudo chmod 644 /etc/cron.d/web01-ops
sudo systemctl restart cron  # Ubuntu
# sudo systemctl restart crond  # CentOS Stream
```

For the one-minute demonstration, temporarily change `*/5` to `*/1`, observe `/var/log/web01-health.log`, then restore `*/5`.

## 8. Why cron can fail when manual execution works

Cron has a smaller `PATH`, a different working directory, a different user and `$HOME`, no interactive shell profile, and potentially different permissions. This project addresses that by using absolute project paths, defining `PATH` in the cron file, sourcing `/etc/*.env`, and redirecting output to dedicated logs.
