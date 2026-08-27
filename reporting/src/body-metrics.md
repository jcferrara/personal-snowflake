# Body metrics

Weight, body-fat percentage, and BMI over time, with 7- and 14-day moving
averages. Source: `ANALYTICS.PROD.metrics_daily_body_metrics` (one row per
calendar day per source app).

```js
const raw = FileAttachment("data/body-metrics.json").json();
```

```js
// Coerce the ISO day string to a Date once, up front.
const data = raw.map((d) => ({ ...d, recorded_date: new Date(`${d.recorded_date}T00:00:00`) }));
```

```js
const sources = Array.from(new Set(data.map((d) => d.source_app))).sort();
const source = view(
  Inputs.select(sources, { label: "Source app", value: sources[0] }),
);
```

```js
const rows = data
  .filter((d) => d.source_app === source)
  .sort((a, b) => a.recorded_date - b.recorded_date);
const latest = rows.filter((d) => d.weight_lb_7dma != null).at(-1);
const fmt = (v, digits = 1, suffix = "") =>
  v == null ? "—" : v.toFixed(digits) + suffix;
```

<div class="grid grid-cols-3">
  <div class="card">
    <h2>Weight · 7-day avg</h2>
    <span class="big">${latest ? fmt(latest.weight_lb_7dma) : "—"} lb</span>
  </div>
  <div class="card">
    <h2>Body fat · 7-day avg</h2>
    <span class="big">${latest ? fmt(latest.body_fat_percentage_7dma, 1, "%") : "—"}</span>
  </div>
  <div class="card">
    <h2>BMI · 7-day avg</h2>
    <span class="big">${latest ? fmt(latest.body_mass_index_7dma) : "—"}</span>
  </div>
</div>

```js
// Raw daily readings as faint dots, 14-day average as a thin grey line,
// 7-day average as the bold line.
function trend(pointKey, ma7Key, ma14Key, { label } = {}) {
  return Plot.plot({
    width,
    height: 260,
    marginLeft: 52,
    y: { label, grid: true },
    x: { label: null, type: "time" },
    marks: [
      Plot.dot(rows, {
        x: "recorded_date",
        y: pointKey,
        r: 1.5,
        fill: "currentColor",
        fillOpacity: 0.25,
      }),
      Plot.line(rows, {
        x: "recorded_date",
        y: ma14Key,
        stroke: "currentColor",
        strokeOpacity: 0.4,
        strokeWidth: 1,
      }),
      Plot.line(rows, {
        x: "recorded_date",
        y: ma7Key,
        stroke: "var(--theme-foreground-focus)",
        strokeWidth: 2,
      }),
      Plot.tip(
        rows,
        Plot.pointerX({
          x: "recorded_date",
          y: ma7Key,
          title: (d) =>
            `${d.recorded_date.toISOString().slice(0, 10)}\n${label}\n` +
            `reading: ${d[pointKey] ?? "—"}\n7d avg: ${d[ma7Key]?.toFixed(2) ?? "—"}\n14d avg: ${d[ma14Key]?.toFixed(2) ?? "—"}`,
        }),
      ),
    ],
  });
}
```

## Weight (lb)

```js
trend("weight_lb", "weight_lb_7dma", "weight_lb_14dma", { label: "Weight (lb)" })
```

## Body fat (%)

```js
trend("body_fat_percentage", "body_fat_percentage_7dma", "body_fat_percentage_14dma", {
  label: "Body fat (%)",
})
```

## BMI

```js
trend("body_mass_index", "body_mass_index_7dma", "body_mass_index_14dma", { label: "BMI" })
```

<div class="note">

Dots are individual daily readings; the bold line is the 7-day moving average and
the faint line the 14-day. Gap days (no reading) are skipped in both windows —
see the `metrics_daily_body_metrics` model docs.

</div>
