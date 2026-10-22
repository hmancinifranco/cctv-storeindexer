# Synthetic fixtures & demo upload

**Last reviewed:** 2026-10-22

Because the customer has no sample recordings yet, this folder produces a
synthetic set of files whose **names** emulate the prototype filename grammar
(assumption A1) and uploads them to the demo S3 bucket so the ingestion →
indexing → search → download pipeline can be demonstrated end-to-end.

The upload uses `aws s3 sync` — the same transfer mechanism used by the PoC uploader (design §2) — so the demo exercises the cloud ingestion path with synthetic content. Production credentials and scheduling remain separate decisions.

## Contents

| File | Purpose |
|------|---------|
| `generate_fixtures.py` | Generates placeholder files + `manifest.json` (expected parse result per file). Committed. |
| `manifest.json` | Canonical fixture consumed by indexer/parser tests (T3.3). Committed. |
| `upload_to_s3.sh` | Syncs the set to `s3://$VIDEO_BUCKET_NAME/$prefix/` using the `.env` profile. |
| `out/` | Generated placeholder files. **Git-ignored** (regenerable). |

## Fixture coverage

19 entries — 5 valid, 4 edge, 10 malformed:

- **Valid:** 3 cameras, 2 days, with/without end time, `.mp4/.avi/.mkv`.
- **Edge (must parse OK):** midnight start, recording crossing midnight, multi-digit camera id, re-recording name collision (tests indexer idempotency).
- **Malformed (must be cataloged `INVALID_METADATA`, never dropped):** missing time, missing camera, wrong date/time format, lowercase prefix, spaces, disallowed extension, accented prefix, impossible month/hour.

The grammar (A1, editable/versioned in the real parser):

```
CAM<id>_YYYYMMDD_HHMMSS[-HHMMSS].<ext>   local time UTC-3, no DST
example: CAM07_20260923_142530-142959.mp4
```

## Prerequisites

1. AWS CLI v2 and `python3` installed.
2. Credentials for the demo profile available (e.g. `aws sso login --profile "$AWS_PROFILE"`).
3. The storage stack deployed and `VIDEO_BUCKET_NAME` set in the repo-root `.env`
   (see `.env.example`). Optional `INGEST_PREFIX` (default `videos`).

## Procedure

```bash
cd uploader/synthetic

# 1. Generate the set (also runs automatically if out/ is empty)
python3 generate_fixtures.py

# 2. Preview what would upload (no writes)
./upload_to_s3.sh --dry-run

# 3. Upload for real (reads AWS_PROFILE / AWS_REGION / VIDEO_BUCKET_NAME from .env)
./upload_to_s3.sh

# Optional: custom prefix
./upload_to_s3.sh --prefix demo-set
```

Each uploaded object triggers `S3 ObjectCreated → EventBridge → SQS → indexer
Lambda → DynamoDB` (design §3). After the sync:

- Valid names appear as searchable catalog entries.
- Malformed names are cataloged `INVALID_METADATA` and raise the invalid-filename metric.
- Re-running the sync uploads nothing new (idempotent transfer) and creates no duplicate catalog entries (idempotent indexer).

## Safety notes

- The script never hardcodes account values; it reads them from the git-ignored `.env`.
- It refuses to run if `VIDEO_BUCKET_NAME` is empty or the bucket is unreachable with the profile.
- Placeholder files are a few hundred bytes — no real video content.
- To clean up, empty the prefix: `aws s3 rm "s3://$VIDEO_BUCKET_NAME/videos/" --recursive --profile "$AWS_PROFILE"` (destructive; scope to the demo prefix).
