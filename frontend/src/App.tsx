import { useEffect, useState } from "react";
import AppBar from "@mui/material/AppBar";
import Avatar from "@mui/material/Avatar";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import CircularProgress from "@mui/material/CircularProgress";
import IconButton from "@mui/material/IconButton";
import Toolbar from "@mui/material/Toolbar";
import Tooltip from "@mui/material/Tooltip";
import Typography from "@mui/material/Typography";
import DarkModeIcon from "@mui/icons-material/DarkModeOutlined";
import LightModeIcon from "@mui/icons-material/LightModeOutlined";
import LoginIcon from "@mui/icons-material/Login";
import VideocamIcon from "@mui/icons-material/Videocam";
import { useColorMode } from "./ColorModeContext";
import { SearchPage } from "./pages/SearchPage";
import { completeLoginIfRedirected, getIdToken, isConfigured, login, logout } from "./auth/auth";

export function App() {
  const { mode, toggle } = useColorMode();
  const [ready, setReady] = useState(false);
  const [authed, setAuthed] = useState(false);

  useEffect(() => {
    completeLoginIfRedirected()
      .then(() => setAuthed(Boolean(getIdToken())))
      .finally(() => setReady(true));
  }, []);

  const modeToggle = (
    <Tooltip title={mode === "dark" ? "Cambiar a tema claro" : "Cambiar a tema oscuro"}>
      <IconButton
        onClick={toggle}
        aria-label={mode === "dark" ? "Activar tema claro" : "Activar tema oscuro"}
        sx={{ color: "text.secondary" }}
      >
        {mode === "dark" ? <LightModeIcon /> : <DarkModeIcon />}
      </IconButton>
    </Tooltip>
  );

  return (
    <Box sx={{ minHeight: "100vh", bgcolor: "background.default" }}>
      <AppBar position="static" elevation={0} sx={{ bgcolor: "background.paper", borderBottom: 1, borderColor: "divider" }}>
        <Toolbar>
          <Avatar variant="rounded" sx={{ bgcolor: "primary.main", color: "primary.contrastText", mr: 1.5, width: 36, height: 36 }}>
            <VideocamIcon fontSize="small" />
          </Avatar>
          <Box sx={{ flexGrow: 1 }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 600, color: "text.primary", lineHeight: 1.1 }}>
              Video Archive
            </Typography>
            <Typography variant="caption" sx={{ color: "text.secondary" }}>
              Búsqueda y descarga de grabaciones
            </Typography>
          </Box>
          {modeToggle}
          {authed && (
            <Button sx={{ ml: 1, color: "text.secondary" }} onClick={logout}>
              Cerrar sesión
            </Button>
          )}
        </Toolbar>
      </AppBar>

      {!ready ? (
        <Box sx={{ display: "flex", justifyContent: "center", pt: 10 }}>
          <CircularProgress />
        </Box>
      ) : authed ? (
        <SearchPage />
      ) : (
        <Box sx={{ textAlign: "center", pt: 12, px: 2 }}>
          <Typography variant="h6" sx={{ mb: 1 }}>
            Acceso al archivo de video
          </Typography>
          <Typography sx={{ color: "text.secondary", mb: 3 }}>
            Iniciá sesión para buscar y descargar grabaciones.
          </Typography>
          <Button
            variant="contained"
            size="large"
            startIcon={<LoginIcon />}
            onClick={login}
            disabled={!isConfigured()}
          >
            Iniciar sesión
          </Button>
          {!isConfigured() && (
            <Typography variant="caption" sx={{ display: "block", mt: 2, color: "text.secondary" }}>
              Falta configurar el proveedor de identidad (VITE_HOSTED_UI_DOMAIN / VITE_COGNITO_CLIENT_ID).
            </Typography>
          )}
        </Box>
      )}
    </Box>
  );
}
