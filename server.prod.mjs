import http from "node:http";
import { createReadStream, existsSync, statSync } from "node:fs";
import path from "node:path";
import { server as wisp } from "@mercuryworkshop/wisp-js/server";

const PORT = parseInt(process.env.PORT || "4141");
const STATIC_DIR = path.resolve(process.env.STATIC_DIR || "./static");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

function serve(req, res) {
  let url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
  let filePath = path.join(STATIC_DIR, decodeURIComponent(url.pathname));

  // Prevent directory traversal
  if (!filePath.startsWith(STATIC_DIR)) {
    res.writeHead(403);
    res.end();
    return;
  }

  // Default to index.html
  if (filePath.endsWith("/") || !path.extname(filePath)) {
    const indexPath = filePath.endsWith("/")
      ? path.join(filePath, "index.html")
      : filePath + "/index.html";
    if (existsSync(indexPath)) {
      filePath = indexPath;
    } else if (!path.extname(filePath) && existsSync(filePath + ".html")) {
      filePath = filePath + ".html";
    }
  }

  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    // SPA fallback
    filePath = path.join(STATIC_DIR, "index.html");
    if (!existsSync(filePath)) {
      res.writeHead(404);
      res.end("Not Found");
      return;
    }
  }

  // INTERCEPT HTML FILES FOR DYNAMIC ENV INJECTION
  if (filePath.endsWith(".html")) {
    let html = readFileSync(filePath, "utf-8");
    
    // Create our dynamic configuration object from Docker environment variables
    const runtimeConfig = {
      WISP_URL: process.env.WISP_URL || "wss://surf.ziqfm.com/"
    };

    // Inject the variables into the <head> of the HTML document
    const injectionScript = `<script>window.__RUNTIME_CONFIG__ = ${JSON.stringify(runtimeConfig)};</script>`;
    html = html.replace("<head>", `<head>${injectionScript}`);

    res.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    });
    res.end(html);
    return;
  }

  // Serve all other static assets normally
  const ext = path.extname(filePath).toLowerCase();
  const mime = MIME[ext] || "application/octet-stream";

  res.writeHead(200, {
    "Content-Type": mime,
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Embedder-Policy": "require-corp",
  });
  createReadStream(filePath).pipe(res);
}

const httpServer = http.createServer(serve);

httpServer.on("upgrade", (req, socket, head) => {
  wisp.routeRequest(req, socket, head);
});

wisp.options.allow_private_ips = true;
wisp.options.allow_loopback_ips = true;

httpServer.listen(PORT, "0.0.0.0", () => {
  console.log(`scramjet production server on :${PORT}`);
});
