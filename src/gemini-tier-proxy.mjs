// ~/.local/share/gemini-tier-proxy/gemini-tier-proxy.mjs
import http from "node:http";
import https from "node:https";
import fs from "node:fs";

const PORT = Number(process.env.PORT || 8787);
const HOST = "127.0.0.1";
const UPSTREAM_HOST = "generativelanguage.googleapis.com";
const SERVICE_TIER = (process.env.SERVICE_TIER || "FLEX").toUpperCase(); // FLEX | PRIORITY | STANDARD
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 900_000); // 15 min

function isFallbackEnabled() {
  const toggleFile = `${process.env.HOME}/.local/share/gemini-tier-proxy/auto-fallback`;
  try {
    if (fs.existsSync(toggleFile)) {
      const val = fs.readFileSync(toggleFile, "utf8").trim().toLowerCase();
      if (val === "true" || val === "1") return true;
      if (val === "false" || val === "0") return false;
    }
  } catch {}
  return String(process.env.AUTO_FALLBACK || "true").toLowerCase() === "true";
}

const TARGET_ENDPOINT_RE = /:(streamG|g)enerateContent(\?|$)/;

function maskApiKey(url = "") {
  return url.replace(/([?&]key=)[^&]+/gi, "$1***");
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function buildUpstreamHeaders(reqHeaders, bodyBuffer) {
  const headers = { ...reqHeaders };
  headers.host = UPSTREAM_HOST;
  delete headers["connection"];
  delete headers["transfer-encoding"];

  if (bodyBuffer.length > 0) {
    headers["content-length"] = String(bodyBuffer.length);
  } else {
    delete headers["content-length"];
  }
  return headers;
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && (req.url === "/health" || req.url?.startsWith("/health?"))) {
    const healthBody = JSON.stringify({
      status: "ok",
      serviceTier: SERVICE_TIER,
      autoFallback: isFallbackEnabled(),
      port: PORT,
    });
    res.writeHead(200, {
      "content-type": "application/json",
      "content-length": String(Buffer.byteLength(healthBody)),
    });
    res.end(healthBody);
    return;
  }

  let activeUpstreamReq = null;
  let clientClosed = false;

  res.on("close", () => {
    if (!res.writableEnded) {
      clientClosed = true;
      if (activeUpstreamReq) {
        activeUpstreamReq.destroy();
      }
    }
  });

  try {
    const rawBody = await readBody(req);
    if (clientClosed) return;

    let primaryBody = rawBody;
    let fallbackBody = null;
    let injectedTier = null;

    if (
      req.method === "POST" &&
      TARGET_ENDPOINT_RE.test(req.url || "") &&
      rawBody.length > 0 &&
      SERVICE_TIER !== "STANDARD"
    ) {
      try {
        const payload = JSON.parse(rawBody.toString("utf8"));
        const primaryPayload = { ...payload, serviceTier: SERVICE_TIER.toLowerCase() };
        primaryBody = Buffer.from(JSON.stringify(primaryPayload), "utf8");
        injectedTier = SERVICE_TIER;

        if (isFallbackEnabled() && SERVICE_TIER === "FLEX") {
          const standardPayload = { ...payload };
          delete standardPayload.serviceTier;
          fallbackBody = Buffer.from(JSON.stringify(standardPayload), "utf8");
        }
      } catch {
        // Corpo não é JSON válido: repassa intacto
      }
    }

    const forwardRequest = (bodyToSend, { tierLabel, isFallback }) => {
      if (clientClosed) return;

      const headers = buildUpstreamHeaders(req.headers, bodyToSend);
      const upstreamReq = https.request(
        {
          hostname: UPSTREAM_HOST,
          port: 443,
          path: req.url,
          method: req.method,
          headers,
          timeout: TIMEOUT_MS,
        },
        (upstreamRes) => {
          const status = upstreamRes.statusCode || 502;
          const canFallback = !isFallback && fallbackBody !== null && (status === 429 || status === 503);

          if (canFallback) {
            upstreamRes.resume();
            console.warn(
              `[${new Date().toISOString()}] ${req.method} ${maskApiKey(req.url)} ` +
                `status=${status} no modo ${tierLabel} -> ativando fallback para STANDARD`
            );
            forwardRequest(fallbackBody, { tierLabel: "STANDARD", isFallback: true });
            return;
          }

          const appliedTier =
            upstreamRes.headers["x-gemini-service-tier"] || "não retornado no header";

          console.log(
            `[${new Date().toISOString()}] ${req.method} ${maskApiKey(req.url)} ` +
              `status=${status} | tier=${tierLabel || "inalterado"} | fallback=${isFallback} | x-gemini-service-tier=${appliedTier}`
          );

          upstreamRes.on("error", () => {
            if (!res.writableEnded) res.end();
          });

          res.writeHead(status, upstreamRes.headers);
          res.flushHeaders();
          upstreamRes.pipe(res);
        }
      );

      activeUpstreamReq = upstreamReq;

      upstreamReq.on("timeout", () => {
        upstreamReq.destroy(new Error(`Timeout após ${TIMEOUT_MS}ms`));
      });

      upstreamReq.on("error", (err) => {
        if (clientClosed) return;
        console.error(`[ERRO upstream] ${maskApiKey(req.url)}:`, err.message);
        if (!res.headersSent) {
          const errBody = JSON.stringify({ error: { message: `Proxy error: ${err.message}` } });
          res.writeHead(502, {
            "content-type": "application/json",
            "content-length": String(Buffer.byteLength(errBody)),
          });
          res.end(errBody);
        } else {
          res.end();
        }
      });

      if (bodyToSend.length > 0) {
        upstreamReq.write(bodyToSend);
      }
      upstreamReq.end();
    };

    forwardRequest(primaryBody, { tierLabel: injectedTier, isFallback: false });
  } catch (err) {
    console.error("[ERRO proxy]", err.message);
    if (!res.headersSent) {
      const errBody = JSON.stringify({ error: { message: err.message } });
      res.writeHead(500, {
        "content-type": "application/json",
        "content-length": String(Buffer.byteLength(errBody)),
      });
      res.end(errBody);
    }
  }
});

// Desativa timeouts padrão de 5 min do Node.js para suportar filas longas do modo FLEX
server.requestTimeout = 0;
server.headersTimeout = 0;

server.listen(PORT, HOST, () => {
  console.log(`Gemini Tier Proxy ouvindo em http://${HOST}:${PORT}`);
  console.log(
    `Destino: https://${UPSTREAM_HOST} | SERVICE_TIER=${SERVICE_TIER} | AUTO_FALLBACK=${isFallbackEnabled()}`
  );
});
