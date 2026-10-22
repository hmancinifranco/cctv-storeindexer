import Chip from "@mui/material/Chip";
import type { VideoItem } from "../api/client";

/**
 * Maps a catalog entry to a human, plain-language status chip.
 * Color comes from the theme palette (success/warning/error), never hardcoded.
 * Uses a text label + color (never color alone) for accessibility.
 */
export type UiStatus = "available" | "invalid" | "archived" | "restorePending" | "restored" | "deleted";

export function statusOf(item: VideoItem): UiStatus {
  if (item.deleted || item.lifecycleState === "DELETED") return "deleted";
  if (item.catalogStatus === "INVALID_METADATA") return "invalid";
  if (item.lifecycleState === "RESTORE_PENDING") return "restorePending";
  if (item.lifecycleState === "RESTORED") return "restored";
  if (item.lifecycleState === "ARCHIVED") return "archived";
  const sc = (item.storageClass ?? "STANDARD").toUpperCase();
  if (sc === "GLACIER" || sc === "DEEP_ARCHIVE") return "archived";
  return "available";
}

const LABEL: Record<UiStatus, string> = {
  available: "Disponible",
  invalid: "Metadata inválida",
  archived: "Archivado; requiere restauración",
  restorePending: "Restauración en curso",
  restored: "Restaurado temporalmente",
  deleted: "Eliminado",
};

const COLOR: Record<UiStatus, "success" | "error" | "warning" | "info"> = {
  available: "success",
  invalid: "error",
  archived: "warning",
  restorePending: "info",
  restored: "success",
  deleted: "error",
};

export function StatusChip({ item }: { item: VideoItem }) {
  const s = statusOf(item);
  return <Chip size="small" variant="outlined" color={COLOR[s]} label={LABEL[s]} />;
}
