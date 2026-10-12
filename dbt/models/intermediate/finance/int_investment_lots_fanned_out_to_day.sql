-- Table rather than the intermediate-default view: this view nests the
-- transaction, lot, and FIFO views several times over, and Snowflake spent
-- ~50-80s just compiling each downstream fact that inlined it. Building it
-- once per run keeps both lot facts fast; it is rebuilt in full every run.
{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [
            ref('int_investment_lots'),
            ref('int_investment_lot_disposals_matched'),
            ref('int_investment_transactions_unioned'),
            ref('stg_market_data__daily_prices'),
            ref('int_dates_spine')
        ],
        ctes = [
            'investment_lots',
            'lot_disposals',
            'investment_transactions',
            'daily_prices',
            'dates'
        ]
    )
}},

/* A lot closes on the day its last share is disposed; lots never fully
   disposed stay open through today. The small tolerance absorbs float
   drift from split-adjusted quantities. */
lot_closings as (

    select
        lot_disposals.lot_id,
        max(lot_disposals.disposed_date) as closed_date
    from lot_disposals
    inner join investment_lots
        on lot_disposals.lot_id = investment_lots.lot_id
    group by lot_disposals.lot_id, investment_lots.lot_quantity
    having sum(lot_disposals.matched_quantity) >= investment_lots.lot_quantity - 0.000001

),

/* Fan each lot out to one row per calendar day from acquisition through
   its closing day (or today), so weekends and holidays carry the last
   close forward. */
lot_days as (

    select
        investment_lots.lot_id,
        investment_lots.ticker_symbol,
        investment_lots.lot_quantity,
        investment_lots.purchase_amount_usd,
        investment_lots.cost_basis_usd,
        investment_lots.cost_basis_per_share_usd,
        investment_lots.acquired_date,
        lot_closings.closed_date,
        dates.date_day
    from investment_lots
    left join lot_closings
        on investment_lots.lot_id = lot_closings.lot_id
    inner join dates
        on dates.date_day between investment_lots.acquired_date
            and coalesce(lot_closings.closed_date, current_date)

),

/* Collapse the FIFO matches to one row per lot per disposal day. */
lot_disposals_by_day as (

    select
        lot_id,
        disposed_date,
        sum(matched_quantity) as disposed_quantity,
        sum(proceeds_usd) as proceeds_usd,
        sum(cost_basis_relieved_usd) as cost_basis_relieved_usd,
        sum(realized_gain_usd) as realized_gain_usd
    from lot_disposals
    group by 1, 2

),

/* Running share counts per lot: shares open at the end of each day, and
   at the start of it (zero on the acquisition day, so a lot bought on a
   dividend's pay date doesn't share in that dividend). */
lot_days_with_quantities as (

    select
        lot_days.lot_id,
        lot_days.ticker_symbol,
        lot_days.lot_quantity,
        lot_days.purchase_amount_usd,
        lot_days.cost_basis_usd,
        lot_days.cost_basis_per_share_usd,
        coalesce(lot_disposals_by_day.disposed_quantity, 0) as disposed_quantity,
        coalesce(lot_disposals_by_day.proceeds_usd, 0) as proceeds_usd,
        coalesce(lot_disposals_by_day.cost_basis_relieved_usd, 0) as cost_basis_relieved_usd,
        coalesce(lot_disposals_by_day.realized_gain_usd, 0) as realized_gain_usd,
        lot_days.lot_quantity - sum(coalesce(lot_disposals_by_day.disposed_quantity, 0)) over (
            partition by lot_days.lot_id
            order by lot_days.date_day
            rows between unbounded preceding and current row
        ) as quantity_open,
        case
            when lot_days.date_day = lot_days.acquired_date then 0
            else lot_days.lot_quantity - sum(coalesce(lot_disposals_by_day.disposed_quantity, 0)) over (
                partition by lot_days.lot_id
                order by lot_days.date_day
                rows between unbounded preceding and 1 preceding
            )
        end as quantity_open_at_day_start,
        lot_days.acquired_date,
        lot_days.closed_date,
        lot_days.date_day
    from lot_days
    left join lot_disposals_by_day
        on lot_days.lot_id = lot_disposals_by_day.lot_id
        and lot_days.date_day = lot_disposals_by_day.disposed_date

),

/* Limit the price scan to tickers that were ever held. */
held_tickers as (

    select distinct ticker_symbol
    from investment_lots

),

held_ticker_prices as (

    select
        daily_prices.ticker_symbol,
        daily_prices.close_price_usd,
        daily_prices.price_date
    from daily_prices
    inner join held_tickers
        on daily_prices.ticker_symbol = held_tickers.ticker_symbol

),

/* Value each lot-day at the most recent close on or before that day.
   Tickers Yahoo doesn't carry (BLCN, delisted after liquidation) fall
   back to the lot's cost basis per share, flagged by price_source. */
lot_days_priced as (

    select
        lot_days_with_quantities.*,
        coalesce(
            held_ticker_prices.close_price_usd,
            lot_days_with_quantities.cost_basis_per_share_usd
        ) as close_price_usd,
        case
            when held_ticker_prices.close_price_usd is not null then 'market_close'
            else 'cost_basis_no_market_data'
        end as price_source,
        held_ticker_prices.price_date
    from lot_days_with_quantities
    asof join held_ticker_prices
        match_condition (lot_days_with_quantities.date_day >= held_ticker_prices.price_date)
        on lot_days_with_quantities.ticker_symbol = held_ticker_prices.ticker_symbol

),

/* Dividend cash received per ticker per pay date. */
dividends_by_ticker_day as (

    select
        ticker_symbol,
        trade_date,
        sum(cash_amount_usd) as dividend_income_usd
    from investment_transactions
    where transaction_category = 'dividend'
    group by 1, 2

),

/* Allocate each dividend to the lots open at the start of the pay date,
   pro rata by shares. Exact when every lot was held through the ex-date,
   which pay-date holdings approximate. */
lot_days_with_dividends as (

    select
        lot_days_priced.*,
        coalesce(
            dividends_by_ticker_day.dividend_income_usd
            * lot_days_priced.quantity_open_at_day_start
            / nullif(
                sum(lot_days_priced.quantity_open_at_day_start) over (
                    partition by lot_days_priced.ticker_symbol, lot_days_priced.date_day
                ),
                0
            ),
            0
        ) as dividend_income_usd
    from lot_days_priced
    left join dividends_by_ticker_day
        on lot_days_priced.ticker_symbol = dividends_by_ticker_day.ticker_symbol
        and lot_days_priced.date_day = dividends_by_ticker_day.trade_date

),

/* Daily lot valuation plus running totals since acquisition. Total return
   compares everything the lot has produced (market value, sale proceeds,
   dividends) against the cash paid for it. */
lot_days_valued as (

    select
        {{ dbt_utils.generate_surrogate_key(['lot_id', 'date_day']) }} as sk,
        lot_id,
        ticker_symbol,
        price_source,
        lot_quantity,
        quantity_open,
        quantity_open_at_day_start,
        disposed_quantity,
        close_price_usd,
        quantity_open * close_price_usd as market_value_usd,
        purchase_amount_usd,
        case when date_day = acquired_date then purchase_amount_usd else 0 end as purchases_usd,
        cost_basis_usd,
        cost_basis_usd * quantity_open / lot_quantity as cost_basis_open_usd,
        quantity_open * close_price_usd
            - cost_basis_usd * quantity_open / lot_quantity as unrealized_gain_usd,
        proceeds_usd,
        cost_basis_relieved_usd,
        realized_gain_usd,
        dividend_income_usd,
        sum(proceeds_usd) over (
            partition by lot_id order by date_day rows between unbounded preceding and current row
        ) as cumulative_proceeds_usd,
        sum(realized_gain_usd) over (
            partition by lot_id order by date_day rows between unbounded preceding and current row
        ) as cumulative_realized_gain_usd,
        sum(dividend_income_usd) over (
            partition by lot_id order by date_day rows between unbounded preceding and current row
        ) as cumulative_dividend_income_usd,
        quantity_open = 0 as is_closed,
        acquired_date,
        closed_date,
        price_date,
        date_day
    from lot_days_with_dividends

),

/* Total return to date, in dollars and as a share of purchase cash. */
lot_days_with_total_return as (

    select
        *,
        market_value_usd
            + cumulative_proceeds_usd
            + cumulative_dividend_income_usd
            - purchase_amount_usd as total_return_usd,
        (
            market_value_usd
            + cumulative_proceeds_usd
            + cumulative_dividend_income_usd
            - purchase_amount_usd
        ) / nullif(purchase_amount_usd, 0) as total_return_pct
    from lot_days_valued

)

select * from lot_days_with_total_return
