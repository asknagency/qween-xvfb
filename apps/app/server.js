'use strict';

// Zero-dependency static file server — no npm install needed.
// Serves QweenRender.html and project ZIPs to Playwright.

const http = require('http');
const path = require('path');
const fs   = require('fs');
const url  = require('url');

const PORT       = process.env.RENDERER_PORT || 3000;
const PUBLIC_DIR = path.join(__dirname, 'public');
// ASSETS_DIR must point to the same folder the API writes to.
// Default: apps/api/assets/ (sibling of apps/app/ — persistent on-disk store).
// Override with ASSETS_DIR env var when using a shared volume or object storage.
const ASSETS_DIR = process.env.ASSETS_DIR || path.resolve(__dirname, '../../api/assets');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.zip':  'application/zip',
  '.json': 'application/json',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.svg':  'image/svg+xml',
  '.woff2':'font/woff2',
  '.woff': 'font/woff',
  '.ttf':  'font/ttf',
  '.mp4':  'video/mp4',
  '.webm': 'video/webm',
  '.mov':  'video/quicktime',
  '.avi':  'video/x-msvideo',
  '.mkv':  'video/x-matroska',
  '.otf':  'font/otf',
};

const PROJECTS_DIR = path.join(PUBLIC_DIR, 'projects');
if (!fs.existsSync(PROJECTS_DIR)) fs.mkdirSync(PROJECTS_DIR, { recursive: true });

const server = http.createServer((req, res) => {
  const parsed  = url.parse(req.url);
  const reqPath = decodeURIComponent(parsed.pathname);

  // CORS — allow Playwright and QweenApp on any port
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, DELETE, OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  // ── GET /health ────────────────────────────────────────────────────────────
  if (req.method === 'GET' && reqPath === '/health') {
    const projects = fs.readdirSync(PROJECTS_DIR).filter(f => f.endsWith('.zip'));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', projects: projects.length, port: PORT }));
    return;
  }

  // ── GET /projects — list ZIPs ──────────────────────────────────────────────
  if (req.method === 'GET' && reqPath === '/projects') {
    const files = fs.readdirSync(PROJECTS_DIR)
      .filter(f => f.endsWith('.zip'))
      .map(f => ({
        id:      path.basename(f, '.zip'),
        url:     `/projects/${f}`,
        size_mb: +(fs.statSync(path.join(PROJECTS_DIR, f)).size / 1_048_576).toFixed(2),
      }));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ projects: files }));
    return;
  }

  // ── DELETE /projects/:id ───────────────────────────────────────────────────
  if (req.method === 'DELETE' && reqPath.startsWith('/projects/')) {
    const id   = path.basename(reqPath);
    const file = path.join(PROJECTS_DIR, id.endsWith('.zip') ? id : `${id}.zip`);
    if (!fs.existsSync(file)) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Not found' }));
      return;
    }
    fs.unlinkSync(file);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ deleted: id }));
    return;
  }

  // ── GET /assets/:id — serve uploaded video/font blobs to Playwright ──────────
  // Assets are stored by the API as: ASSETS_DIR/<asset_id>/file.<ext>
  if (req.method === 'GET' && reqPath.startsWith('/assets/')) {
    const assetId  = reqPath.split('/')[2];
    if (assetId) {
      const assetDir = path.join(ASSETS_DIR, assetId);
      // Security: prevent path traversal
      if (!assetDir.startsWith(ASSETS_DIR)) {
        res.writeHead(403); res.end('Forbidden'); return;
      }
      if (fs.existsSync(assetDir)) {
        const files = fs.readdirSync(assetDir).filter(f => f.startsWith('file.'));
        if (files.length > 0) {
          const assetPath = path.join(assetDir, files[0]);
          const ext  = path.extname(assetPath).toLowerCase();
          const mime = MIME[ext] || 'application/octet-stream';
          const stat = fs.statSync(assetPath);
          res.writeHead(200, {
            'Content-Type':   mime,
            'Content-Length': stat.size,
            'Cache-Control':  'public, max-age=3600',
            'Accept-Ranges':  'bytes',
          });
          fs.createReadStream(assetPath).pipe(res);
          return;
        }
      }
    }
    res.writeHead(404); res.end('Asset not found'); return;
  }

  // ── Static files from public/ ──────────────────────────────────────────────
  // Default / → QweenRender.html
  const filePath = path.join(
    PUBLIC_DIR,
    reqPath === '/' ? 'QweenRender.html' : reqPath
  );

  // Security: prevent path traversal
  if (!filePath.startsWith(PUBLIC_DIR)) {
    res.writeHead(403); res.end('Forbidden'); return;
  }

  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    res.writeHead(404); res.end('Not found'); return;
  }

  const ext      = path.extname(filePath).toLowerCase();
  const mime     = MIME[ext] || 'application/octet-stream';
  const noCache  = ext === '.zip' || ext === '.html';
  const headers  = {
    'Content-Type':  mime,
    'Cache-Control': noCache ? 'no-store' : 'public, max-age=3600',
  };

  const stat = fs.statSync(filePath);
  res.writeHead(200, { ...headers, 'Content-Length': stat.size });
  fs.createReadStream(filePath).pipe(res);
});

server.listen(PORT, () => {
  console.log(`[qween-app] Renderer running at http://localhost:${PORT}`);
  console.log(`[qween-app] QweenRender: http://localhost:${PORT}/QweenRender.html`);
  console.log(`[qween-app] Projects dir: ${PROJECTS_DIR}`);
});
