import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // The site now uses the custom domain at the root:
  // https://latentarchive.bond/
  base: "/",
});
