# Backblaze B2 Setup for Cloud Backup Sync

This guide walks you through setting up Backblaze B2 as the offsite backup destination for `sync_to_cloud.sh`.

## Prerequisites

- rclone installed (provisioning installs it automatically)
- Backup admin user (e.g. `gabe`) on the backup server

---

## Step 1: Create a Backblaze B2 Account

1. Go to [backblaze.com/b2](https://www.backblaze.com/b2/cloud-storage.html)
2. Sign up or log in
3. Open **B2 Cloud Storage** from the dashboard

---

## Step 2: Create a Bucket

1. Click **Buckets** → **Create a Bucket**
2. **Bucket Name**: e.g. `ae-provisioning-backups` (must be globally unique)
3. **Files in Bucket**: **Private** (recommended for backups)
4. **Default Encryption**: enabled (recommended)
5. Click **Create a Bucket**

---

## Step 3: Create an Application Key

1. Go to **App Keys** in the left sidebar
2. Click **Add a New Application Key**
3. **Name of Key**: e.g. `backup-server-rclone`
4. **Allow List All Bucket Names**: optional (can restrict to specific bucket)
5. **Allow List Bucket Files**: Yes
6. **Allow Read**: Yes
7. **Allow Write**: Yes
8. **Allow Delete**: optional (needed if you want rclone to prune old files)
9. Click **Create New Key**
10. **Save the `keyID` and `applicationKey`** — the application key is shown only once.

---

## Step 4: Configure rclone on the Backup Server

SSH into the backup server as the backup admin user and run:

```bash
rclone config
```

Then:

1. **n** (New remote)
2. **name>** `b2backup` (or any name you prefer)
3. **Storage>** `b2` (Backblaze B2)
4. **account** or **env_auth>** Leave blank and press Enter
5. **key_id>** Paste your Application Key ID
6. **key>** Paste your Application Key
7. **hard_delete>** `false` (use B2 lifecycle for deletes)
8. **versions>** `false` (unless you need versioning)
9. **Confirm** `y`
10. **q** (Quit)

---

## Step 5: Create remote.conf

```bash
sudo cp /mnt/Backups/remote.conf.example /mnt/Backups/remote.conf
# Or if provisioning already created it, just edit:
sudo nano /mnt/Backups/remote.conf
```

Set:

```bash
RCLONE_REMOTE="b2backup:ae-provisioning-backups/backups"
```

Replace:
- `b2backup` — your rclone remote name from Step 4
- `ae-provisioning-backups` — your B2 bucket name
- `backups` — path prefix inside the bucket (optional)

Fix ownership so the backup user can read it:

```bash
sudo chown gabe:gabe /mnt/Backups/remote.conf
```

---

## Step 6: Test the Sync

```bash
# Dry run (no uploads, just show what would happen)
rclone sync /mnt/Backups b2backup:ae-provisioning-backups/backups --dry-run -v

# Actual sync
/mnt/Backups/scripts/sync_to_cloud.sh
```

Check logs: `/mnt/Backups/logs/cloud_sync_*.log`

---

## Step 7: Scheduled Sync

If the backup role is provisioned, cron runs `sync_to_cloud.sh` nightly at 5:15 AM. Verify:

```bash
cat /etc/cron.d/backup-maint
```

---

## Cost Estimate (B2 Pricing)

- **Storage**: ~$0.006/GB/month ($6/TB)
- **Egress**: Free up to 3× your stored data per month

For ~27 GB: ~$0.16/month for storage.

---

## Troubleshooting

| Problem | Solution |
|--------|----------|
| `rclone: command not found` | Run provisioning, or `apt-get install rclone` |
| `Authentication failed` | Verify key_id and application_key; create a new key if needed |
| `Permission denied` on remote.conf | `chown gabe:gabe /mnt/Backups/remote.conf` |
| Sync skipped | Ensure `RCLONE_REMOTE` is set and not the placeholder value |
