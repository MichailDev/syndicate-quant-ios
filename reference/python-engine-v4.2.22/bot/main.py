from __future__ import annotations
import asyncio
import datetime as dt
from aiogram import Bot, Dispatcher, F
from aiogram.filters import CommandStart, Command
from aiogram.types import Message, InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery
from .config import settings
from .api.sstats import SStatsClient
from .db.store import Store
from .engine.scanner import Scanner
from .auto_backtest import verify, scheduler, running, launch, status as backtest_status, stop as stop_backtest, run_single, run_league_all_seasons, launch_league, task_running, target_inventory, league_name, invalidate_target, LEAGUES, YEARS
from .history import overview_text, market_audit_text
from .services.forecast import run_forecast_data, today_local

VERSION = 'v4.2.22'
store = Store()
dp = Dispatcher()


def is_owner(user_id):
    try:
        return bool(settings.owner_user_id) and int(user_id or 0) == int(settings.owner_user_id)
    except Exception:
        return False


def authorized_message(m: Message) -> bool:
    # Public bot functions are available to every user in a private chat.
    # Administrative functions are protected separately by is_owner().
    return m.chat.type == 'private'


async def reject_unauthorized(m: Message):
    # Keep the bot private-chat oriented. Do not expose admin functionality in
    # groups/supergroups/channels and do not leave a group merely because a
    # public user cannot use the private UI there.
    return None


def owner_only_message(m: Message) -> bool:
    return authorized_message(m) and is_owner(getattr(getattr(m, 'from_user', None), 'id', None))


def menu():
    # Admin is intentionally hidden from the public menu. The owner enters it
    # with /admin; this also prevents other users from discovering the section.
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text='🔮 Прогноз', callback_data='m:FORECAST')],
        [InlineKeyboardButton(text='🎯 Ставка дня', callback_data='m:DAYBET')],
        [InlineKeyboardButton(text='📊 Статистика', callback_data='m:STATS')],
    ])


def admin_menu():
    # This is the former History System menu, renamed to ADMIN and hidden
    # from public users. Nothing from the old history navigation is removed;
    # only the two requested backtest controls are added.
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text='📊 Общая сводка', callback_data='h:OVERVIEW')],
        [InlineKeyboardButton(text='🎯 Market Audit', callback_data='h:AUDIT')],
        [InlineKeyboardButton(text='🔬 Исторический backtest', callback_data='a:BACKTEST_MENU')],
        [InlineKeyboardButton(text='📡 /backtest_status', callback_data='a:STATUS')],
        [InlineKeyboardButton(text='🔙 Главное меню', callback_data='h:BACK')],
    ])


def forecast_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text='🌍 Все лиги', callback_data='f:ALL')],
        [InlineKeyboardButton(text='🏆 Топ-лиги', callback_data='f:TOP')],
        [InlineKeyboardButton(text='🔙 Главное меню', callback_data='f:BACK')],
    ])


def history_menu():
    return admin_menu()

# Backward-compatible alias for old code/commands; history now lives inside hidden ADMIN.
_legacy_history_menu = admin_menu


@dp.message(CommandStart())
async def start(m: Message):
    if not authorized_message(m):
        await reject_unauthorized(m)
        return
    await m.answer(
        f'⚽ SYNDICATE QUANT {VERSION}\n\n'
        'Dixon–Coles + Poisson/NB + Monte Carlo + Glicko + player assembly + referee model + sharp guard + portfolio control.\n\n'
        '🔮 Прогноз — полный прогноз по всем рынкам.\n'
        '🎯 Ставка дня — сохранённый прогноз на сегодня.\n'
        '📊 Статистика — результаты рассчитанных и завершённых прогнозов.\n\n'
        'Исторический backtest запускается вручную: выбери лигу — бот последовательно обработает сезоны 2023, 2024 и 2025.\n'
        'NO DATA → NO NUMBER → NO EDGE → NO BET.', reply_markup=menu())


async def _safe_edit(target, text, reply_markup=None):
    try:
        return await target.edit_text(text, reply_markup=reply_markup)
    except Exception as e:
        if 'message is not modified' in str(e).lower():
            return None
        raise


async def _safe_callback_answer(c: CallbackQuery):
    # A user can click an old inline button after Telegram's callback-query
    # acknowledgement window has expired. This must never crash polling.
    try:
        await c.answer()
    except Exception as e:
        if 'query is too old' in str(e).lower() or 'query id is invalid' in str(e).lower() or 'response timeout expired' in str(e).lower():
            return None
        return None


async def send_history(target, view='OVERVIEW'):
    text = market_audit_text() if view == 'AUDIT' else overview_text()
    return await _safe_edit(target, text, admin_menu())


async def send_stats(target):
    try:
        async with SStatsClient(settings.sstats_base_url, settings.sstats_api_key, settings.request_timeout, settings.sstats_connect_timeout, settings.sstats_trust_env, settings.sstats_retry_attempts, settings.sstats_min_request_gap) as api:
            scanner = Scanner(api, store, settings)
            await scanner.settle_finished()
    except Exception:
        pass
    s = store.stats()
    text=(
        '📊 СТАТИСТИКА\n\n'
        f'Всего ставок: {s["bets"]}\n'
        f'✅ Выиграно: {s["wins"]}\n'
        f'❌ Проиграно: {s["losses"]}\n'
        f'↩️ Возвратов: {s["pushes"]}\n'
        f'🎯 Проход: {s["hit_rate"]*100:.1f}%\n\n'
        f'💰 Прибыль: {s["profit_units"]:+.4f} банка\n'
        f'📈 ROI: {s["roi"]*100:+.2f}%\n'
        f'🧮 Средний EV: {s["avg_ev"]*100:+.2f}%\n'
        f'📐 Ожидаемая прибыль: {s["expected_profit"]:+.4f} банка\n'
        f'💵 Средний коэффициент: {s["avg_odds"]:.2f}\n'
        f'💼 Оборот: {s["staked_units"]:.4f} банка'
    )
    if isinstance(target, CallbackQuery):
        await _safe_edit(target.message, text, menu())
    else:
        await target.answer(text, reply_markup=menu())


@dp.message(Command('admin'))
async def admin_cmd(m: Message):
    if not owner_only_message(m):
        return
    await m.answer(
        '🔐 АДМИН\n\n'
        'Скрытый раздел владельца. Здесь сохранена вся история системы и добавлено управление backtest.',
        reply_markup=admin_menu())


@dp.message(Command('stats'))
async def stats(m: Message):
    if not authorized_message(m):
        return
    await send_stats(m)


@dp.message(Command('history'))
async def history_cmd(m: Message):
    if not owner_only_message(m):
        return
    await m.answer(overview_text(), reply_markup=admin_menu())


@dp.message(Command('settle'))
async def settle_cmd(m: Message):
    if not owner_only_message(m):
        return
    try:
        async with SStatsClient(settings.sstats_base_url, settings.sstats_api_key, settings.request_timeout, settings.sstats_connect_timeout, settings.sstats_trust_env, settings.sstats_retry_attempts, settings.sstats_min_request_gap) as api:
            scanner = Scanner(api, store, settings)
            settled = await scanner.settle_finished()
        await m.answer(f'🔄 Проверка результатов завершена. Обновлено матчей: {settled}', reply_markup=menu())
    except Exception as e:
        await m.answer(f'❌ SETTLE ERROR\n{str(e)[:1200]}', reply_markup=menu())


def _backtest_league_menu():
    rows=[]
    for lid in (39,78,140,135,61,235):
        rows.append([InlineKeyboardButton(text=f'🏆 {league_name(lid)}', callback_data=f'b:L:{lid}')])
    rows.append([InlineKeyboardButton(text='🔙 Админ', callback_data='a:BACK')])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def _backtest_year_menu(league):
    inv=[]
    for y in YEARS:
        x=target_inventory(league,y)
        mark='🟢' if x['report_ok'] else ('🟡' if x['exists'] else '⚪')
        inv.append([InlineKeyboardButton(text=f'{mark} {y}', callback_data=f'b:Y:{league}:{y}')])
    inv.append([InlineKeyboardButton(text='🔙 Лиги', callback_data='a:BACKTEST_MENU')])
    return InlineKeyboardMarkup(inline_keyboard=inv)


def _backtest_update_menu(league, year):
    x=target_inventory(league,year)
    if x['report_ok']:
        status='полная готовая база'
    elif x['exists']:
        status='есть сохранённые данные / checkpoint'
    else:
        status='базы ещё нет'
    rows=[]
    if x['exists']:
        rows.append([InlineKeyboardButton(text='🔄 Да, обновить', callback_data=f'b:U:{league}:{year}:1')])
        rows.append([InlineKeyboardButton(text='⏭ Нет, оставить как есть', callback_data=f'b:U:{league}:{year}:0')])
    else:
        rows.append([InlineKeyboardButton(text='▶️ Создать базу', callback_data=f'b:U:{league}:{year}:1')])
    rows.append([InlineKeyboardButton(text='🔙 Сезоны', callback_data=f'b:L:{league}')])
    return status, InlineKeyboardMarkup(inline_keyboard=rows)


async def _start_single_backtest(target, league, year, force_update=False):
    if running():
        text=_backtest_status_text(backtest_status())
        await _safe_edit(target, text, admin_menu())
        return
    inv=target_inventory(league,year)
    if inv['report_ok'] and not force_update:
        await _safe_edit(target,
            f'🟢 БАЗА УЖЕ ГОТОВА\n\n🏆 {league_name(league)}\n📅 Сезон: {year}\n\n'
            'Обновление не запускалось. Эта историческая база уже доступна системе для калибровки.',
            admin_menu())
        return
    await _safe_edit(target,
        f'⏳ BACKTEST ЗАПУЩЕН\n\n🏆 {league_name(league)}\n📅 Сезон: {year}\n\n'
        + ('🔄 Полное обновление выбранной базы.\n' if force_update else '▶️ Создание/продолжение базы.\n')
        + 'Другие лиги и сезоны не затрагиваются.', admin_menu())
    msg=target
    async def progress(kind,idx,total,l,y,info):
        try:
            if kind=='fetch':
                cache=' (локальный cache)' if info.get('cache_hit') else ''
                text=(f'📥 BACKTEST\n🏆 {league_name(l)} | {y}\n'
                      f'Получено матчей: {info.get("received",0)}{cache}\n'
                      f'Raw: {info.get("raw_path", "—")}')
            elif kind=='details':
                text=(f'⏳ BACKTEST\n🏆 {league_name(l)} | {y}\n'
                      f'Детализация: {info.get("done",0)}/{info.get("total",0)}\n'
                      f'Успешно: {info.get("full",0)} | ошибок: {info.get("errors",0)} | осталось: {info.get("missing",0)}\nПовтор: {info.get("retry_round",0)}')
            elif kind=='target_partial_ok':
                text=(f'⚠️ BACKTEST ЧАСТИЧНО ЗАВЕРШЁН\n🏆 {league_name(l)} | {y}\n'
                      f'Детализация: {info.get("full",0)}/{info.get("matches",0)} ({info.get("coverage",0):.1%})\n'
                      f'Пропущено: {info.get("missing",0)}\nРасчёт продолжается без отсутствующих матчей.')
            elif kind=='target_partial':
                text=(f'⚠️ BACKTEST НЕПОЛНЫЙ\n🏆 {league_name(l)} | {y}\n'
                      f'Детализация: {info.get("full",0)}/{info.get("matches",0)}\n'
                      f'Осталось: {info.get("missing",0)}\nCheckpoint сохранён.')
            elif kind=='target_done':
                text=(f'✅ BACKTEST ЗАВЕРШЁН\n🏆 {league_name(l)} | {y}\n'
                      f'Матчей: {info.get("matches",0)}\nПрогнозов: {info.get("predictions",0)}\nСтавок: {info.get("bets",0)}')
            elif kind=='fetch_request':
                text=(f'📡 SStats\n🏆 {league_name(l)} | {y}\n'
                      f'GET /Games/list\noffset={info.get("offset",0)} limit={info.get("limit",0)}')
            elif kind=='target_error':
                text=f'⚠️ Ошибка {league_name(l)} {y}\n{str(info)[:1200]}'
            else:
                text=f'⏳ BACKTEST\n🏆 {league_name(l)} | {y}\nПодготовка...'
            await msg.edit_text(text,reply_markup=admin_menu())
        except Exception: pass
    async def finish(task):
        try:
            result=await task
            await msg.edit_text(
                f'✅ BACKTEST ЗАВЕРШЁН\n\n🏆 {league_name(league)}\n📅 Сезон: {year}\n'
                f'Матчей: {result.get("matches",0)}\nДетализация: {result.get("usable_full_matches",0)}/{result.get("matches",0)} ({result.get("detail_coverage",0):.1%})\nПрогнозов: {result.get("predictions",0)}\n'
                f'Ставок: {result.get("portfolio_bets",0)}\n\n'
                + ('База сохранена и будет использоваться в калибровке будущих прогнозов.' if result.get('integrity_status')=='complete' else 'База сохранена со статусом PARTIAL; отсутствующие матчи не использовались.'),
                reply_markup=admin_menu())
        except asyncio.CancelledError:
            await msg.edit_text('🛑 BACKTEST остановлен. Сохранённые checkpoint не удалены.',reply_markup=admin_menu())
        except Exception as e:
            await msg.edit_text(f'❌ BACKTEST ERROR\n{str(e)[:1500]}',reply_markup=admin_menu())
    task=asyncio.create_task(run_single(league,year,settings.backtest_limit,progress,force_update))
    asyncio.create_task(finish(task))


@dp.message(Command('backtest'))
async def backtest_cmd(m: Message):
    if not owner_only_message(m):
        return
    await m.answer('🔬 ИСТОРИЧЕСКИЙ BACKTEST\n\nВыберите лигу:', reply_markup=_backtest_league_menu())



def _backtest_status_text(st):
    status=st.get('status','idle')
    if status=='running':
        errors = st.get('fetch_errors') or []
        error_text = ('\n⚠️ Ошибки загрузки: ' + ' | '.join(str(x)[:180] for x in errors[-2:])) if errors else ''
        return ('⏳ BACKTEST В РАБОТЕ\n\n'
                f'API: {settings.sstats_base_url}/Games/list\n'
                f'Цель: {st.get("target_index",0)}/{st.get("target_total",0)}\n'
                f'Лига/сезон: {st.get("league","—")} / {st.get("year","—")}\n'
                f'Получено матчей: {st.get("received_matches",st.get("match_total",0))}\n'
                f'Запрос: {st.get("fetch_source","Games/list")} offset={st.get("fetch_offset",0)} limit={st.get("fetch_limit",0)}\n'
                f'Детализация: {st.get("detail_done",st.get("match_done",0))}/{st.get("detail_total",st.get("match_total",0))}\n'                f'Фаза: {st.get("phase","—")}\n'
                f'Raw: {st.get("raw_path","—")}\n'
                f'Последняя завершённая цель: {st.get("last_completed_target","—")}\n'
                + ('\n'.join(f'{y}: сбор {"🟢" if v.get("collection")=="ok" else "🔴" if v.get("collection")=="error" else "⚪"} | анализ {"🟢" if v.get("analysis")=="ok" else "🔴" if v.get("analysis")=="error" else "⚪"}' for y,v in sorted((st.get("stage_statuses") or {}).items()))) + '\n'
                f'Heartbeat: {st.get("heartbeat_at","—")}\n'
                f'{error_text}\n\n'
                'Каждая завершённая цель и raw-список сохраняются сразу.')
    if status=='completed':
        return f'✅ BACKTEST завершён\n\nПоследний полный запуск: {st.get("finished_at","—")}\nЗавершённых целей: {st.get("completed_targets",0)}\nОшибок целей: {st.get("failed_targets",0)}'
    if status=='cancelled': return '🛑 BACKTEST остановлен пользователем.\n\nЗавершённые цели сохранены.'
    if status=='error': return f'❌ BACKTEST завершился с ошибкой.\n\n{st.get("error","Неизвестная ошибка")}'
    return 'ℹ️ BACKTEST не выполняется.\n\nИсторический backtest запускается только вручную. Выберите лигу и сезон через /backtest.'


@dp.message(Command('backtest_status'))
async def backtest_status_cmd(m: Message):
    if not owner_only_message(m):
        return
    await m.answer(_backtest_status_text(backtest_status()), reply_markup=admin_menu())


@dp.message(Command('backtest_stop'))
async def backtest_stop_cmd(m: Message):
    if not owner_only_message(m):
        return
    if await stop_backtest():
        await m.answer('🛑 Команда остановки отправлена. Текущий запрос завершится/будет отменён; сохранённые цели не удаляются.', reply_markup=admin_menu())
    else:
        await m.answer('ℹ️ Сейчас исторический backtest не выполняется.', reply_markup=admin_menu())


@dp.callback_query(F.data.startswith('f:'))
async def forecast_callback(c: CallbackQuery):
    await _safe_callback_answer(c)
    if getattr(getattr(c, 'message', None), 'chat', None) is None or c.message.chat.type != 'private':
        return
    scope=c.data.split(':',1)[1]
    if scope == 'BACK':
        await _safe_edit(c.message, f'⚽ SYNDICATE QUANT {VERSION}', menu())
        return
    await generate_forecast(c, scope.lower())


@dp.callback_query(F.data.startswith('h:'))
async def history_callback(c: CallbackQuery):
    await _safe_callback_answer(c)
    if not (getattr(getattr(c, 'message', None), 'chat', None) and c.message.chat.type == 'private' and is_owner(getattr(getattr(c, 'from_user', None), 'id', None))):
        return
    view = c.data.split(':', 1)[1]
    if view == 'BACK':
        await _safe_edit(c.message, f'🔐 АДМИН', admin_menu())
        return
    await send_history(c.message, view)


@dp.callback_query(F.data.startswith('a:'))
async def admin_callback(c: CallbackQuery):
    await _safe_callback_answer(c)
    if not (getattr(getattr(c, 'message', None), 'chat', None) and c.message.chat.type == 'private' and is_owner(getattr(getattr(c, 'from_user', None), 'id', None))):
        return
    action = c.data.split(':', 1)[1]
    if action == 'BACKTEST_MENU':
        await _safe_edit(c.message, '🔬 ИСТОРИЧЕСКИЙ BACKTEST\n\nВыберите лигу:', _backtest_league_menu())
    elif action == 'STATUS':
        await _safe_edit(c.message, _backtest_status_text(backtest_status()), admin_menu())
    elif action == 'BACK':
        await _safe_edit(c.message, f'⚽ SYNDICATE QUANT {VERSION}', menu())


async def _start_league_backtest(msg, league):
    if task_running() or running():
        await _safe_edit(msg, '⏳ Исторический backtest уже выполняется.', admin_menu())
        return
    await _safe_edit(
        msg,
        f'⏳ BACKTEST ЗАПУЩЕН\\n\\n🏆 {league_name(league)}\\n'
        f'📚 Сезоны: 2023 / 2024 / 2025\\n'
        'Существующие полные сезоны будут пропущены; checkpoint/partial продолжатся.',
        admin_menu()
    )
    async def progress(kind, idx, total, l, y, info):
        if kind in ('stage_start','collection_done','collection_error','analysis_done','analysis_error','target_partial'):
            stage=(info.get('stage') if isinstance(info,dict) else None) or ('collect' if kind.startswith('collection') else 'analysis')
            if kind=='stage_start':
                stage=info.get('stage','collect') if isinstance(info,dict) else 'collect'
            label='СБОР ДАННЫХ' if stage=='collect' else 'АНАЛИЗ'
            lines=[f'⏳ BACKTEST: {label}', '', f'🏆 {league_name(l)}']
            if kind=='stage_start':
                lines.append('Начат этап. Сезоны: 2023 / 2024 / 2025')
            elif kind=='collection_done':
                lines.append(f'📅 {y}: 🟢 Данные собраны' if info.get('status')=='ok' or info.get('cached') else f'📅 {y}: 🔴 Сбор не завершён')
                lines.append(f'Матчей: {info.get("matches",0)} | детализация: {info.get("usable_full_matches",0)}/{info.get("matches",0)}')
            elif kind=='collection_error':
                lines.append(f'📅 {y}: 🔴 Сбор данных')
                lines.append(f'Ошибка: {str(info)[:700]}')
            elif kind=='analysis_done':
                lines.append(f'📅 {y}: 🟢 Анализ завершён')
            elif kind=='analysis_error':
                lines.append(f'📅 {y}: 🔴 Анализ')
                lines.append(f'Ошибка: {str(info)[:700]}')
            elif kind=='target_partial':
                lines.append(f'📅 {y}: 🔴 Недостаточно данных')
                lines.append(f'Детализация: {info.get("full",0)}/{info.get("matches",0)}')
            try:
                await _safe_edit(msg,'\n'.join(lines),admin_menu())
            except Exception:
                pass
    async def finish(task):
        try:
            result=await task
            if result.get('status')=='ok':
                await _safe_edit(
                    msg,
                    f'✅ BACKTEST ЗАВЕРШЁН\\n\\n🏆 {league_name(league)}\\n'
                    f'Обработаны сезоны: 2023 / 2024 / 2025\\n'
                    f'Ошибок: {result.get("failed_targets",0)}',
                    admin_menu())
            elif result.get('status')=='partial':
                await _safe_edit(
                    msg,
                    f'⚠️ BACKTEST ЗАВЕРШЁН ЧАСТИЧНО\\n\\n🏆 {league_name(league)}\\n'
                    'Часть сезонов завершена, ошибки сохранены в checkpoint.',
                    admin_menu())
            else:
                await _safe_edit(msg, f'❌ BACKTEST ERROR\\n{str(result)[:1500]}', admin_menu())
        except asyncio.CancelledError:
            await _safe_edit(msg, '🛑 BACKTEST остановлен. Сохранённые checkpoint не удалены.', admin_menu())
        except Exception as e:
            await _safe_edit(msg, f'❌ BACKTEST ERROR\\n{str(e)[:1500]}', admin_menu())
    task=launch_league(league, YEARS, settings.backtest_limit, progress, False)
    asyncio.create_task(finish(task))


@dp.callback_query(F.data.startswith('b:'))
async def backtest_callback(c: CallbackQuery):
    await _safe_callback_answer(c)
    if not (getattr(getattr(c,'message',None),'chat',None) and c.message.chat.type=='private' and is_owner(getattr(getattr(c,'from_user',None),'id',None))):
        return
    parts=c.data.split(':')
    action=parts[1] if len(parts)>1 else ''
    if action=='L':
        league=int(parts[2])
        await _start_league_backtest(c.message, league)
    elif action=='Y':
        league,year=int(parts[2]),int(parts[3])
        status,kb=_backtest_update_menu(league,year)
        x=target_inventory(league,year)
        detail=(f'\\n\\nRaw: {"есть" if x["raw_exists"] else "нет"}\\n'
                f'Details: {"есть" if x["details_exists"] else "нет"}\\n'
                f'Отчёт: {"готов" if x["report_ok"] else "нет"}')
        await _safe_edit(c.message, f'🏆 {league_name(league)}\\n📅 Сезон {year}\\n\\nСтатус: {status}{detail}\\n\\nОбновить базу?', kb)
    elif action=='U':
        league,year=int(parts[2]),int(parts[3]); force=parts[4]=='1'
        await _start_single_backtest(c.message,league,year,force)
    elif action=='BACK':
        await _safe_edit(c.message,'🔐 АДМИН',admin_menu())

@dp.callback_query(F.data.startswith('m:'))
async def menu_callback(c: CallbackQuery):
    await _safe_callback_answer(c)
    if not (getattr(getattr(c, 'message', None), 'chat', None) and c.message.chat.type == 'private'):
        return
    action = c.data.split(':', 1)[1]

    if action == 'STATS':
        await send_stats(c)
        return

    if action == 'DAYBET':
        await show_daily_forecast(c)
        return

    if action == 'FORECAST':
        await _safe_edit(c.message, '🔮 ПРОГНОЗ\n\nВыберите охват анализа:', forecast_menu())
        return

    # Compatibility with old inline messages/buttons. No market-specific
    # buttons are exposed by the new UI, but an old message may still contain one.
    if action == 'HISTORY':
        if is_owner(getattr(getattr(c, 'from_user', None), 'id', None)):
            await send_history(c.message, 'OVERVIEW')
        return
    if action == 'BACK':
        await _safe_edit(c.message, f'⚽ SYNDICATE QUANT {VERSION}', menu())
        return

    await _safe_edit(c.message, '⚠️ Эта кнопка относится к старой версии меню. Откройте /start.', menu())


def _today_local():
    return today_local(settings)

def _forecast_header(created_at=None):
    today = dt.datetime.now(dt.timezone(dt.timedelta(hours=settings.timezone)))
    txt = f'📅 {today:%d.%m.%Y} | UTC{settings.timezone:+d}'
    if created_at:
        try:
            x = dt.datetime.fromisoformat(str(created_at).replace('Z','+00:00'))
            if x.tzinfo is None:
                x = x.replace(tzinfo=dt.timezone.utc)
            x = x.astimezone(dt.timezone(dt.timedelta(hours=settings.timezone)))
            txt += f' | обновлено {x:%H:%M}'
        except Exception:
            pass
    return txt


def _format_forecast(rows, title='🔮 SYNDICATE QUANT — ПРОГНОЗ', created_at=None):
    if not rows:
        return f'{title}\n\n{_forecast_header(created_at)}\n\n❌ На сегодня нет ставки, прошедшей фильтры портфеля.\n\nNO DATA → NO NUMBER → NO EDGE → NO BET.'
    lines=[title,'',_forecast_header(created_at),'']
    for i,r in enumerate(rows,1):
        league = r.get('league') or (f'Лига {r.get("league_id")}' if r.get('league_id') else 'Лига не определена')
        lines += [
            f'{i}. {r.get("home","?")} — {r.get("away","?")}',
            f'🏟 {league}',
            _match_datetime_text(r),
            f'🆔 {r.get("game_id","?")}',
            f'🏷 {r.get("market","?")}: {r.get("selection","?")} @ {float(r.get("odds",0)):.2f}',
            f'P {float(r.get("p",0))*100:.1f}% | Robust {float(r.get("p_low",0))*100:.1f}% | Fair {float(r.get("fair",0)):.2f}',
            f'EV {float(r.get("ev",0))*100:+.1f}% | R-EV {float(r.get("robust_ev",0))*100:+.1f}%',
            f'QCS {float(r.get("qcs",0)):.0f} | DCS {float(r.get("dcs",0)):.0f} | MS {float(r.get("ms",0)):.0f}',
            f'💰 Stake {float(r.get("stake",0))*100:.2f}% | {r.get("classification","?")}',
            f'🧠 {r.get("model","N/A")} | Sharp {r.get("sharp_label", "N/A")}',
            f'👥 PlayerAdj {r.get("player_adjustment_label", "N/A")} | Ref {r.get("referee_adjustment_label", "N/A")}',
            ''
        ]
    lines.append('⚠️ Котировки: historical/closing reference. Live execution не заявляется.')
    return '\n'.join(lines)




async def generate_forecast(c: CallbackQuery, scope="all"):
    scope_label='ВСЕ ЛИГИ' if scope=='all' else 'ТОП-ЛИГИ'
    await _safe_edit(c.message, f'⏳ {scope_label}: SStats → фильтр турниров → история → Glicko → player assembly → referee → odds → sharp guard → model → EV/QCS...')
    try:
        valid = await run_forecast_data(store, settings, scope)
    except Exception as e:
        await _safe_edit(c.message, f'❌ SStats/API error:\n{str(e)[:1600]}', menu())
        return
    text = _format_forecast(valid, title=f'🔮 ПРОГНОЗ — {scope_label}', created_at=dt.datetime.utcnow().isoformat())
    if not valid:
        text += f'\n\n📐 Prediction layer сохранён; Bet layer: 0 ставок после фильтров.'
    await _safe_edit(c.message, text, menu())


async def show_daily_forecast(c: CallbackQuery):
    today = _today_local()
    saved = store.daily_forecast(today)
    if not saved:
        await _safe_edit(c.message,
                         f'🎯 СТАВКА ДНЯ\n\n{_forecast_header()}\n\n'
                         'Нет сохранённого прогноза на сегодня.\n\n'
                         'Сначала нажмите 🔮 Прогноз — он выполнит полный анализ всех рынков и сохранит результат на сегодня.',
                         menu())
        return
    text = _format_forecast(saved.get('rows') or [], title='🎯 СТАВКА ДНЯ', created_at=saved.get('created_at'))
    await _safe_edit(c.message, text, menu())


def _parse_dt(value):
    if value is None or value == '': return None
    if isinstance(value,(int,float)):
        try:
            return dt.datetime.fromtimestamp(float(value),tz=dt.timezone.utc)
        except Exception:
            return None
    text=str(value).strip()
    try:
        # Numeric strings are Unix seconds or milliseconds.
        if text.replace('.', '', 1).isdigit():
            v=float(text)
            if v>1e11: v/=1000.0
            return dt.datetime.fromtimestamp(v,tz=dt.timezone.utc)
    except Exception: pass
    try:
        x=dt.datetime.fromisoformat(text.replace('Z','+00:00'))
        return x if x.tzinfo else x.replace(tzinfo=dt.timezone.utc)
    except Exception:
        return None

def _match_datetime_text(r):
    raw=r.get('date_utc') or r.get('date')
    x=_parse_dt(raw)
    if x is None:
        return '📅 Дата/время: нет данных'
    local=x.astimezone(dt.timezone(dt.timedelta(hours=settings.timezone)))
    return f'📅 {local:%d.%m.%Y} ⏰ {local:%H:%M} (UTC{settings.timezone:+d})'


@dp.message(F.text)
async def text_commands(m: Message):
    """Public shortcuts for forecast/statistics in a private chat."""
    if not authorized_message(m):
        return
    text=(m.text or '').strip().lower().replace('ё','е')
    if text in ('прогноз на сегодня','прогноз','/forecast','/forecast@'+str(getattr(m.bot, 'username', '')).lower()):
        scope=(getattr(settings, 'forecast_scope', 'top') or 'top').lower()
        try:
            rows=await run_forecast_data(store, settings, scope)
            await m.answer(_format_forecast(rows, title='🔮 ПРОГНОЗ НА СЕГОДНЯ', created_at=dt.datetime.utcnow().isoformat()), reply_markup=menu())
        except Exception as e:
            await m.answer(f'❌ SStats/API error:\n{str(e)[:1600]}', reply_markup=menu())
    elif text in ('статистика','/statistics','/stat'):
        await send_stats(m)


async def settlement_tracker():
    # Keep daily forecasts tied to actual completed SStats results without
    # requiring the user to open Statistics manually. No result is inferred
    # when SStats lacks a final score/statistics block.
    while True:
        try:
            async with SStatsClient(settings.sstats_base_url, settings.sstats_api_key, settings.request_timeout, settings.sstats_connect_timeout, settings.sstats_trust_env, settings.sstats_retry_attempts, settings.sstats_min_request_gap) as api:
                scanner = Scanner(api, store, settings)
                await scanner.settle_finished()
        except Exception as e:
            print(f'[SETTLEMENT-TRACKER] {e}')
        await asyncio.sleep(max(300, int(getattr(settings, 'settlement_interval_minutes', 10) * 60)))


async def main():
    if not settings.owner_user_id:
        raise RuntimeError('OWNER_USER_ID обязателен для защищённого раздела /admin.')
    if not settings.telegram_bot_token:
        raise RuntimeError('TELEGRAM_BOT_TOKEN обязателен для запуска Telegram-интерфейса.')
    bot = Bot(settings.telegram_bot_token)
    asyncio.create_task(settlement_tracker())
    await dp.start_polling(bot)

if __name__ == '__main__':
    asyncio.run(main())
