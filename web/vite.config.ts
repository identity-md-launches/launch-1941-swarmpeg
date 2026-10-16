import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Relative base: the export is served from an IPFS gateway subpath or an ENS name, never from "/".
export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    outDir: "../dist",
    emptyOutDir: true,
    target: "es2022",
    sourcemap: false,
    chunkSizeWarningLimit: 1500,
  },
});
