from __future__ import annotations
import asyncio
from typing import Any
import httpx
import json
import os
import socket
import random
import time

class SStatsError(RuntimeError):
    def __init__(self, message: str, *, kind="unknown", retryable=False, status_code=None, endpoint=None):
        super().__init__(message)
        self.kind = kind
        self.retryable = bool(retryable)
        self.status_code = status_code
        self.endpoint = endpoint

class SStatsClient:
    """Small, rate-limit-aware async client for SStats.

    The API is used conservatively: a global semaphore + minimum request gap
    prevent the bot from opening dozens of concurrent requests, while 429s are
    retried only after the server's Retry-After (or a short exponential delay).
    """
    def __init__(self, base_url: str, api_key: str, timeout: float = 30, connect_timeout: float = 30, trust_env: bool = False, retry_attempts: int = 5, min_request_gap: float = 0.25):
        self.base = base_url.rstrip('/')
        self.api_key = api_key
        self.timeout = timeout
        self._client: httpx.AsyncClient | None = None
        self._fallback_client: httpx.AsyncClient | None = None
        self._ipv6_client: httpx.AsyncClient | None = None
        self._sem = asyncio.Semaphore(2)
        self._trust_env = bool(trust_env)
        self._connect_timeout = float(connect_timeout)
        self._retry_attempts = max(1, int(retry_attempts))
        self._rate_lock = asyncio.Lock()
        self._last_request = 0.0
        self._min_gap = max(0.0, float(min_request_gap))

    async def __aenter__(self):
        # Direct connection is the default. This avoids broken system HTTP(S)
        # proxies on Windows causing httpx ConnectError while a browser works.
        timeout = httpx.Timeout(self.timeout, connect=min(self.timeout, self._connect_timeout))
        self._client = httpx.AsyncClient(
            timeout=timeout,
            headers={"Accept": "application/json", "User-Agent": "SYNDICATE-QUANT/4.2.19"},
            follow_redirects=True,
            trust_env=self._trust_env,
            transport=httpx.AsyncHTTPTransport(local_address="0.0.0.0"),
        )
        return self

    async def __aexit__(self, *args):
        if self._client:
            await self._client.aclose()
        if self._fallback_client:
            await self._fallback_client.aclose()
        if self._ipv6_client:
            await self._ipv6_client.aclose()

    async def _wait_turn(self):
        async with self._rate_lock:
            loop = asyncio.get_running_loop()
            now = loop.time()
            wait = self._min_gap - (now - self._last_request)
            if wait > 0:
                await asyncio.sleep(wait)
            self._last_request = loop.time()

    async def _backoff(self, attempt: int, base: float = 2.0, cap: float = 30.0):
        base = 2.0 if base is None else max(0.1, float(base))
        cap = 30.0 if cap is None else max(base, float(cap))
        attempt = max(0, int(attempt or 0))
        delay=min(cap, base*(2**attempt)) + random.uniform(0.0, min(1.0, base/2.0))
        await asyncio.sleep(delay)

    async def get(self, path: str, **params) -> Any:
        if not self._client:
            raise RuntimeError("Use SStatsClient as async context manager")
        params = {k: v for k, v in params.items() if v is not None}
        params["apikey"] = self.api_key
        url = self.base + path
        last_error = None

        # Network failures are retried with exponential backoff. This is
        # deliberately longer than the old 2-attempt policy because transient
        # DNS/TCP/TLS failures are common on Windows networks. HTTP 429 still
        # respects Retry-After.
        for attempt in range(self._retry_attempts):
            try:
                async with self._sem:
                    await self._wait_turn()
                    r = await self._client.get(url, params=params)

                if r.status_code == 429:
                    retry_after = r.headers.get("Retry-After")
                    try:
                        delay = float(retry_after) if retry_after else (3.0 * (attempt + 1))
                    except ValueError:
                        delay = 3.0 * (attempt + 1)
                    last_error = f"HTTP 429 Too Many Requests: {path}"
                    if attempt < self._retry_attempts - 1:
                        await asyncio.sleep(min(max(delay, 1.0), 30.0))
                        continue
                    raise SStatsError(last_error + " (rate limit)", kind="rate_limit", retryable=True, status_code=429, endpoint=path)

                # 404 is deterministic for an unsupported ID/endpoint shape;
                # never waste four more requests on it.
                if r.status_code == 404:
                    body = r.text[:180].replace('\n', ' ')
                    raise SStatsError(f"HTTP 404 Not Found: {path}" + (f" ({body})" if body else ""), kind="not_found", retryable=False, status_code=404, endpoint=path)

                if r.status_code >= 500:
                    last_error = f"HTTP {r.status_code} from SStats: {path}"
                    if attempt < self._retry_attempts - 1:
                        await asyncio.sleep(min(2.0 * (2 ** attempt), 15.0))
                        continue
                    raise SStatsError(last_error, kind="server_error", retryable=True, status_code=r.status_code, endpoint=path)

                if r.status_code in (401, 403):
                    body = r.text[:300].replace('\n', ' ')
                    raise SStatsError(f"HTTP {r.status_code} SStats authorization error on {path}: {body}", kind="auth", retryable=False, status_code=r.status_code, endpoint=path)

                r.raise_for_status()
                try:
                    payload = r.json()
                except (ValueError, json.JSONDecodeError):
                    raise SStatsError(f"Invalid JSON from SStats on {path}: HTTP {r.status_code}", kind="invalid_json", retryable=True, status_code=r.status_code, endpoint=path)
                if isinstance(payload, dict) and str(payload.get("status", "")).lower() not in ("", "ok", "success", "true"):
                    if payload.get("data") is None and payload.get("message"):
                        raise SStatsError(f"SStats API error on {path}: {payload.get('message')}", kind="api_error", retryable=False, status_code=r.status_code, endpoint=path)
                return payload
            except SStatsError:
                raise
            except (httpx.TimeoutException, httpx.NetworkError, httpx.RemoteProtocolError) as e:
                last_error = f"SStats network error on {path}: {type(e).__name__}: {e}"
                # Some Windows/server installations require the system HTTP(S)
                # proxy to reach external APIs. The bot normally uses a direct
                # connection, but automatically gets one proxy-enabled retry
                # before declaring the API unreachable.
                if not self._trust_env and self._fallback_client is None:
                    self._fallback_client = httpx.AsyncClient(
                        timeout=httpx.Timeout(self.timeout, connect=min(self.timeout, self._connect_timeout)),
                        headers={"Accept":"application/json","User-Agent":"SYNDICATE-QUANT/4.2.19"},
                        follow_redirects=True, trust_env=True)
                    try:
                        async with self._sem:
                            await self._wait_turn()
                            r = await self._fallback_client.get(url, params=params)
                        if r.status_code < 400:
                            try: return r.json()
                            except Exception: pass
                    except Exception:
                        pass
                if attempt < self._retry_attempts - 1:
                    await asyncio.sleep(min(1.5 * (2 ** attempt), 12.0))
                    continue
                # Add local DNS/proxy diagnostics without exposing the API key.
                host = self.base.split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0]
                try:
                    addrs = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
                    families = sorted({"IPv4" if a[0] == socket.AF_INET else "IPv6" if a[0] == socket.AF_INET6 else str(a[0]) for a in addrs})
                    dns_note = " DNS=" + ",".join(families)
                except Exception as de:
                    dns_note = f" DNS_ERROR={type(de).__name__}: {de}"
                proxy_note = " env_proxy=ON" if self._trust_env else " env_proxy=OFF"
                ipv4_note = " ipv4_forced=ON"
                raise SStatsError(last_error + dns_note + proxy_note + ipv4_note, kind="network", retryable=True, endpoint=path)
            except httpx.HTTPError as e:
                last_error = f"SStats HTTP error on {path}: {type(e).__name__}: {e}"
                if attempt < self._retry_attempts - 1:
                    await asyncio.sleep(min(1.5 * (2 ** attempt), 12.0))
                    continue
                raise SStatsError(last_error, kind="http_error", retryable=True, endpoint=path)
            except Exception as e:
                raise SStatsError(f"SStats unexpected error on {path}: {type(e).__name__}: {e}", kind="unexpected", retryable=False, endpoint=path)
        raise SStatsError(last_error or f"SStats request failed: {path}")

    async def post(self, path: str, body: dict, **params) -> Any:
        if not self._client:
            raise RuntimeError("Use SStatsClient as async context manager")
        params = {k: v for k, v in params.items() if v is not None}
        params["apikey"] = self.api_key
        url = self.base + path
        last_error = None
        for attempt in range(self._retry_attempts):
            try:
                async with self._sem:
                    await self._wait_turn()
                    r = await self._client.post(url, params=params, json=body)
                if r.status_code == 429:
                    ra=r.headers.get("Retry-After")
                    try: delay=float(ra) if ra else 3.0*(attempt+1)
                    except ValueError: delay=3.0*(attempt+1)
                    if attempt < self._retry_attempts-1:
                        await asyncio.sleep(min(max(delay,1.0),30.0)); continue
                    raise SStatsError(f"HTTP 429 Too Many Requests: {path}")
                if r.status_code in (401,403):
                    raise SStatsError(f"HTTP {r.status_code} SStats authorization error on {path}: {r.text[:300]}")
                if r.status_code >= 500:
                    last_error=f"HTTP {r.status_code} from SStats: {path}"
                    if attempt < self._retry_attempts-1:
                        await asyncio.sleep(min(2.0*(2**attempt),15.0)); continue
                    raise SStatsError(last_error)
                r.raise_for_status()
                try: return r.json()
                except (ValueError,json.JSONDecodeError): raise SStatsError(f"Invalid JSON from SStats on {path}: HTTP {r.status_code}")
            except SStatsError: raise
            except (httpx.TimeoutException,httpx.NetworkError,httpx.RemoteProtocolError) as e:
                last_error=f"SStats network error on {path}: {type(e).__name__}: {e}"
                if attempt < self._retry_attempts-1:
                    await asyncio.sleep(min(1.5*(2**attempt),12.0)); continue
                raise SStatsError(last_error)
            except httpx.HTTPError as e:
                last_error=f"SStats HTTP error on {path}: {type(e).__name__}: {e}"
                if attempt < self._retry_attempts-1:
                    await asyncio.sleep(min(1.5*(2**attempt),12.0)); continue
                raise SStatsError(last_error)
        raise SStatsError(last_error or f"SStats request failed: {path}")

    async def games(self, **params): return await self.get("/Games/list", **params)
    async def games_query(self, condition, fields=None, order="Date", offset=0, limit=1000, timezone=3):
        body={"condition":condition,"fields":fields or ["Id","Date","HomeTeamName","AwayTeamName","HomeTeamId","AwayTeamId","ScoreHomeFT","ScoreAwayFT","Status","LeagueId","Year"],"order":order,"offset":offset,"limit":min(1000,max(1,int(limit))),"format":"json"}
        return await self.post("/Games/query", body, timeZone=timezone)
    async def game(self, game_id): return await self.get(f"/Games/{game_id}")
    async def glicko(self, game_id): return await self.get(f"/Games/glicko/{game_id}")
    async def odds(self, game_id, bookmaker_id=None, opening=False):
        return await self.get(f"/Odds/{game_id}", bookmakerId=bookmaker_id, opening=str(opening).lower())
    async def odds_live(self, game_id): return await self.get(f"/Odds/live/{game_id}")
    async def odds_live_changes(self, game_id): return await self.get(f"/Odds/live-changes/{game_id}")
    async def bookmakers(self): return await self.get("/Odds/bookmakers")
    async def prematch_markets(self): return await self.get("/Odds/prematch-markets")
    async def flashscore_list(self, **params): return await self.get("/Ls/List", **params)
    async def flashscore_game_info(self, game_id): return await self.get("/Ls/GameInfo", id=game_id)


def data_of(payload):
    """Unwrap the SStats response envelope.

    SStats documents list endpoints as {status,count,data:[...]...} and
    single-match endpoints as {status,count,data:{...}...}. Keep this helper
    tolerant of casing/legacy wrappers so one API response shape cannot make
    the scanner/backtest silently see zero rows.
    """
    if isinstance(payload, dict):
        for key in ("data", "Data", "games", "matches", "items", "results"):
            if key in payload:
                return payload.get(key)
    return payload
