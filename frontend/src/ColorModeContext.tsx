import { createContext, useContext, useMemo, useState, type ReactNode } from "react";
import { ThemeProvider } from "@mui/material/styles";
import CssBaseline from "@mui/material/CssBaseline";
import { themeFor, type ColorMode } from "./theme";

interface ColorModeCtx {
  mode: ColorMode;
  toggle: () => void;
}

const Ctx = createContext<ColorModeCtx>({ mode: "dark", toggle: () => {} });

const STORAGE_KEY = "cctv.colorMode";

function initialMode(): ColorMode {
  const saved = localStorage.getItem(STORAGE_KEY);
  if (saved === "light" || saved === "dark") return saved;
  // Default to the user's OS preference, falling back to dark (the mockup).
  const prefersLight =
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: light)").matches;
  return prefersLight ? "light" : "dark";
}

/** Wraps the app in an MUI ThemeProvider whose mode is toggleable + persisted. */
export function ColorModeProvider({ children }: { children: ReactNode }) {
  const [mode, setMode] = useState<ColorMode>(initialMode);

  const value = useMemo<ColorModeCtx>(
    () => ({
      mode,
      toggle: () =>
        setMode((prev) => {
          const next = prev === "dark" ? "light" : "dark";
          localStorage.setItem(STORAGE_KEY, next);
          return next;
        }),
    }),
    [mode],
  );

  return (
    <Ctx.Provider value={value}>
      <ThemeProvider theme={themeFor(mode)}>
        <CssBaseline />
        {children}
      </ThemeProvider>
    </Ctx.Provider>
  );
}

export const useColorMode = () => useContext(Ctx);
