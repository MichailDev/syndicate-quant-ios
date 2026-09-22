from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    telegram_bot_token: str = ""
    sstats_api_key: str
    sstats_base_url: str = "https://api.sstats.net"
    timezone: int = 3  # Moscow / UTC+3; live forecast is always today only
    bankroll: float = 100000
    max_stake_pct: float = 0.02
    min_sample: int = 6
    lookback_matches: int = 20
    scan_matches: int = 1000
    request_timeout: float = 45
    sstats_connect_timeout: float = 12
    sstats_retry_attempts: int = 4
    sstats_min_request_gap: float = 0.75
    sstats_backtest_concurrency: int = 2
    backtest_detail_retry_rounds: int = 2
    backtest_detail_retry_cooldown_seconds: float = 8.0
    backtest_min_coverage: float = 0.98
    sstats_trust_env: bool = False
    settlement_interval_minutes: int = 10
    simulations: int = 50000
    portfolio_max_bets: int = 8
    daily_max_stake_pct: float = 0.10
    owner_user_id: int = 0
    forecast_scope: str = "top"
    calibration_enabled: bool = True
    calibration_min_samples: int = 25
    calibration_window_matches: int = 500
    auto_backtest_enabled: bool = False
    auto_backtest_on_start: bool = False
    auto_backtest_interval_hours: int = 168
    backtest_target_timeout_minutes: int = 45
    backtest_heartbeat_seconds: int = 20
    backtest_progress_persist_every: int = 25
    auto_backtest_targets: str = "39:2023:500,39:2024:500,39:2025:500,140:2023:500,140:2024:500,140:2025:500,135:2023:500,135:2024:500,135:2025:500,78:2023:500,78:2024:500,78:2025:500,61:2023:500,61:2024:500,61:2025:500,235:2023:500,235:2024:500,235:2025:500"
    backtest_markets: list[str] = ["1X2", "GOALS", "CARDS", "CORNERS"]
    backtest_limit: int = 500
    model_config = SettingsConfigDict(env_file=".env", case_sensitive=False, extra="ignore")

settings = Settings()
