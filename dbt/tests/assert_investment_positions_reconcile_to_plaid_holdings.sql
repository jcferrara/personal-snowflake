-- Today's share count per ticker, rebuilt from transaction history (manual
-- file before the Plaid cutover, Plaid transactions after), must match the
-- holdings Plaid reports right now. A failure means a position-changing
-- event is missing or mis-categorized: e.g. a Plaid in-kind transfer or
-- split arriving as category 'other', or a Plaid holdings refresh that
-- landed a trade before its transaction. Cash and Plaid's ticker-less
-- escrow rows have no lots, so only ticker-bearing securities are compared.

with

{{
    import_models(
        refs = [
            ref('fct_investment_lot_daily_values'),
            ref('stg_plaid__holdings'),
            ref('stg_plaid__securities')
        ],
        ctes = ['lot_daily_values', 'plaid_holdings', 'plaid_securities']
    )
}},

modeled_positions as (

    select
        ticker_symbol,
        sum(quantity_open) as modeled_quantity
    from lot_daily_values
    where date_day = current_date
    group by 1

),

plaid_positions as (

    select
        plaid_securities.ticker_symbol,
        sum(plaid_holdings.quantity) as plaid_quantity
    from plaid_holdings
    inner join plaid_securities
        on plaid_holdings.security_id = plaid_securities.security_id
    where plaid_securities.ticker_symbol is not null
        and coalesce(plaid_securities.security_type, '') <> 'cash'
        and not coalesce(plaid_securities.is_cash_equivalent, false)
    group by 1

),

positions_compared as (

    select
        coalesce(modeled_positions.ticker_symbol, plaid_positions.ticker_symbol) as ticker_symbol,
        coalesce(modeled_positions.modeled_quantity, 0) as modeled_quantity,
        coalesce(plaid_positions.plaid_quantity, 0) as plaid_quantity
    from modeled_positions
    full outer join plaid_positions
        on modeled_positions.ticker_symbol = plaid_positions.ticker_symbol

)

select *
from positions_compared
-- small tolerance for float drift in split-adjusted quantities
where abs(modeled_quantity - plaid_quantity) > 0.0001
