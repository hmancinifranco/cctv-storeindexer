import Alert from "@mui/material/Alert";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import CircularProgress from "@mui/material/CircularProgress";
import Paper from "@mui/material/Paper";
import Table from "@mui/material/Table";
import TableBody from "@mui/material/TableBody";
import TableCell from "@mui/material/TableCell";
import TableContainer from "@mui/material/TableContainer";
import TableHead from "@mui/material/TableHead";
import TableRow from "@mui/material/TableRow";
import Typography from "@mui/material/Typography";
import DownloadIcon from "@mui/icons-material/Download";
import type { VideoItem } from "../api/client";
import { StatusChip, statusOf } from "./StatusChip";

export type LoadState = "idle" | "loading" | "loaded" | "error";

function fmtSize(bytes: number | null): string {
  if (!bytes) return "—";
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`;
  if (bytes >= 1e6) return `${(bytes / 1e6).toFixed(1)} MB`;
  if (bytes >= 1e3) return `${(bytes / 1e3).toFixed(1)} KB`;
  return `${bytes} B`;
}

function fmtWhen(item: VideoItem): string {
  return item.recordedAtLocal ?? item.recordedAtUtc ?? "Sin fecha válida";
}

/**
 * Results table covering every UI state (design §15): loading, empty,
 * error, and rows with per-status actions. Uses accessible roles/labels so
 * tests query by role, not MUI internals.
 */
export function ResultsTable({
  state,
  items,
  errorMessage,
  onDownload,
  downloadingId,
}: {
  state: LoadState;
  items: VideoItem[];
  errorMessage?: string;
  onDownload: (item: VideoItem) => void;
  downloadingId?: string | null;
}) {
  if (state === "idle") {
    return (
      <Box sx={{ p: 5, textAlign: "center", color: "text.secondary" }}>
        <Typography>Elegí una fecha o cámara y presioná Buscar.</Typography>
      </Box>
    );
  }

  if (state === "loading") {
    return (
      <Box sx={{ p: 5, textAlign: "center" }} aria-busy="true" aria-label="Cargando resultados">
        <CircularProgress color="primary" />
        <Typography sx={{ mt: 2, color: "text.secondary" }}>Cargando resultados…</Typography>
      </Box>
    );
  }

  if (state === "error") {
    return (
      <Alert severity="error" role="alert">
        {errorMessage ?? "No pudimos completar la búsqueda. Reintentá en unos segundos."}
      </Alert>
    );
  }

  if (items.length === 0) {
    return (
      <Box sx={{ p: 5, textAlign: "center", color: "text.secondary" }}>
        <Typography>No se encontraron grabaciones para los filtros seleccionados.</Typography>
      </Box>
    );
  }

  return (
    <TableContainer component={Paper} variant="outlined">
      <Table aria-label="Resultados de grabaciones">
        <TableHead>
          <TableRow>
            <TableCell>Fecha y hora</TableCell>
            <TableCell>Cámara</TableCell>
            <TableCell>Archivo</TableCell>
            <TableCell>Tamaño</TableCell>
            <TableCell>Estado</TableCell>
            <TableCell align="right">Acción</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {items.map((item) => {
            const s = statusOf(item);
            const downloadable = s === "available" || s === "restored";
            const busy = downloadingId === item.stableId;
            return (
              <TableRow key={item.stableId} hover>
                <TableCell>{fmtWhen(item)}</TableCell>
                <TableCell>{item.cameraId ?? "—"}</TableCell>
                <TableCell sx={{ fontFamily: "monospace", fontSize: 13 }}>
                  {item.objectKey.replace(/^videos\//, "")}
                </TableCell>
                <TableCell>{fmtSize(item.sizeBytes)}</TableCell>
                <TableCell>
                  <StatusChip item={item} />
                </TableCell>
                <TableCell align="right">
                  <Button
                    size="small"
                    startIcon={<DownloadIcon />}
                    disabled={!downloadable || busy}
                    onClick={() => onDownload(item)}
                  >
                    {busy ? "Preparando…" : downloadable ? "Descargar" : "No disponible"}
                  </Button>
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </TableContainer>
  );
}
