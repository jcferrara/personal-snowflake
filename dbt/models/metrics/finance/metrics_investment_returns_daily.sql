{{ config(materialized = 'table') }}

{%- set trailing_periods = {
    '1m': "dateadd('month', -1, scope_days.date_day)",
    '3m': "dateadd('month', -3, scope_days.date_day)",
    'ytd': "dateadd('day', -1, date_trunc('year', scope_days.date_day))",
    '1y': "dateadd('year', -1, scope_days.date_day)",
    '3y': "dateadd('year', -3, scope_days.date_day)",
    '5y': "dateadd('year', -5, scope_days.date_day)",
} -%}

with

{{
    import_models(
        refs = [ref('fct_investment_lot_daily_values')],
        ctes = ['lot_daily_values']
    )
}},

/* Roll lot-days up to two scopes in one pass: each holding (ticker) per
   day, and the whole portfolio per day. Measures come straight from the
   lot fact. */
scope_days_aggregated as (

    select
        date_day,
        ticker_symbol,
        grouping(ticker_symbol) = 1 as is_portfolio_scope,
        sum(market_value_usd) as market_value_usd,
        sum(cost_basis_open_usd) as cost_basis_open_usd,
        sum(unrealized_gain_usd) as unrealized_gain_usd,
        sum(purchases_usd) as purchases_usd,
        sum(proceeds_usd) as proceeds_usd,
        sum(realized_gain_usd) as realized_gain_usd,
        sum(dividend_income_usd) as dividend_income_usd
    from lot_daily_values
    group by grouping sets ((date_day, ticker_symbol), (date_day))

),

/* Bring in the prior day's market value. A holding that was fully sold
   and later re-bought has a gap in its days; the first day back starts
   from zero rather than the value before the gap. */
scope_days_with_prior_value as (

    select
        *,
        case when is_portfolio_scope then 'portfolio' else 'holding' end as return_scope,
        case
            when lag(date_day) over (
                partition by is_portfolio_scope, ticker_symbol order by date_day
            ) = dateadd('day', -1, date_day)
                then lag(market_value_usd) over (
                    partition by is_portfolio_scope, ticker_symbol order by date_day
                )
            else 0
        end as prior_market_value_usd
    from scope_days_aggregated

),

/* Daily time-weighted return: the day's gain (value change, plus sale
   proceeds and dividends paid out, less new purchases) over the capital
   at work (prior value plus same-day purchases). */
scope_days_with_daily_return as (

    select
        *,
        (
            market_value_usd
            - prior_market_value_usd
            - purchases_usd
            + proceeds_usd
            + dividend_income_usd
        ) / nullif(prior_market_value_usd + purchases_usd, 0) as daily_return_pct
    from scope_days_with_prior_value

),

/* Chain daily returns into a growth index (1.0 = starting value) and
   carry running dollar totals since the scope's first day. */
scope_days as (

    select
        *,
        exp(sum(ln(greatest(1 + coalesce(daily_return_pct, 0), 0.000001))) over (
            partition by is_portfolio_scope, ticker_symbol
            order by date_day
            rows between unbounded preceding and current row
        )) as growth_index,
        min(date_day) over (partition by is_portfolio_scope, ticker_symbol) as inception_date,
        sum(purchases_usd) over (
            partition by is_portfolio_scope, ticker_symbol
            order by date_day
            rows between unbounded preceding and current row
        ) as cumulative_purchases_usd,
        sum(proceeds_usd) over (
            partition by is_portfolio_scope, ticker_symbol
            order by date_day
            rows between unbounded preceding and current row
        ) as cumulative_proceeds_usd,
        sum(realized_gain_usd) over (
            partition by is_portfolio_scope, ticker_symbol
            order by date_day
            rows between unbounded preceding and current row
        ) as cumulative_realized_gain_usd,
        sum(dividend_income_usd) over (
            partition by is_portfolio_scope, ticker_symbol
            order by date_day
            rows between unbounded preceding and current row
        ) as cumulative_dividend_income_usd
    from scope_days_with_daily_return

),

/* Trailing-period returns as of each day: the growth index today over
   its value at the period's start. Null when the scope didn't exist yet
   at that start. Three- and five-year figures are also annualized. */
scope_days_with_trailing_returns as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'scope_days.date_day', 'scope_days.return_scope', 'scope_days.ticker_symbol'
        ]) }} as investment_return_day_id,
        scope_days.ticker_symbol,
        scope_days.return_scope,
        scope_days.market_value_usd,
        scope_days.market_value_usd / nullif(
            sum(iff(scope_days.is_portfolio_scope, 0, scope_days.market_value_usd)) over (
                partition by scope_days.date_day
            ),
            0
        ) as portfolio_weight_pct,
        scope_days.prior_market_value_usd,
        scope_days.cost_basis_open_usd,
        scope_days.unrealized_gain_usd,
        scope_days.purchases_usd,
        scope_days.proceeds_usd,
        scope_days.realized_gain_usd,
        scope_days.dividend_income_usd,
        scope_days.cumulative_purchases_usd,
        scope_days.cumulative_proceeds_usd,
        scope_days.cumulative_realized_gain_usd,
        scope_days.cumulative_dividend_income_usd,
        scope_days.market_value_usd
            + scope_days.cumulative_proceeds_usd
            + scope_days.cumulative_dividend_income_usd
            - scope_days.cumulative_purchases_usd as total_return_usd,
        scope_days.daily_return_pct,
        scope_days.growth_index,
        scope_days.growth_index - 1 as twr_since_inception_pct,
        case
            when datediff('day', scope_days.inception_date, scope_days.date_day) >= 365
                then power(
                    scope_days.growth_index,
                    365 / datediff('day', scope_days.inception_date, scope_days.date_day)
                ) - 1
        end as twr_since_inception_annualized_pct,
        {% for period, start_expression in trailing_periods.items() -%}
        scope_days.growth_index / period_start_{{ period }}.growth_index - 1 as twr_{{ period }}_pct,
        {% endfor -%}
        power(scope_days.growth_index / period_start_3y.growth_index, 1 / 3) - 1 as twr_3y_annualized_pct,
        power(scope_days.growth_index / period_start_5y.growth_index, 1 / 5) - 1 as twr_5y_annualized_pct,
        scope_days.is_portfolio_scope,
        scope_days.inception_date,
        scope_days.date_day
    from scope_days
    {% for period, start_expression in trailing_periods.items() -%}
    left join scope_days as period_start_{{ period }}
        on scope_days.is_portfolio_scope = period_start_{{ period }}.is_portfolio_scope
        and equal_null(scope_days.ticker_symbol, period_start_{{ period }}.ticker_symbol)
        and period_start_{{ period }}.date_day = {{ start_expression }}
    {% endfor %}

)

select * from scope_days_with_trailing_returns
