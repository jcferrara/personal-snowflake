# Finance semantic views

| View | Grain | Purpose |
| --- | --- | --- |
| `sv_investment_lots` | purchase lot (`fct_investment_lots`) | Current and lifetime returns per purchase, rolled up to ticker, sector, category, purchase year, or the whole portfolio. Includes sold lots. |
| `sv_investment_positions` | lot × day (`fct_investment_lot_daily_values`) | Portfolio value over time (point-in-time metrics, one `date_day`) and purchases / sales / dividends over any period (flow metrics). |

Time-weighted and trailing-period returns (YTD, 1Y, 3Y) need window functions, so
they live in the `metrics_investment_returns_daily` table, not a semantic view.

## sv_investment_lots

```mermaid
erDiagram
    lots }o--|| securities : lots_to_securities
    lots }o--|| acquired_dates : lots_to_acquired_dates
    lots {
        string lot_id PK
        string ticker_symbol FK
        date acquired_date FK
    }
    securities {
        string ticker_symbol PK
    }
    acquired_dates {
        date date_day PK
    }
```

## sv_investment_positions

```mermaid
erDiagram
    lot_days }o--|| securities : lot_days_to_securities
    lot_days }o--|| dates : lot_days_to_dates
    lot_days {
        string lot_day_id PK
        string ticker_symbol FK
        date date_day FK
    }
    securities {
        string ticker_symbol PK
    }
    dates {
        date date_day PK
    }
```
