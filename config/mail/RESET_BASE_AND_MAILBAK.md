# Reset to Base + Mail.bak Merge

## Reset a server back to Base (best effort)

If the wrong role was provisioned, run:

```bash
cd /opt/ae_provisioning
SERVER_ROLE=ResetBase sudo ./provision.sh
```

What this does:
- Stops/disables host `apache2` and host `nginx`
- Stops Mailcow stack (if present)
- Removes role cron files: `/etc/cron.d/mail-maint`, `/etc/cron.d/backup-maint`
- Unmounts known web bind mounts (`/home`, `/opt/standalone`) when they came from `/mnt/web/*`
- Removes those bind lines from `/etc/fstab`
- Sets ops-monitor role to `base`

## Re-apply Mail role cleanly

```bash
cd /opt/ae_provisioning
SERVER_ROLE=Mail sudo ./provision.sh
```

## Merge `Mail.bak` before deleting it

The merge helper is installed as `/usr/local/bin/merge_mail_bak.sh` by Mail role.

Default paths:
- source: `/mnt/Mail.bak`
- target: `/mnt/Mail`

Run:

```bash
sudo /usr/local/bin/merge_mail_bak.sh
```

The script:
- shows a dry-run first
- asks for confirmation
- rsyncs without `--delete` (safe merge)
- reapplies Mailcow ownership (`5000:5000`)

After verifying mailboxes are present and client access works, you can archive or delete `/mnt/Mail.bak`.
