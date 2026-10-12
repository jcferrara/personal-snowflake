{{ config(materialized='semantic_view') }}

TABLES(
    lot_days AS {{ ref('fct_investment_lot_daily_values') }}
        PRIMARY KEY (lot_day_id)
        WITH SYNONYMS = ('positions', 'daily positions', 'holdings history', 'portfolio history')
        COMMENT = 'One row per purchase lot per calendar day held, valued at the latest close on or before that day, with that day''s purchases, sales, and dividends.',
    securities AS {{ ref('dim_securities') }}
        PRIMARY KEY (ticker_symbol)
        WITH SYNONYMS = ('tickers', 'holdings', 'stocks', 'funds', 'ETFs')
        COMMENT = 'One row per security: name, category, and GICS sector.',
    dates AS {{ ref('dim_dates') }}
        PRIMARY KEY (date_day)
        COMMENT = 'Calendar dimension for the valuation day.'
)

RELATIONSHIPS(
    lot_days_to_securities AS
        lot_days (ticker_symbol) REFERENCES securities,
    lot_days_to_dates AS
        lot_days (date_day) REFERENCES dates
)

DIMENSIONS(
    lot_days.lot_id AS lot_id
        WITH SYNONYMS = ('lot', 'purchase', 'buy transaction')
        COMMENT = 'Purchase lot id: the transaction id of the buy that opened it.',
    lot_days.acquired_date AS acquired_date
        WITH SYNONYMS = ('purchase date', 'buy date')
        COMMENT = 'Date the lot was bought.',
    lot_days.price_source AS price_source
        COMMENT = 'market_close, or cost_basis_no_market_data when no market price exists (BLCN).',
    securities.ticker_symbol AS ticker_symbol
        WITH SYNONYMS = ('ticker', 'symbol', 'holding', 'stock', 'fund')
        COMMENT = 'Security ticker (e.g. SPY, QQQ).',
    securities.security_name AS security_name
        WITH SYNONYMS = ('name', 'fund name', 'company')
        COMMENT = 'Security name.',
    securities.security_category AS security_category
        WITH SYNONYMS = ('asset class', 'category', 'type')
        COMMENT = 'Classification: curated category (broad_market, sector, industry, fixed_income, ...), equity for S&P 500 stocks, else the Plaid security type.',
    securities.gics_sector AS gics_sector
        WITH SYNONYMS = ('sector', 'industry sector')
        COMMENT = 'GICS sector, for S&P 500 stocks only.',
    dates.date_day AS date_day
        WITH SYNONYMS = ('date', 'as of date', 'valuation date', 'day')
        COMMENT = 'Calendar day being valued. Point-in-time metrics need exactly one date_day.',
    dates.calendar_month AS dates.month_start_date
        WITH SYNONYMS = ('month', 'calendar month')
        COMMENT = 'First day of the month.',
    dates.calendar_year AS dates.year_number
        WITH SYNONYMS = ('year', 'calendar year')
        COMMENT = 'Calendar year.',
    dates.is_last_day_of_month AS is_last_day_of_month
        WITH SYNONYMS = ('month end', 'end of month')
        COMMENT = 'True on the last calendar day of the month: filter to it for month-end balances.'
)

METRICS(
    lot_days.market_value_usd AS SUM(lot_days.market_value_usd)
        WITH SYNONYMS = ('value', 'market value', 'portfolio value', 'balance', 'worth')
        COMMENT = 'POINT-IN-TIME: market value of shares held at the end of the day. Filter to a single date_day (or is_last_day_of_month and group by month); summing across days is meaningless.',
    lot_days.quantity_open AS SUM(lot_days.quantity_open)
        WITH SYNONYMS = ('shares', 'shares held', 'position size')
        COMMENT = 'POINT-IN-TIME: shares held at the end of the day (split-adjusted). Filter to a single date_day.',
    lot_days.cost_basis_open_usd AS SUM(lot_days.cost_basis_open_usd)
        WITH SYNONYMS = ('cost basis', 'book value')
        COMMENT = 'POINT-IN-TIME: cost basis of shares held at the end of the day. Filter to a single date_day.',
    lot_days.unrealized_gain_usd AS SUM(lot_days.unrealized_gain_usd)
        WITH SYNONYMS = ('unrealized gain', 'paper gain')
        COMMENT = 'POINT-IN-TIME: market value minus cost basis of shares held. Filter to a single date_day.',
    lot_days.purchase_amount_usd AS SUM(lot_days.purchase_amount_usd)
        WITH SYNONYMS = ('amount invested in held lots')
        COMMENT = 'POINT-IN-TIME: cash originally paid for the lots held that day. Filter to a single date_day.',
    lot_days.total_return_usd AS SUM(lot_days.total_return_usd)
        WITH SYNONYMS = ('total return to date', 'gain to date')
        COMMENT = 'POINT-IN-TIME: lifetime return to date of the lots held that day (value + proceeds + dividends - cash paid). Lots fully sold before that day drop out; for lifetime totals including sold lots use sv_investment_lots.',
    lot_days.total_return_pct AS lot_days.total_return_usd / NULLIF(lot_days.purchase_amount_usd, 0)
        WITH SYNONYMS = ('return to date', 'percent return')
        COMMENT = 'POINT-IN-TIME: total_return_usd / purchase_amount_usd for the lots held that day.',
    lot_days.purchases_usd AS SUM(lot_days.purchases_usd)
        WITH SYNONYMS = ('purchases', 'amount bought', 'money invested', 'contributions')
        COMMENT = 'FLOW: cash spent buying shares over the selected days. Safe to sum over any date range.',
    lot_days.proceeds_usd AS SUM(lot_days.proceeds_usd)
        WITH SYNONYMS = ('sale proceeds', 'amount sold', 'cash from sales')
        COMMENT = 'FLOW: cash received from sales and liquidations over the selected days.',
    lot_days.realized_gain_usd AS SUM(lot_days.realized_gain_usd)
        WITH SYNONYMS = ('realized gain', 'realized loss', 'gain on sales')
        COMMENT = 'FLOW: realized gain (proceeds minus FIFO cost basis) on shares sold over the selected days.',
    lot_days.dividend_income_usd AS SUM(lot_days.dividend_income_usd)
        WITH SYNONYMS = ('dividends', 'dividend income', 'distributions')
        COMMENT = 'FLOW: dividends received over the selected days.'
)

COMMENT = 'Investment positions over time: daily value, cost basis, and gains for every purchase lot, plus purchases, sales, and dividends by day. Metrics are either POINT-IN-TIME (filter to exactly one date_day, or month-ends) or FLOW (sum over any date range); each metric comment says which. Use for "what was my portfolio worth on X", "month-end value by holding", "dividends this year", "how much did I buy in 2025". Current and lifetime per-lot returns are in sv_investment_lots; time-weighted returns are in metrics_investment_returns_daily.'
