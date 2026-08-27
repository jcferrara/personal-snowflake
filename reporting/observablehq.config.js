// Observable Framework configuration.
// See https://observablehq.com/framework/config for all options.

export default {
  title: "Personal Snowflake Reporting",

  // Source root for pages, components, and data loaders.
  root: "src",

  // Left-nav structure. Add an entry per dashboard.
  pages: [
    {
      name: "Health",
      pages: [{ name: "Body metrics", path: "/body-metrics" }],
    },
  ],

  toc: true,
  pager: true,

  // Deployment target is intentionally left unset. When ready, either:
  //   - `npm run deploy` to Observable Cloud (fills in `deploy` on first run), or
  //   - `npm run build` and point any static host at `dist/`.
};
