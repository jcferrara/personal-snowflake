{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [
            ref('stg_market_data__tickers'),
            ref('stg_market_data__daily_prices'),
            ref('int_investment_transactions_unioned'),
            ref('int_investment_lots')
        ],
        ctes = [
            'market_data_tickers',
            'daily_prices',
            'investment_transactions',
            'investment_lots'
        ]
    )
}},

/* Tickers that appear in transactions but not in the market-data
   universe (brokerage-internal symbols such as the MMDA1 cash sweep or
   the 829ESC029 escrow), named from their transaction description. */
transaction_only_tickers as (

    select
        investment_transactions.ticker_symbol,
        max(investment_transactions.transaction_description) as security_name
    from investment_transactions
    left join market_data_tickers
        on investment_transactions.ticker_symbol = market_data_tickers.ticker_symbol
    where investment_transactions.ticker_symbol is not null
        and market_data_tickers.ticker_symbol is null
    group by 1

),

/* Price coverage per ticker. */
price_coverage as (

    select
        ticker_symbol,
        min(price_date) as first_price_date,
        max(price_date) as last_price_date
    from daily_prices
    group by 1

),

/* Ownership history per ticker. */
lot_history as (

    select
        ticker_symbol,
        count(*) as num_lots,
        min(acquired_date) as first_acquired_date
    from investment_lots
    group by 1

),

/* Every security in either the market-data universe or the transaction
   history, one row each. */
securities_unioned as (

    select
        ticker_symbol,
        security_name,
        gics_sector,
        gics_sub_industry,
        curated_category,
        curated_subcategory,
        plaid_security_type,
        is_sp500_constituent,
        is_curated,
        sp500_added_date
    from market_data_tickers

    union all

    select
        ticker_symbol,
        security_name,
        null as gics_sector,
        null as gics_sub_industry,
        null as curated_category,
        null as curated_subcategory,
        null as plaid_security_type,
        false as is_sp500_constituent,
        false as is_curated,
        null as sp500_added_date
    from transaction_only_tickers

),

/* Widen each security with a single classification, price coverage, and
   ownership history. */
securities_enriched as (

    select
        securities_unioned.ticker_symbol,
        securities_unioned.security_name,
        coalesce(
            securities_unioned.curated_category,
            case when securities_unioned.is_sp500_constituent then 'equity' end,
            securities_unioned.plaid_security_type,
            'unclassified'
        ) as security_category,
        securities_unioned.curated_subcategory,
        securities_unioned.gics_sector,
        securities_unioned.gics_sub_industry,
        coalesce(lot_history.num_lots, 0) as num_lots,
        securities_unioned.is_sp500_constituent,
        securities_unioned.is_curated,
        lot_history.ticker_symbol is not null as is_ever_held,
        price_coverage.ticker_symbol is not null as has_market_prices,
        securities_unioned.sp500_added_date,
        lot_history.first_acquired_date,
        price_coverage.first_price_date,
        price_coverage.last_price_date
    from securities_unioned
    left join lot_history
        on securities_unioned.ticker_symbol = lot_history.ticker_symbol
    left join price_coverage
        on securities_unioned.ticker_symbol = price_coverage.ticker_symbol

)

select * from securities_enriched
