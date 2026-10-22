import { useState } from "react";
import Box from "@mui/material/Box";
import Container from "@mui/material/Container";
import Snackbar from "@mui/material/Snackbar";
import Alert from "@mui/material/Alert";
import Typography from "@mui/material/Typography";
import {
  ApiError,
  requestDownloadUrl,
  searchVideos,
  type SearchParams,
  type VideoItem,
} from "../api/client";
import { SearchBar } from "../components/SearchBar";
import { ResultsTable, type LoadState } from "../components/ResultsTable";
import { getIdToken } from "../auth/auth";

export function SearchPage() {
  const idToken = getIdToken() ?? "";
  const [state, setState] = useState<LoadState>("idle");
  const [items, setItems] = useState<VideoItem[]>([]);
  const [errorMessage, setErrorMessage] = useState<string>();
  const [downloadingId, setDownloadingId] = useState<string | null>(null);
  const [toast, setToast] = useState<{ severity: "success" | "warning" | "error"; msg: string } | null>(null);

  const doSearch = async (params: SearchParams) => {
    setState("loading");
    try {
      const res = await searchVideos(idToken, params);
      setItems(res.items);
      setState("loaded");
    } catch (err) {
      const msg =
        err instanceof ApiError && err.code === "INVALID_QUERY"
          ? err.message
          : "No pudimos completar la búsqueda. Reintentá en unos segundos.";
      setErrorMessage(msg);
      setState("error");
    }
  };

  const doDownload = async (item: VideoItem) => {
    setDownloadingId(item.stableId);
    try {
      const { url } = await requestDownloadUrl(idToken, item.stableId);
      window.open(url, "_blank", "noopener");
      setToast({ severity: "success", msg: "Enlace de descarga generado (válido por tiempo limitado)." });
    } catch (err) {
      if (err instanceof ApiError && (err.status === 403 || err.code === "FORBIDDEN")) {
        setToast({ severity: "warning", msg: "No tenés permiso para descargar esta grabación." });
      } else if (err instanceof ApiError && err.code === "RESTORE_REQUIRED") {
        setToast({ severity: "warning", msg: "La grabación está archivada; requiere restauración." });
      } else {
        setToast({ severity: "error", msg: "No se pudo generar el enlace de descarga." });
      }
    } finally {
      setDownloadingId(null);
    }
  };

  return (
    <Container maxWidth="lg" sx={{ py: 4 }}>
      <SearchBar onSearch={doSearch} disabled={state === "loading"} />
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", mt: 4, mb: 1.5 }}>
        <Typography variant="overline" sx={{ color: "text.secondary", letterSpacing: 1 }}>
          Resultados
        </Typography>
        {state === "loaded" && (
          <Typography variant="body2" sx={{ color: "primary.main", fontWeight: 600 }}>
            {items.length} grabaciones
          </Typography>
        )}
      </Box>
      <ResultsTable
        state={state}
        items={items}
        errorMessage={errorMessage}
        onDownload={doDownload}
        downloadingId={downloadingId}
      />
      <Snackbar
        open={!!toast}
        autoHideDuration={6000}
        onClose={() => setToast(null)}
        anchorOrigin={{ vertical: "bottom", horizontal: "center" }}
      >
        {toast ? (
          <Alert severity={toast.severity} onClose={() => setToast(null)} variant="filled">
            {toast.msg}
          </Alert>
        ) : undefined}
      </Snackbar>
    </Container>
  );
}
