import { defineConfig } from "vitest/config";

export default defineConfig({ test: {
  environment: "edge-runtime",
  include: ["Tests/backend/**/*.test.ts"],
} });
