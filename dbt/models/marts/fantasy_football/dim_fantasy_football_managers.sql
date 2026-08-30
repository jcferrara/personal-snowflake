with

{{
    import_models(
        refs = [ref('stg_fantasy_football__members')],
        ctes = ['members']
    )
}},

/* Members are landed once per season. Collapse to one row per person,
   taking the most recent season's name (managers rename themselves) and
   the span of seasons they've been in the league. */
latest_identity as (

    select
        member_id as manager_id,
        display_name,
        first_name,
        last_name
    from members
    qualify row_number() over (
        partition by member_id order by season_year desc
    ) = 1

),

season_span as (

    select
        member_id as manager_id,
        min(season_year) as first_season,
        max(season_year) as last_season,
        count(distinct season_year) as seasons_played,
        array_agg(distinct season_year) within group (order by season_year)
            as seasons_active
    from members
    group by 1

),

joined as (

    select
        latest_identity.manager_id,
        latest_identity.display_name,
        latest_identity.first_name,
        latest_identity.last_name,
        nullif(trim(
            coalesce(latest_identity.first_name, '') || ' '
            || coalesce(latest_identity.last_name, '')
        ), '') as full_name,
        season_span.first_season,
        season_span.last_season,
        season_span.seasons_played,
        season_span.last_season = max(season_span.last_season) over ()
            as is_active,
        season_span.seasons_active
    from latest_identity
    inner join season_span
        on latest_identity.manager_id = season_span.manager_id

)

select * from joined
