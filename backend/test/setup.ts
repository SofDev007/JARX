import { applyD1Migrations, reset } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, vi } from "vitest";

beforeEach(async () => {
	await reset(); // wipe D1 so every test starts from an empty, migrated database
	await applyD1Migrations(env.jarx_db, env.TEST_MIGRATIONS);
});

afterEach(() => {
	vi.restoreAllMocks();
});
