import http from "node:http";

const PORT = Number(process.env.PORT || 10000);
const GRAPH_HOPPER_KEY = process.env.GRAPH_HOPPER_API_KEY;
const GRAPH_HOPPER_URL = "https://graphhopper.com/api/1/route";
const MAX_BODY_BYTES = 32 * 1024;
const WINDOW_MS = 10 * 60 * 1000;
const MAX_REQUESTS_PER_WINDOW = 30;
const requestLog = new Map();

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type",
  });
  res.end(payload);
}

function clientAddress(req) {
  const forwarded = req.headers["x-forwarded-for"];
  return (typeof forwarded === "string" ? forwarded.split(",")[0] : req.socket.remoteAddress) || "unknown";
}

function isRateLimited(address) {
  const now = Date.now();
  const recent = (requestLog.get(address) || []).filter((timestamp) => now - timestamp < WINDOW_MS);
  if (recent.length >= MAX_REQUESTS_PER_WINDOW) {
    requestLog.set(address, recent);
    return true;
  }
  recent.push(now);
  requestLog.set(address, recent);
  return false;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      size += Buffer.byteLength(chunk);
      if (size > MAX_BODY_BYTES) {
        reject(Object.assign(new Error("Request body is too large"), { statusCode: 413 }));
        req.destroy();
        return;
      }
      body += chunk;
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function validateRequest(input) {
  const latitude = Number(input?.latitude);
  const longitude = Number(input?.longitude);
  const targetDistanceKm = Number(input?.targetDistanceKm);
  const seed = Number(input?.seed);

  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90) {
    throw Object.assign(new Error("latitude must be between -90 and 90"), { statusCode: 400 });
  }
  if (!Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
    throw Object.assign(new Error("longitude must be between -180 and 180"), { statusCode: 400 });
  }
  if (!Number.isFinite(targetDistanceKm) || targetDistanceKm < 2 || targetDistanceKm > 300) {
    throw Object.assign(new Error("targetDistanceKm must be between 2 and 300"), { statusCode: 400 });
  }
  if (!Number.isInteger(seed) || seed < 0 || seed > 1000000) {
    throw Object.assign(new Error("seed must be an integer between 0 and 1000000"), { statusCode: 400 });
  }

  return { latitude, longitude, targetDistanceKm, seed };
}

async function handleRoute(req, res) {
  if (!GRAPH_HOPPER_KEY) {
    sendJson(res, 503, { message: "Routing service is not configured" });
    return;
  }

  let input;
  try {
    input = validateRequest(JSON.parse(await readBody(req)));
  } catch (error) {
    sendJson(res, error.statusCode || 400, { message: error.message || "Invalid request" });
    return;
  }

  const params = new URLSearchParams({
    point: `${input.latitude},${input.longitude}`,
    profile: "bike",
    algorithm: "round_trip",
    "round_trip.distance": String(Math.round(input.targetDistanceKm * 1000)),
    "round_trip.seed": String(input.seed),
    elevation: "true",
    instructions: "true",
    locale: "en",
    key: GRAPH_HOPPER_KEY,
  });

  try {
    const upstream = await fetch(`${GRAPH_HOPPER_URL}?${params.toString()}`, {
      signal: AbortSignal.timeout(25000),
    });
    const text = await upstream.text();
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      body = { message: "Routing provider returned an invalid response" };
    }

    if (!upstream.ok) {
      sendJson(res, upstream.status >= 500 ? 502 : upstream.status, {
        message: body.message || "Routing provider rejected the request",
      });
      return;
    }

    sendJson(res, 200, body);
  } catch (error) {
    console.error("GraphHopper request failed:", error.message);
    sendJson(res, 502, { message: "Routing provider unavailable" });
  }
}

const server = http.createServer(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type",
    });
    res.end();
    return;
  }

  if (req.method === "GET" && req.url === "/health") {
    sendJson(res, 200, { ok: true, service: "iloop-routing-proxy" });
    return;
  }

  if (req.method === "POST" && req.url === "/route") {
    const address = clientAddress(req);
    if (isRateLimited(address)) {
      sendJson(res, 429, { message: "Too many route requests. Try again shortly." });
      return;
    }
    await handleRoute(req, res);
    return;
  }

  sendJson(res, 404, { message: "Not found" });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`iLoop routing proxy listening on port ${PORT}`);
});
