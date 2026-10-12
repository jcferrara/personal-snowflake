-- Every dividend dollar received must land on some lot. Dividends are split
-- across the lots open at the start of the pay date, so a dividend paid when
-- no lot of that ticker was open at the start of the day (e.g. paid after
-- the position was fully sold, or on the day it was first bought) is
-- silently dropped from returns; this test surfaces that.

with

{{
    import_models(
        refs = [ref('fct_investment_transactions'), ref('fct_investment_lot_daily_values')],
        ctes = ['investment_transactions', 'lot_daily_values']
    )
}},

dividends_received as (

    select
        ticker_symbol,
        trade_date,
        sum(cash_amount_usd) as dividends_received_usd
    from investment_transactions
    where transaction_category = 'dividend'
    group by 1, 2

),

dividends_allocated as (

    select
        ticker_symbol,
        date_day,
        sum(dividend_income_usd) as dividends_allocated_usd
    from lot_daily_values
    group by 1, 2

),

dividends_compared as (

    select
        dividends_received.ticker_symbol,
        dividends_received.trade_date,
        dividends_received.dividends_received_usd,
        coalesce(dividends_allocated.dividends_allocated_usd, 0) as dividends_allocated_usd
    from dividends_received
    left join dividends_allocated
        on dividends_received.ticker_symbol = dividends_allocated.ticker_symbol
        and dividends_received.trade_date = dividends_allocated.date_day

)

select *
from dividends_compared
where abs(dividends_received_usd - dividends_allocated_usd) > 0.01
