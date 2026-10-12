{{ config(materialized='semantic_view') }}

TABLES(
    lots AS {{ ref('fct_investment_lots') }}
        PRIMARY KEY (lot_id)
        WITH SYNONYMS = ('purchase lots', 'tax lots', 'purchases', 'buys', 'investments')
        COMMENT = 'One row per purchase lot (every buy is a lot) with its current valuation, or its final one if fully sold, and lifetime returns. Sales are matched to lots first-in-first-out.',
    securities AS {{ ref('dim_securities') }}
        PRIMARY KEY (ticker_symbol)
        WITH SYNONYMS = ('tickers', 'holdings', 'stocks', 'funds', 'ETFs')
        COMMENT = 'One row per security: name, category, and GICS sector.',
    acquired_dates AS {{ ref('dim_dates') }}
        PRIMARY KEY (date_day)
        COMMENT = 'Calendar dimension, joined on the date each lot was bought.'
)

RELATIONSHIPS(
    lots_to_securities AS
        lots (ticker_symbol) REFERENCES securities,
    lots_to_acquired_dates AS
        lots (acquired_date) REFERENCES acquired_dates
)

DIMENSIONS(
    lots.lot_id AS lot_id
        WITH SYNONYMS = ('lot', 'purchase', 'buy transaction', 'transaction id')
        COMMENT = 'Purchase lot id: the transaction id of the buy that opened it.',
    lots.acquired_date AS acquired_date
        WITH SYNONYMS = ('purchase date', 'buy date', 'date bought')
        COMMENT = 'Date the lot was bought.',
    lots.closed_date AS closed_date
        WITH SYNONYMS = ('sold date', 'sale date', 'date fully sold')
        COMMENT = 'Date the last share of the lot was sold; null while still held.',
    lots.is_open AS is_open
        WITH SYNONYMS = ('currently held', 'still held', 'open position')
        COMMENT = 'True while any shares of the lot are still held. Filter to true for current holdings only.',
    lots.is_synthetic AS is_synthetic
        COMMENT = 'True when the buy was reconstructed by hand to close a gap in brokerage exports.',
    lots.price_source AS price_source
        COMMENT = 'market_close, or cost_basis_no_market_data when no market price exists (BLCN).',
    lots.transaction_source AS transaction_source
        COMMENT = 'manual_historical (brokerage export) or plaid (live connection).',
    securities.ticker_symbol AS ticker_symbol
        WITH SYNONYMS = ('ticker', 'symbol', 'holding', 'stock', 'fund')
        COMMENT = 'Security ticker (e.g. SPY, QQQ).',
    securities.security_name AS security_name
        WITH SYNONYMS = ('name', 'fund name', 'company')
        COMMENT = 'Security name.',
    securities.security_category AS security_category
        WITH SYNONYMS = ('asset class', 'category', 'type')
        COMMENT = 'Classification: curated category (broad_market, sector, industry, fixed_income, ...), equity for S&P 500 stocks, else the Plaid security type.',
    securities.curated_subcategory AS curated_subcategory
        WITH SYNONYMS = ('theme', 'subcategory', 'segment')
        COMMENT = 'Curated subcategory for ETFs (e.g. semiconductors, us_large_cap).',
    securities.gics_sector AS gics_sector
        WITH SYNONYMS = ('sector', 'industry sector')
        COMMENT = 'GICS sector, for S&P 500 stocks only.',
    acquired_dates.acquired_year AS acquired_dates.year_number
        WITH SYNONYMS = ('purchase year', 'year bought')
        COMMENT = 'Calendar year the lot was bought.',
    acquired_dates.acquired_month AS acquired_dates.month_start_date
        WITH SYNONYMS = ('purchase month', 'month bought')
        COMMENT = 'First day of the month the lot was bought.'
)

METRICS(
    lots.num_lots AS COUNT(lots.lot_id)
        WITH SYNONYMS = ('number of lots', 'number of purchases', 'lot count')
        COMMENT = 'Number of purchase lots.',
    lots.quantity_open AS SUM(lots.quantity_open)
        WITH SYNONYMS = ('shares', 'shares held', 'share count', 'position size')
        COMMENT = 'Shares currently held, in today''s share basis (split-adjusted).',
    lots.purchase_amount_usd AS SUM(lots.purchase_amount_usd)
        WITH SYNONYMS = ('amount invested', 'cash invested', 'money put in', 'purchase cost')
        COMMENT = 'Cash paid for the lots, including fees.',
    lots.cost_basis_usd AS SUM(lots.cost_basis_usd)
        WITH SYNONYMS = ('total cost basis', 'original cost basis')
        COMMENT = 'Brokerage cost basis of the full lots, held and sold shares together.',
    lots.cost_basis_open_usd AS SUM(lots.cost_basis_open_usd)
        WITH SYNONYMS = ('cost basis', 'cost of current holdings', 'book value')
        COMMENT = 'Cost basis of the shares still held.',
    lots.market_value_usd AS SUM(lots.market_value_usd)
        WITH SYNONYMS = ('current value', 'market value', 'portfolio value', 'worth', 'balance')
        COMMENT = 'Current market value of the shares still held (latest close).',
    lots.unrealized_gain_usd AS SUM(lots.unrealized_gain_usd)
        WITH SYNONYMS = ('unrealized gain', 'paper gain', 'unrealized profit', 'unrealized loss')
        COMMENT = 'Market value minus cost basis of the shares still held.',
    lots.proceeds_usd AS SUM(lots.proceeds_usd)
        WITH SYNONYMS = ('sale proceeds', 'cash from sales')
        COMMENT = 'Lifetime cash received from selling or liquidating shares of the lots.',
    lots.realized_gain_usd AS SUM(lots.realized_gain_usd)
        WITH SYNONYMS = ('realized gain', 'realized profit', 'realized loss', 'gain on sales')
        COMMENT = 'Lifetime realized gain on shares sold (proceeds minus FIFO cost basis).',
    lots.dividend_income_usd AS SUM(lots.dividend_income_usd)
        WITH SYNONYMS = ('dividends', 'dividend income', 'distributions')
        COMMENT = 'Lifetime dividends received by the lots.',
    lots.total_return_usd AS SUM(lots.total_return_usd)
        WITH SYNONYMS = ('total return', 'total gain', 'profit', 'how much I made', 'net gain')
        COMMENT = 'Current market value + sale proceeds + dividends - cash invested: everything the lots produced, net of what they cost. Includes closed lots unless filtered by is_open.',
    lots.total_return_pct AS lots.total_return_usd / NULLIF(lots.purchase_amount_usd, 0)
        WITH SYNONYMS = ('return', 'percent return', 'return on investment', 'ROI', 'performance')
        COMMENT = 'Total return as a fraction of cash invested (0.25 = 25%). Money-weighted by lot size, not time-weighted; for time-weighted returns use metrics_investment_returns_daily.',
    lots.unrealized_gain_pct AS lots.unrealized_gain_usd / NULLIF(lots.cost_basis_open_usd, 0)
        WITH SYNONYMS = ('unrealized return', 'percent unrealized gain')
        COMMENT = 'Unrealized gain as a fraction of the cost basis still held.'
)

COMMENT = 'Investment lots: current and lifetime returns per purchase, rolled up to any ticker, sector, category, or the whole portfolio. Use for "how much have I made on X", "current value", "returns by holding", "best and worst purchases". Includes fully sold lots (filter is_open = true for current holdings only). Point-in-time history (value on a past date, dividends in a period) is in sv_investment_positions; time-weighted and trailing-period returns (YTD, 1Y, 3Y) are in the metrics_investment_returns_daily table.'
