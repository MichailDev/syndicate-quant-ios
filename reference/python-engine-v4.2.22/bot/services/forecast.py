from __future__ import annotations
import datetime as dt
from ..api.sstats import SStatsClient
from ..engine.scanner import Scanner
from ..engine.portfolio import select_portfolio


def today_local(settings) -> str:
    tz = dt.timezone(dt.timedelta(hours=int(settings.timezone)))
    return dt.datetime.now(tz).date().isoformat()


async def run_forecast_data(store_obj, settings, scope: str = "all"):
    """Run the canonical forecast engine independently of Telegram UI."""
    scope = (scope or "all").lower()
    if scope not in {"all", "top"}:
        raise ValueError("scope must be 'all' or 'top'")
    markets = ["1X2", "GOALS", "CARDS", "CORNERS"]
    async with SStatsClient(
        settings.sstats_base_url,
        settings.sstats_api_key,
        settings.request_timeout,
        settings.sstats_connect_timeout,
        settings.sstats_trust_env,
        settings.sstats_retry_attempts,
        settings.sstats_min_request_gap,
    ) as api:
        scanner = Scanner(api, store_obj, settings)
        all_results = await scanner.scan_many(markets, scope=scope)

    valid = select_portfolio(
        all_results,
        max_items=settings.portfolio_max_bets,
        max_total_stake=settings.daily_max_stake_pct,
    )
    forecast_date = today_local(settings)
    for row in all_results:
        row["forecast_scope"] = scope
        row["forecast_date"] = forecast_date
        store_obj.prediction(row.get("game_id"), row)
    store_obj.save_daily_forecast(forecast_date, valid)
    return valid
