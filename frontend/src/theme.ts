import { createTheme, type Theme } from "@mui/material/styles";

/**
 * Centralized theme (design §15, R "centralized theme, no hardcoded colors").
 * Graphite + teal identity from the approved mockup, expressed as light and
 * dark palettes so the SPA can toggle between them. Components read palette
 * tokens — never hardcoded hex — so both modes stay consistent.
 */

const TEAL = "#14b8a6";
const TEAL_LIGHT = "#2dd4bf";

const shared = {
  typography: {
    fontFamily: ["Inter", "-apple-system", "Segoe UI", "Roboto", "sans-serif"].join(","),
    button: { textTransform: "none" as const, fontWeight: 600 },
  },
  shape: { borderRadius: 10 },
};

export const darkTheme: Theme = createTheme({
  ...shared,
  palette: {
    mode: "dark",
    primary: { main: TEAL_LIGHT, dark: TEAL, contrastText: "#04201c" },
    background: { default: "#0f1419", paper: "#1a212b" },
    text: { primary: "#e6edf3", secondary: "#8b98a9" },
    divider: "#2c3644",
    success: { main: "#34d399" },
    warning: { main: "#fbbf24" },
    error: { main: "#f87171" },
  },
});

export const lightTheme: Theme = createTheme({
  ...shared,
  palette: {
    mode: "light",
    primary: { main: TEAL, dark: "#0e7490", contrastText: "#ffffff" },
    background: { default: "#f5f7f8", paper: "#ffffff" },
    text: { primary: "#0f1419", secondary: "#5b6773" },
    divider: "#e2e8ec",
    success: { main: "#0f9d6b" },
    warning: { main: "#b7791f" },
    error: { main: "#d32f2f" },
  },
});

export type ColorMode = "light" | "dark";
export const themeFor = (mode: ColorMode): Theme =>
  mode === "dark" ? darkTheme : lightTheme;
