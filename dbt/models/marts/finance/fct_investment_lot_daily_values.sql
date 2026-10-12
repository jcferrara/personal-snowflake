{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [ref('int_investment_lots_fanned_out_to_day')],
        ctes = ['lot_days']
    )
}},

/* Persist the lot-day valuation history as the analyst-facing daily
   fact; ticker and portfolio rollups aggregate from here. */
lot_daily_values as (

    select
        sk as lot_day_id,
        lot_id,
        ticker_symbol,
        price_source,
        quantity_open,
        quantity_open_at_day_start,
        disposed_quantity,
        close_price_usd,
        market_value_usd,
        -- lot-level constants carried onto every day so point-in-time return
        -- ratios can be computed from this fact alone (e.g. in a semantic view)
        purchase_amount_usd,
        purchases_usd,
        cost_basis_open_usd,
        unrealized_gain_usd,
        proceeds_usd,
        cost_basis_relieved_usd,
        realized_gain_usd,
        dividend_income_usd,
        cumulative_proceeds_usd,
        cumulative_realized_gain_usd,
        cumulative_dividend_income_usd,
        total_return_usd,
        total_return_pct,
        is_closed,
        acquired_date,
        date_day,
        price_date
    from lot_days

)

select * from lot_daily_values
