# AWS Offsite Backup Setup — S3 Glacier Deep Archive

The offsite target for both backup legs (`BACKUP_REMOTE` and `BACKUP_NEXTCLOUD_REMOTE`)
is one S3 bucket with every object in **Glacier Deep Archive**. Cheapest storage AWS
sells (~$1/TB-month); the accepted cost is that **every restore starts with a 12–48 hour
thaw** — see [decisions.md](decisions.md#the-offsite-target-is-aws-s3-glacier-deep-archive)
for why that trade was taken, and
[disaster-recovery.md](disaster-recovery.md) for the restore procedures that account
for it.

What this guide builds:

- One bucket, two prefixes: `appdata/` (weekly archive sets) and `nextcloud/`
  (user files + db dumps). Same storage class, so one bucket is enough.
- **Versioning on, with a 30-day noncurrent expiry** — an overwrite never destroys
  the previous copy immediately.
- **An IAM user that cannot delete** — the box's credentials can write and read but
  not destroy. A compromised box (the downloaders are internet-facing) cannot take
  the backups with it. Combined with versioning, even a malicious overwrite is
  recoverable for 30 days.
- An rclone remote named `aws` with `storage_class = DEEP_ARCHIVE` baked in, so
  `backup-appdata.sh` needs no changes at all.

Nothing here touches the stack. The only on-box artifacts are the rclone config and
two `.env` lines.

---

## Step 1 — Account hygiene (once, if the account is new)

1. Sign in at <https://aws.amazon.com/> (create the account if needed).
2. **Enable MFA on the root user** (IAM → root user security credentials). This
   account will hold the only copy of irreplaceable files; treat it accordingly.
3. Never create access keys for the root user. Step 4 makes a scoped user instead.
4. Optional but recommended: Billing → Budgets → create a $5/month budget with an
   email alert. Normal spend here is under $1/month; an alert firing means
   something is wrong (usually an unintended restore or a runaway upload).

## Step 2 — Create the bucket

Console → S3 → **Create bucket**:

| Setting | Value |
|---------|-------|
| Bucket name | Globally unique — e.g. `dellbox-offsite-<random>`. Record it; it appears in every command below as `BUCKET`. |
| Region | Pick the nearest one and never move (e.g. `us-west-2`). Cross-region transfer costs money; there is no reason for these bytes to change region. |
| Object Ownership | ACLs disabled (default) |
| Block Public Access | **All four on** (default) — verify, don't assume |
| Bucket Versioning | **Enable** — this is the overwrite protection the no-delete IAM policy relies on |
| Default encryption | SSE-S3 (default) |

Do **not** set a bucket-level default storage class or an
"intelligent tiering" configuration — the storage class is set per-upload by
rclone (Step 5), which is explicit and survives bucket-setting drift.

## Step 3 — Lifecycle rules

Bucket → Management → **Create lifecycle rule**, twice:

1. **`abort-incomplete-multipart`** — scope: entire bucket → "Delete expired object
   delete markers or incomplete multipart uploads" → abort incomplete multipart
   uploads after **7 days**. The Nextcloud leg moves large files over a home
   connection that only has to blink once; without this rule, every interrupted
   multipart upload leaves invisible parts that are billed forever and appear in
   no listing.
2. **`expire-noncurrent-30d`** — scope: entire bucket → "Permanently delete
   noncurrent versions of objects" after **30 days**, keep 0 newer versions.
   Versioning exists to survive a bad overwrite, not to keep history forever —
   30 days is the window to notice.

## Step 4 — IAM policy and user

IAM → Policies → **Create policy** → JSON (replace `BUCKET`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BucketList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::BUCKET"
    },
    {
      "Sid": "ObjectWriteReadRestore",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:RestoreObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::BUCKET/*"
    }
  ]
}
```

Name it `dellbox-backup-writer`. What is deliberately **absent**:

- **`s3:DeleteObject`** — the box cannot destroy backups, by construction. Pruning
  the remote (which `backup-appdata.sh` never does — `rclone copy` only grows it)
  is done from the console with your admin login, deliberately.
- **`s3:CreateBucket`** — rclone's remote config sets `no_check_bucket = true`
  (Step 5) so it never tries.
- Any `s3:*Version*` action — the box can't reach into version history either;
  recovering an overwritten version is a console operation.

Then IAM → Users → **Create user**:

- Name: `dellbox-backup` · no console access
- Attach `dellbox-backup-writer` directly
- After creation: Security credentials → **Create access key** → "Application
  running outside AWS" → record the key ID and secret (the secret is shown once)

## Step 5 — rclone remote on the box

rclone is already installed (`/usr/bin/rclone`). First confirm the config file
lives somewhere that **survives a reboot** — `/root` does not on Unraid:

```bash
rclone config file
```

If it prints a path under `/root/.config`, point rclone at flash-backed storage
instead and use `--config` consistently, or (better, with the rclone plugin) it
already reports `/boot/config/plugins/rclone/.rclone.conf` — that persists.

Add the remote non-interactively (replace region and keys):

```bash
rclone config create aws s3 \
    provider=AWS \
    region=us-west-2 \
    access_key_id=AKIA... \
    secret_access_key=... \
    storage_class=DEEP_ARCHIVE \
    no_check_bucket=true
```

The two settings that are not boilerplate:

- **`storage_class=DEEP_ARCHIVE`** — every upload through this remote lands cold.
  Baked into the remote so `backup-appdata.sh` needs no flags and can never
  accidentally upload at Standard rates.
- **`no_check_bucket=true`** — the IAM user can't create buckets, so rclone must
  not try; without this, restricted credentials produce a confusing `AccessDenied`
  on the first copy.

Smoke test (uploads land as Deep Archive; **listing works instantly** — only
*content* reads need a thaw):

```bash
echo "$(date) dellbox smoke test" > /tmp/smoke.txt
rclone copy /tmp/smoke.txt aws:BUCKET/smoke/
rclone ls aws:BUCKET/smoke/
rclone lsjson aws:BUCKET/smoke/ | grep -i tier      # expect DEEP_ARCHIVE
```

A `rclone cat aws:BUCKET/smoke/smoke.txt` failing with `InvalidObjectState` is
**correct behaviour** — that's Deep Archive refusing an unthawed read, and seeing
it once now is worth it so it isn't a surprise during a disaster.

## Step 6 — Wire up `.env` and prove the run

In `homeserver/.env`:

```
BACKUP_REMOTE=aws:BUCKET/appdata
BACKUP_NEXTCLOUD_REMOTE=aws:BUCKET/nextcloud
```

Run the backup once by hand rather than waiting for Sunday:

```bash
bash /mnt/user/appdata/homeserver/homeserver/scripts/backup-appdata.sh
docker exec -u www-data nextcloud php occ status   # maintenance: false
```

Watch the log for the two offsite lines (`Syncing ... → aws:...`), then verify
from the other end:

```bash
rclone ls aws:BUCKET/appdata | tail
rclone ls aws:BUCKET/nextcloud/db | tail
```

The first Nextcloud file sync is the big one (every byte in `/mnt/user/nextcloud`).
Subsequent weekly runs only upload new/changed files.

## Step 7 — Ongoing

- **Next Monday**: check `/var/log/homeserver/backup.log` for a clean scheduled
  run — this closes the TODOS.md item.
- **Quarterly** (already in [operations.md](operations.md#maintenance-schedule)):
  `rclone ls $BACKUP_NEXTCLOUD_REMOTE | tail` — listing is a metadata operation
  and needs no thaw.
- **Once a year**: thaw and pull back one real file end-to-end
  ([disaster-recovery.md](disaster-recovery.md#user-file-restore) has the
  procedure). An unverified backup of irreplaceable files is not a backup, and
  with Deep Archive the *restore path itself* is the part most likely to rust.

---

## Restore reality (read before you need it)

Deep Archive objects cannot be read until restored ("thawed") into a temporary
readable copy. There is **no expedited tier** for Deep Archive:

| Priority | Ready within | Retrieval cost |
|----------|-------------|----------------|
| `Standard` | ~12 h | ~$0.02/GB |
| `Bulk` | ~48 h | ~$0.0025/GB |

```bash
# Thaw a whole prefix (lifetime = days the thawed copy stays readable)
rclone backend restore aws:BUCKET/nextcloud -o priority=Standard -o lifetime=7

# Check progress — done when objects stop reporting an in-progress restore
rclone backend restore-status aws:BUCKET/nextcloud

# Only THEN does the copy in disaster-recovery.md work
rclone copy aws:BUCKET/nextcloud /mnt/user/nextcloud --progress
```

For a single accidentally-deleted file, thaw just its path — same commands with
the full object path instead of the prefix.

Egress to the internet is ~$0.09/GB after the monthly free allowance, so a full
disaster restore of several hundred GB costs real money (~$40–50 at 500 GB).
That is the deal: the insurance premium is under $1/month, and the deductible is
two days and fifty dollars, paid only if the house burns down.
