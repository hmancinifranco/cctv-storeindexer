/// <reference types="vitest/config" />
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  // Local dev only: proxy /v1/* to the deployed API so browser requests are
  // same-origin (no CORS needed until the API's production CORS is configured).
  // Set DEV_PROXY_TARGET in .env.local to the API host (without the /v1 stage).
  const proxyTarget = env.DEV_PROXY_TARGET;
  return {
    plugins: [react()],
    server: proxyTarget
      ? { proxy: { "/v1": { target: proxyTarget, changeOrigin: true, secure: true } } }
      : undefined,
    test: {
      globals: true,
      environment: "jsdom",
      setupFiles: ["./src/test-setup.ts"],
    },
  };
});
