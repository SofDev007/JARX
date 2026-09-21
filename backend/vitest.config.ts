import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => ({
	plugins: [
		cloudflareTest({
			wrangler: { configPath: "./wrangler.jsonc" },
			remoteBindings: false, // tests must never touch the real D1 database
			miniflare: {
				bindings: {
					JARX_TOKEN: "test-token",
					JAMENDO_CLIENT_ID: "test-jamendo-id",
					YOUTUBE_API_KEY: "test-youtube-key",
					TEST_MIGRATIONS: await readD1Migrations("./migrations"),
				},
			},
		}),
	],
	test: { setupFiles: ["./test/setup.ts"] },
}));
