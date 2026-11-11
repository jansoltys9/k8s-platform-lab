const http = require("node:http");
const os = require("node:os");
const crypto = require("node:crypto");

const PORT = Number(process.env.PORT || 3000);
const MESSAGE = process.env.APP_MESSAGE || "Hello from Kubernetes Platform!";
const ENVIRONMENT = process.env.APP_ENV || "local";
const INTERNAL_API_TOKEN = process.env.INTERNAL_API_TOKEN;

// Fail closed when the required secret is unavailable.
if (!/^[0-9a-f]{64}$/.test(INTERNAL_API_TOKEN || "")) {
  console.error("INTERNAL_API_TOKEN is missing or invalid");
  process.exit(1);
}

let apiRequests = 0;

function authorized(providedToken) {
  if (typeof providedToken !== "string") {
    return false;
  }

  const expected = Buffer.from(INTERNAL_API_TOKEN);
  const actual = Buffer.from(providedToken);

  return expected.length === actual.length &&
    crypto.timingSafeEqual(expected, actual);
}

const server = http.createServer((req, res) => {
  const path = new URL(req.url, "http://localhost").pathname;

  if (req.method !== "GET") {
    res.writeHead(405, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ error: "Method not allowed" }));
  }

  if (path === "/healthz" || path === "/readyz") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ status: "ok" }));
  }

  if (path === "/internal/status") {
    if (!authorized(req.headers["x-internal-token"])) {
      res.writeHead(401, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store"
      });

      return res.end(JSON.stringify({ error: "Unauthorized" }));
    }

    res.writeHead(200, {
      "Content-Type": "application/json",
      "Cache-Control": "no-store"
    });

    return res.end(JSON.stringify({
      status: "ok",
      service: "platformlab-backend"
    }));
  }

  if (path === "/api/hello") {
    apiRequests++;

    res.writeHead(200, { "Content-Type": "application/json" });

    return res.end(JSON.stringify({
      message: MESSAGE,
      service: "platformlab-backend",
      environment: ENVIRONMENT,
      hostname: os.hostname(),
      timestamp: new Date().toISOString()
    }));
  }

  if (path === "/metrics") {
    res.writeHead(200, {
      "Content-Type": "text/plain; version=0.0.4; charset=utf-8"
    });

    return res.end([
      "# HELP platformlab_api_requests_total Total API requests",
      "# TYPE platformlab_api_requests_total counter",
      `platformlab_api_requests_total ${apiRequests}`,
      "# HELP platformlab_uptime_seconds Process uptime in seconds",
      "# TYPE platformlab_uptime_seconds gauge",
      `platformlab_uptime_seconds ${process.uptime()}`,
      ""
    ].join("\n"));
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "Not found" }));
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`PlatformLab backend listening on port ${PORT}`);
});

process.on("SIGTERM", () => {
  server.close(() => process.exit(0));
});
