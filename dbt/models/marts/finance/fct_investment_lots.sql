{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [ref('int_investment_lots'), ref('int_investment_lots_fanned_out_to_day')],
        ctes = ['investment_lots', 'lot_days']
    )
}},

/* Each lot's most recent day: today for open lots, the closing day for
   fully disposed ones. */
latest_lot_days as (

    select *
    from lot_days
    qualify row_number() over (partition by lot_id order by date_day desc) = 1

),

/* One row per purchase lot with its current (or final) valuation and
   lifetime returns. Annualized return is only shown once a lot has been
   held a year, since annualizing shorter periods exaggerates it. */
lots_with_returns as (

    select
        investment_lots.lot_id,
        investment_lots.ticker_symbol,
        investment_lots.transaction_source,
        latest_lot_days.price_source,
        investment_lots.fifo_sequence_number,
        investment_lots.lot_quantity,
        latest_lot_days.quantity_open,
        investment_lots.purchase_price_per_share_usd,
        investment_lots.purchase_amount_usd,
        investment_lots.cost_basis_usd,
        investment_lots.cost_basis_per_share_usd,
        investment_lots.cost_basis_adjustment_usd,
        latest_lot_days.cost_basis_open_usd,
        latest_lot_days.close_price_usd,
        latest_lot_days.market_value_usd,
        latest_lot_days.unrealized_gain_usd,
        latest_lot_days.unrealized_gain_usd / nullif(latest_lot_days.cost_basis_open_usd, 0) as unrealized_gain_pct,
        latest_lot_days.cumulative_proceeds_usd as proceeds_usd,
        latest_lot_days.cumulative_realized_gain_usd as realized_gain_usd,
        latest_lot_days.cumulative_dividend_income_usd as dividend_income_usd,
        latest_lot_days.total_return_usd,
        latest_lot_days.total_return_pct,
        datediff('day', investment_lots.acquired_date, latest_lot_days.date_day) as num_days_held,
        case
            when datediff('day', investment_lots.acquired_date, latest_lot_days.date_day) >= 365
                then power(
                    1 + latest_lot_days.total_return_pct,
                    365 / datediff('day', investment_lots.acquired_date, latest_lot_days.date_day)
                ) - 1
        end as annualized_return_pct,
        not latest_lot_days.is_closed as is_open,
        investment_lots.is_synthetic,
        investment_lots.acquired_date,
        latest_lot_days.closed_date,
        latest_lot_days.date_day as valued_as_of_date,
        latest_lot_days.price_date
    from investment_lots
    inner join latest_lot_days
        on investment_lots.lot_id = latest_lot_days.lot_id

)

select * from lots_with_returns
