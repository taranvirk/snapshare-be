const assert = require("node:assert/strict");
const { once } = require("node:events");
const test = require("node:test");

process.env.SUPABASE_URL = "https://example.invalid";
process.env.SUPABASE_SERVICE_ROLE_KEY = "test-key";
const app = require("../main/index.js");

test("GET /health returns OK and a non-negative integer uptime", async (t) => {
    const server = app.listen(0, "127.0.0.1");
    t.after(() => server.close());
    await once(server, "listening");

    const response = await fetch(`http://127.0.0.1:${server.address().port}/health`, {
        headers: { Connection: "close" },
        signal: AbortSignal.timeout(5000),
    });
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), /^application\/json\b/);

    const { status, uptime } = await response.json();
    assert.equal(status, "ok");
    assert.ok(Number.isInteger(uptime) && uptime >= 0);
});
