import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/sdk/**/*.test.ts"],
    timeout: 30000,
  },
});
