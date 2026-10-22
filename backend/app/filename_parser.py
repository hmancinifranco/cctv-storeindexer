"""Filename parser for the Video Archive prototype (design §4, assumption A1).

The grammar is an externalized, versioned configuration — NOT hardcoded logic —
so each customer deployment can adapt it. Default grammar (A1):

    CAM<id>_YYYYMMDD_HHMMSS[-HHMMSS].<ext>   local time UTC-3 (no DST)
    example: CAM07_20260923_142530-142959.mp4

The parser derives UTC once at index time and returns a typed result. On any
mismatch it returns an INVALID_METADATA outcome with a reason code — it never
raises for a bad name (malformed files are cataloged, not dropped: R2).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

PARSER_VERSION = "v1"

# Externalized grammar config. Swappable per deployment without touching logic.
DEFAULT_GRAMMAR: dict = {
    "version": PARSER_VERSION,
    "pattern": (
        r"^CAM(?P<camera>\d+)_(?P<date>\d{8})_(?P<start>\d{6})"
        r"(?:-(?P<end>\d{6}))?\.(?P<ext>[A-Za-z0-9]+)$"
    ),
    "allowed_extensions": ["mp4", "avi", "mkv"],
    "utc_offset_hours": -3,  # America/Argentina/Buenos_Aires, no DST
}


@dataclass(frozen=True)
class ParseResult:
    status: str  # "OK" | "INVALID_METADATA"
    reason: str = ""
    camera_id: str | None = None
    local_day: str | None = None  # YYYY-MM-DD, local recording day (Catalog PK)
    recorded_at_local: str | None = None
    recorded_at_utc: str | None = None
    ends_at_utc: str | None = None
    extension: str | None = None
    parser_version: str = PARSER_VERSION
    raw_filename: str = ""


@dataclass
class FilenameParser:
    """Config-driven parser. Inject a custom grammar dict to adapt per client."""

    grammar: dict = field(default_factory=lambda: dict(DEFAULT_GRAMMAR))

    def __post_init__(self) -> None:
        self._regex = re.compile(self.grammar["pattern"])
        self._tz = timezone(timedelta(hours=self.grammar["utc_offset_hours"]))
        self._allowed = {e.lower() for e in self.grammar["allowed_extensions"]}
        self._version = self.grammar.get("version", PARSER_VERSION)

    def parse(self, filename: str) -> ParseResult:
        def invalid(reason: str) -> ParseResult:
            return ParseResult(
                status="INVALID_METADATA",
                reason=reason,
                parser_version=self._version,
                raw_filename=filename,
            )

        match = self._regex.match(filename)
        if not match:
            return invalid("grammar mismatch")

        ext = match.group("ext").lower()
        if ext not in self._allowed:
            return invalid(f"disallowed extension: {ext}")

        date, start = match.group("date"), match.group("start")
        try:
            start_local = datetime.strptime(f"{date}{start}", "%Y%m%d%H%M%S").replace(
                tzinfo=self._tz
            )
        except ValueError:
            return invalid("invalid date/time")

        end_utc: str | None = None
        end_raw = match.groupdict().get("end")
        if end_raw:
            try:
                end_local = datetime.strptime(
                    f"{date}{end_raw}", "%Y%m%d%H%M%S"
                ).replace(tzinfo=self._tz)
                # A clip may cross midnight: end earlier than start rolls to next day.
                if end_local < start_local:
                    end_local += timedelta(days=1)
                end_utc = end_local.astimezone(timezone.utc).isoformat()
            except ValueError:
                return invalid("invalid end time")

        local_day = start_local.date().isoformat()
        return ParseResult(
            status="OK",
            camera_id=match.group("camera"),
            local_day=local_day,
            recorded_at_local=start_local.isoformat(),
            recorded_at_utc=start_local.astimezone(timezone.utc).isoformat(),
            ends_at_utc=end_utc,
            extension=ext,
            parser_version=self._version,
            raw_filename=filename,
        )
