# TrafficManager Frontend

Preact + Tailwind CSS web dashboard for the TrafficManager Zig backend. It
consumes the backend's REST API and is bundled into a single self-contained
`index.html` that the backend serves from memory.

## Prerequisites

- **Node.js** with **pnpm >= 11.17** (declared in `package.json` under `engines`).
- A running backend started with `--sqlite --web-port <port>` — every dashboard
  call goes to the backend's `/api/*` routes.

## Commands

| Command | What it does |
|---|---|
| `pnpm install` | Install dependencies (Preact, `@preact/signals`, Tailwind v4, Vite, vite-plugin-singlefile, Vitest). |
| `pnpm dev` | Start the Vite dev server on port **5173**. Proxies every `/api` request to the backend at `http://localhost:8080`. Hot-reloads on edit. |
| `pnpm build` | Build a single self-contained `dist/index.html` via `vite-plugin-singlefile`. |
| `pnpm preview` | Preview the production build locally. |
| `pnpm test` | Run the Vitest suite (jsdom + preact preset) over `src/**/*.test.ts(x)`. |
| `pnpm typecheck` | Run `tsc --noEmit` for type checking. |

## Directory structure

```
frontend/
├── package.json        # pnpm >=11.17; scripts: dev / build / preview / test / typecheck
├── tsconfig.json       # strict TS, Preact JSX (jsxImportSource: preact)
├── vite.config.ts      # preact + tailwind + viteSingleFile; dev /api proxy -> :8080
├── vitest.config.ts    # jsdom environment + preact preset; globals enabled
├── index.html          # Vite HTML entry
└── src/
    ├── index.tsx       # Preact mount point (renders <App/> into #app)
    ├── App.tsx         # Real 4-tab dashboard shell (Dashboard/History/Config/Quota)
    ├── api.ts          # REST API client (typed) targeting the backend /api/* endpoints
    ├── format.ts       # Byte formatting (formatBytes) + human-readable size parsing (parseSizeToBytes)
    ├── app.css         # Tailwind CSS entry
    └── components/
        ├── TrafficChart.tsx   # Pure-SVG daily traffic bar chart (no chart library)
        ├── ConfigPanel.tsx    # Configuration form with client-side validation + unit conversion
        └── QuotaManager.tsx   # Quota snapshot, adjustment list, add/delete UI
```

## The four dashboard tabs

| Tab | Purpose | Backend endpoints used |
|---|---|---|
| **Dashboard** | Live RX/TX speed and totals | `GET /api/traffic/current`, `GET /api/status` |
| **Traffic History** | Daily RX/TX totals for the last N days | `GET /api/traffic/daily?days=N` |
| **Config** | View and edit runtime configuration | `GET /api/config`, `PUT /api/config` |
| **Quota** | Monthly quota usage and one-off adjustments | `GET /api/quota`, `GET/POST /api/quota/adjustments`, `DELETE /api/quota/adjustments/:id` |

The full REST contract lives in `backend/src/http_server.zig` (9 endpoints):
`GET /` (dashboard HTML), `/api/status`, `/api/traffic/current`,
`/api/traffic/daily?days=N`, `GET`/`PUT /api/config`, `/api/quota`,
`GET`/`POST /api/quota/adjustments`, and `DELETE /api/quota/adjustments/:id`.

## Implementation notes

- **No chart library**: `TrafficChart.tsx` renders bars with hand-written SVG +
  CSS (Tailwind), keeping the bundle dependency-free.
- **Unit conversion**: `ConfigPanel` accepts human-readable quota strings
  (e.g. `100GB`) and converts them to raw bytes via `parseSizeToBytes` before
  sending `PUT /api/config`.
- **Tests**: component behavior is covered by Vitest + Testing Library under
  `src/*.test.ts` and `src/components/*.test.tsx`.
