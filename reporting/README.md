# reporting

[Observable Framework](https://observablehq.com/framework) app that turns the
`ANALYTICS` database in Snowflake — the marts and metrics built by the
[`dbt/`](../dbt) project — into static dashboards.

```
reporting/
├── observablehq.config.js   site config + left-nav structure
├── package.json             @observablehq/framework, snowflake-sdk, dotenv
├── tsconfig.json
├── .env.example             Snowflake connection template (copy to .env)
└── src/
    ├── index.md             landing page
    ├── body-metrics.md      sample dashboard (metrics_daily_body_metrics)
    ├── data/
    │   └── body-metrics.json.ts   data loader — queries Snowflake at build time
    └── lib/
        └── snowflake.ts     shared key-pair-auth Snowflake client
```

## Prerequisites

- **Node.js >= 18** and npm (not currently installed on this machine — install
  via [nvm](https://github.com/nvm-sh/nvm) or `brew install node`).
- A Snowflake key-pair already trusted for your user (the same `.p8` the `dbt/`
  and `extraction/` components use).

## Setup

```bash
cd reporting
npm install
cp .env.example .env         # then edit .env with your account / key path
```

`.env` values (see `.env.example` for the full list):

| Var | Default | Notes |
| --- | --- | --- |
| `SNOWFLAKE_ACCOUNT` | — | account locator, e.g. `xxxxxxx-xxxxxxx` |
| `SNOWFLAKE_USER` | — | your Snowflake username |
| `SNOWFLAKE_PRIVATE_KEY_PATH` | — | absolute path to the `.p8` key |
| `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` | _(none)_ | omit if the key is unencrypted |
| `SNOWFLAKE_ROLE` | `TRANSFORMER` | |
| `SNOWFLAKE_WAREHOUSE` | `TRANSFORM_WH` | |
| `SNOWFLAKE_DATABASE` | `ANALYTICS` | set to `ANALYTICS_DEV` to preview un-promoted models |
| `SNOWFLAKE_SCHEMA` | `PROD` | set to your dev schema to match |

> The placeholder values in `.env.example` are exactly that — placeholders.
> Nothing real is committed; `.env` is gitignored.

## Running

```bash
npm run dev      # local dev server with live reload at http://localhost:3000
npm run build    # static build into dist/
npm run clean    # clear the data-loader cache
```

`npm run dev` runs each data loader on first request and caches the result under
`.observablehq/cache/`. Delete that dir (or `npm run clean`) to force a refresh
against Snowflake.

## How data loading works

Framework has no built-in Snowflake connector — a **data loader** is just a script
whose stdout becomes a served file. `src/data/body-metrics.json.ts`:

1. builds a SQL string against `metrics_daily_body_metrics`,
2. calls `query()` from `src/lib/snowflake.ts`, which opens a one-shot key-pair
   (`SNOWFLAKE_JWT`) connection using the `.env` settings,
3. writes the rows to stdout as JSON.

The page then reads it entirely client-side:

```js
const raw = FileAttachment("data/body-metrics.json").json();
```

Snowflake is only ever touched at build time; the deployed site is static.

## Adding a dashboard

1. **Data loader** — add `src/data/<name>.<type>.ts` (`.json`, `.csv`, …). Import
   `query` and `emit` from `src/lib/snowflake.ts`: `query(sql)` runs one
   statement; `emit(string)` writes the loader's output (use it instead of
   `process.stdout.write` / `console.log` — the shared module redirects stdout so
   the Snowflake SDK's logging can't corrupt the output). Cast `DATE`/`TIMESTAMP`
   columns to strings in SQL (`to_char(...)`) so no timezone shift happens on the
   way out.
2. **Page** — add `src/<name>.md`, load the file with `FileAttachment`, chart with
   `Plot`.
3. **Nav** — add the page to `pages` in `observablehq.config.js`.

The referenced model must exist in the database/schema `.env` points at. Marts and
metrics on an un-merged branch only exist in your dev schema until the branch
merges to `main` and the scheduled `dbt build` promotes them to `ANALYTICS.PROD` —
point `SNOWFLAKE_DATABASE`/`SNOWFLAKE_SCHEMA` at `ANALYTICS_DEV`/your dev schema to
preview against those in the meantime.

## Deployment

Not wired up yet. Options when ready:

- **Observable Cloud** — `npm run deploy` (populates `deploy` in the config on
  first run).
- **Static host** — `npm run build`, publish `dist/` anywhere (GitHub Pages, S3,
  Cloudflare Pages, …).
- **CI** — a GitHub Actions workflow mirroring `dbt_run.yml` (restore the key from
  `SNOWFLAKE_PRIVATE_KEY_B64`, `npm ci`, `npm run build`, publish) is the natural
  next step. Deliberately left out of this initial scaffold.
