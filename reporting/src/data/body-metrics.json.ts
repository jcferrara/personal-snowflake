// Data loader: metrics_daily_body_metrics -> body-metrics.json
//
// Framework runs this at build time and caches the JSON output. The page
// reads it with FileAttachment("data/body-metrics.json").json().

import { emit, query } from "../lib/snowflake.js";

interface Row {
  RECORDED_DATE: string; // 'YYYY-MM-DD' (cast in SQL to dodge timezone shifts)
  SOURCE_APP: string;
  WEIGHT_LB: number | null;
  WEIGHT_LB_7DMA: number | null;
  WEIGHT_LB_14DMA: number | null;
  BODY_FAT_PERCENTAGE: number | null;
  BODY_FAT_PERCENTAGE_7DMA: number | null;
  BODY_FAT_PERCENTAGE_14DMA: number | null;
  BODY_MASS_INDEX: number | null;
  BODY_MASS_INDEX_7DMA: number | null;
  BODY_MASS_INDEX_14DMA: number | null;
}

const sqlText = `
  select
    to_char(recorded_date, 'YYYY-MM-DD') as recorded_date,
    source_app,
    weight_lb,
    weight_lb_7dma,
    weight_lb_14dma,
    body_fat_percentage,
    body_fat_percentage_7dma,
    body_fat_percentage_14dma,
    body_mass_index,
    body_mass_index_7dma,
    body_mass_index_14dma
  from metrics_daily_body_metrics
  order by source_app, recorded_date
`;

const rows = await query<Row>(sqlText);

const out = rows.map((r) => ({
  recorded_date: r.RECORDED_DATE,
  source_app: r.SOURCE_APP,
  weight_lb: r.WEIGHT_LB,
  weight_lb_7dma: r.WEIGHT_LB_7DMA,
  weight_lb_14dma: r.WEIGHT_LB_14DMA,
  body_fat_percentage: r.BODY_FAT_PERCENTAGE,
  body_fat_percentage_7dma: r.BODY_FAT_PERCENTAGE_7DMA,
  body_fat_percentage_14dma: r.BODY_FAT_PERCENTAGE_14DMA,
  body_mass_index: r.BODY_MASS_INDEX,
  body_mass_index_7dma: r.BODY_MASS_INDEX_7DMA,
  body_mass_index_14dma: r.BODY_MASS_INDEX_14DMA,
}));

emit(JSON.stringify(out));
