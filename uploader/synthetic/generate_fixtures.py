#!/usr/bin/env python3
"""Synthetic fixture generator for the Video Archive prototype.

Generates small placeholder files whose NAMES emulate the prototype filename
grammar (assumption A1) plus deliberate edge cases and malformed names, so the
ingestion/indexing pipeline can be exercised without real video content.

Grammar (A1, editable/versioned in the real parser):
    CAM<id>_YYYYMMDD_HHMMSS[-HHMMSS].<ext>
    local time America/Argentina/Buenos_Aires (UTC-3, no DST)
    example: CAM07_20260923_142530-142959.mp4

Content is irrelevant to indexing (metadata comes from the name), so each file
is a few bytes. A manifest.json records the expected parse outcome for every
file and is the canonical fixture consumed by indexer tests (task T3.3).

Usage:
    python3 generate_fixtures.py [--out OUT_DIR] [--size-bytes N]
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path

# Local recording timezone per A1: fixed UTC-3, no DST.
LOCAL_TZ = timezone(timedelta(hours=-3))

# Canonical grammar. The production parser keeps this externalized/versioned;
# it is duplicated here only so the fixture is self-contained.
GRAMMAR = re.compile(
    r"^CAM(?P<camera>\d+)_(?P<date>\d{8})_(?P<start>\d{6})"
    r"(?:-(?P<end>\d{6}))?\.(?P<ext>[A-Za-z0-9]+)$"
)
PARSER_VERSION = "v1"
ALLOWED_EXTENSIONS = {"mp4", "avi", "mkv"}


@dataclass
class FixtureEntry:
    """One generated file and its expected parse result."""

    filename: str
    category: str  # "valid" | "edge" | "invalid"
    expected_status: str  # "OK" | "INVALID_METADATA"
    reason: str  # empty for OK, else why it is invalid
    camera_id: str | None = None
    recorded_at_local: str | None = None
    recorded_at_utc: str | None = None
    ends_at_utc: str | None = None


def _to_utc_iso(date_yyyymmdd: str, time_hhmmss: str) -> str:
    """Convert a local YYYYMMDD/HHMMSS pair to a UTC ISO-8601 string."""
    local_dt = datetime.strptime(f"{date_yyyymmdd}{time_hhmmss}", "%Y%m%d%H%M%S").replace(
        tzinfo=LOCAL_TZ
    )
    return local_dt.astimezone(UTC).isoformat()


def _valid_entry(
    camera: str, date: str, start: str, ext: str, end: str | None = None
) -> FixtureEntry:
    """Build an expected-OK entry, deriving UTC from local time (A1)."""
    filename = (
        f"CAM{camera}_{date}_{start}-{end}.{ext}" if end else f"CAM{camera}_{date}_{start}.{ext}"
    )
    return FixtureEntry(
        filename=filename,
        category="valid",
        expected_status="OK",
        reason="",
        camera_id=camera,
        recorded_at_local=f"{date}T{start[:2]}:{start[2:4]}:{start[4:]}-03:00",
        recorded_at_utc=_to_utc_iso(date, start),
        ends_at_utc=_to_utc_iso(date, end) if end else None,
    )


def _invalid_entry(filename: str, reason: str, category: str = "invalid") -> FixtureEntry:
    """Build an expected-INVALID_METADATA entry."""
    return FixtureEntry(
        filename=filename,
        category=category,
        expected_status="INVALID_METADATA",
        reason=reason,
    )


def build_fixture_set() -> list[FixtureEntry]:
    """Return the full set: valid, edge, and malformed filenames."""
    entries: list[FixtureEntry] = []

    # --- Valid: 3 cameras across 2 days, with/without end time, varied ext ---
    entries.append(_valid_entry("01", "20260921", "080000", "mp4", "083000"))
    entries.append(_valid_entry("01", "20260921", "090000", "mp4"))
    entries.append(_valid_entry("02", "20260921", "142530", "avi", "142959"))
    entries.append(_valid_entry("07", "20260922", "235500", "mkv", "235959"))
    entries.append(_valid_entry("12", "20260922", "000000", "mp4", "001500"))

    # --- Edge cases that MUST still parse (category edge, status OK) ---
    # Midnight start.
    midnight = _valid_entry("03", "20260923", "000000", "mp4", "010000")
    midnight.category = "edge"
    entries.append(midnight)
    # Recording that crosses midnight (end < start on the clock).
    cross = _valid_entry("03", "20260923", "235000", "mp4", "001000")
    cross.category = "edge"
    entries.append(cross)
    # Multi-digit camera id.
    bigcam = _valid_entry("128", "20260923", "120000", "mp4", "121500")
    bigcam.category = "edge"
    entries.append(bigcam)
    # Re-recording collision: same camera/date/start as an earlier valid file.
    dup = _valid_entry("01", "20260921", "080000", "mp4", "083000")
    dup.category = "edge"
    entries.append(dup)

    # --- Malformed: MUST be cataloged INVALID_METADATA, never dropped ---
    entries.append(_invalid_entry("CAM01_20260921.mp4", "missing time component"))
    entries.append(_invalid_entry("CAM_20260921_080000.mp4", "missing camera id"))
    entries.append(_invalid_entry("CAM01_2026-09-21_080000.mp4", "date not YYYYMMDD"))
    entries.append(_invalid_entry("CAM01_20260921_8000.mp4", "time not HHMMSS"))
    entries.append(_invalid_entry("cam01_20260921_080000.mp4", "lowercase prefix / no CAM"))
    entries.append(_invalid_entry("CAM01 20260921 080000.mp4", "spaces instead of underscores"))
    entries.append(_invalid_entry("CAM01_20260921_080000.txt", "disallowed extension"))
    entries.append(_invalid_entry("CÁM01_20260921_080000.mp4", "accented / non-ASCII prefix"))
    entries.append(_invalid_entry("CAM01_20261301_080000.mp4", "impossible month 13"))
    entries.append(_invalid_entry("CAM01_20260921_250000.mp4", "impossible hour 25"))

    return entries


def validate_entry_against_grammar(entry: FixtureEntry) -> bool:
    """Cross-check: does the grammar+calendar agree with the expected status?

    Guards the fixture itself so a typo cannot silently mislabel a case.
    """
    match = GRAMMAR.match(entry.filename)
    calendar_ok = False
    if match and match.group("ext").lower() in ALLOWED_EXTENSIONS:
        try:
            datetime.strptime(f"{match.group('date')}{match.group('start')}", "%Y%m%d%H%M%S")
            if match.group("end"):
                datetime.strptime(f"{match.group('date')}{match.group('end')}", "%Y%m%d%H%M%S")
            calendar_ok = True
        except ValueError:
            calendar_ok = False
    derived_status = "OK" if calendar_ok else "INVALID_METADATA"
    return derived_status == entry.expected_status


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="out", help="output directory for files")
    parser.add_argument("--size-bytes", type=int, default=256, help="placeholder file size")
    args = parser.parse_args()

    out_dir = Path(__file__).parent / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    entries = build_fixture_set()

    # Self-check the fixture before writing anything.
    mismatches = [e.filename for e in entries if not validate_entry_against_grammar(e)]
    if mismatches:
        raise SystemExit(f"Fixture self-check failed for: {mismatches}")

    payload = b"synthetic-placeholder\n" + b"0" * max(0, args.size_bytes - 22)
    written = 0
    for entry in entries:
        # Re-recording collision is intentional; suffix on-disk copy to avoid
        # clobbering while keeping the logical (colliding) name in the manifest.
        disk_name = entry.filename
        target = out_dir / disk_name
        if target.exists():
            target = out_dir / f"__dup__{written}__{disk_name}"
        try:
            target.write_bytes(payload)
            written += 1
        except OSError:
            # Non-ASCII/space names may be filesystem-sensitive; the manifest
            # still carries the case for parser tests even if the file is skipped.
            pass

    manifest = {
        "grammar": GRAMMAR.pattern,
        "parser_version": PARSER_VERSION,
        "timezone": "America/Argentina/Buenos_Aires (UTC-3, no DST)",
        "allowed_extensions": sorted(ALLOWED_EXTENSIONS),
        "counts": {
            "total": len(entries),
            "valid": sum(1 for e in entries if e.category == "valid"),
            "edge": sum(1 for e in entries if e.category == "edge"),
            "invalid": sum(1 for e in entries if e.category == "invalid"),
        },
        "entries": [asdict(e) for e in entries],
    }
    manifest_path = Path(__file__).parent / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False))

    print(f"Wrote {written} placeholder files to {out_dir}")
    print(f"Manifest: {manifest_path} ({manifest['counts']})")


if __name__ == "__main__":
    main()
