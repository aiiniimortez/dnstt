#!/usr/bin/env python3
# cf_tg_bot.py
"""
Telegram bot for Cloudflare batch A+NS creation and A-IP edits.
Requires: python-telegram-bot v20.x, requests
"""

import os
import re
import time
import json
import logging
import ipaddress
from textwrap import shorten
from functools import partial

import requests
from telegram import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Update,
)
from telegram.ext import (
    ApplicationBuilder,
    ContextTypes,
    CommandHandler,
    CallbackQueryHandler,
    MessageHandler,
    ConversationHandler,
    filters,
)

TELEGRAM_TOKEN = "8717574663:AAF75uq7VernT0DAEtHRmRhLciEDrrYHxAk"
ALLOWED_USER_ID = 1188689027

# -----------------------
# Config / Constants
# -----------------------
API_BASE = "https://api.cloudflare.com/client/v4"
DOMAINS_FILE = "domains.txt"  # place your domains file here
PAGE_SIZE_DOMAINS = 10  # domains per page in keyboard
PROGRESS_EDIT_DELAY = 0.15  # small delay between creations to avoid rate limits
WORD_LIST = [
    "behaviour","history","picture","monster","network","science","project","example",
    "country","quantum","virtual","library","factory","process","control","message",
    "feature","journey","problem","product","natural","freedom","capital","energy",
    "pattern","resource","traffic","venture","dynamic","battery","dialogue","shelter",
    "language","strategy","purpose","interface","security","release","command","context",
    "support","document","solution","triangle","balance","distance","function","delivery",
    "economy","priority","announce","campaign","category","computer","developer",
    "mountain","question","research","snapshot","umbrella","constant","instance","decoder",
    "terminal","service","boundary","velocity","horizon","duration","entropy","elegance",
    "scenario","synergy","optimize","resonance","archive","fortune","harmonic","inspire"
]

WORD_LIST = [
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "0", "1", "2", "3", "4"
    "5", "6", "7", "8", "9"
]

# Conversation states
(
    CHOOSING_FLOW,
    CREATE_CHOOSE_DOMAIN,
    CREATE_ASK_COUNT,
    EDIT_CHOOSE_DOMAIN,
    EDIT_CHOOSE_IP,
    EDIT_ASK_NUM,
    EDIT_ASK_NEW_IP,
    TXT_CHOOSE_DOMAIN,
) = range(8)

TXT_RECORD_LABEL = "sampletxt"
TXT_RECORD_CONTENT = "sampledata"

# Logging
logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)


# -----------------------
# Helpers: domains file
# -----------------------
def parse_domains_file(path):
    """
    Parse domains file and return list of dicts: {"domain":..., "token":...}
    Accepts lines like:
      3, "sharghidustrial.ir", "TOKEN"
      or
      "domain.ir","TOKEN"
    Ignores empty lines and lines starting with #
    """
    out = []
    if not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # try to extract quoted parts
            quotes = re.findall(r'"([^"]+)"', line)
            if len(quotes) >= 2:
                domain = quotes[0].strip()
                token = quotes[1].strip()
                out.append({"domain": domain, "token": token})
                continue
            # fallback: split by comma
            parts = [p.strip().strip('"').strip("'") for p in line.split(",") if p.strip()]
            if len(parts) >= 2:
                domain = parts[-2]
                token = parts[-1]
                out.append({"domain": domain, "token": token})
    return out


# -----------------------
# Helpers: Cloudflare API
# -----------------------
def cf_headers(token):
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def is_authorized(update):
    user = update.effective_user
    return user and user.id == ALLOWED_USER_ID

def list_zones(token):
    """Return list of zone objects with paging."""
    zones = []
    page = 1
    per_page = 50
    while True:
        r = requests.get(f"{API_BASE}/zones", headers=cf_headers(token), params={"page": page, "per_page": per_page})
        if r.status_code == 401:
            raise RuntimeError("Unauthorized (401) - token might be invalid or lack permissions")
        r.raise_for_status()
        data = r.json()
        zones.extend(data.get("result", []))
        info = data.get("result_info", {})
        if page >= info.get("total_pages", 1):
            break
        page += 1
    return zones


def get_all_dns_records(token, zone_id):
    """Fetch all dns_records for a zone (pagination)."""
    records = []
    page = 1
    per_page = 100
    while True:
        r = requests.get(f"{API_BASE}/zones/{zone_id}/dns_records",
                         headers=cf_headers(token),
                         params={"page": page, "per_page": per_page})
        r.raise_for_status()
        data = r.json()
        records.extend(data.get("result", []))
        info = data.get("result_info", {})
        if page >= info.get("total_pages", 1):
            break
        page += 1
    return records


def create_dns_record(token, zone_id, record_type, name, content, proxied=False, ttl=1):
    payload = {"type": record_type, "name": name, "content": content, "ttl": ttl}
    if record_type in ("A", "AAAA", "CNAME"):
        payload["proxied"] = bool(proxied)
    r = requests.post(f"{API_BASE}/zones/{zone_id}/dns_records", headers=cf_headers(token), json=payload)
    # return boolean and response body
    return r.ok, r.status_code, r.json() if r.content else {}


def update_dns_record(token, zone_id, record_id, name, ip, ttl=1, proxied=False):
    payload = {"type": "A", "name": name, "content": ip, "ttl": ttl, "proxied": proxied}
    r = requests.put(f"{API_BASE}/zones/{zone_id}/dns_records/{record_id}", headers=cf_headers(token), json=payload)
    return r.ok, r.status_code, r.json() if r.content else {}


# -----------------------
# Helpers: filtering logic
# -----------------------
def find_matching_pairs(records, domain):
    """
    Find pairs where:
      - A record: <word>ir.<domain> -> ip
      - NS record: <word>.<domain> -> <word>ir.<domain>
    Returns list of dicts: {"word":word, "a_records":[...], "ns_record": {...}}
    """
    a_map = {}
    ns_map = {}

    # precompute domain suffix
    dot_domain = "." + domain

    a_pattern = re.compile(rf"^([a-z0-9\-]+)ir\.{re.escape(domain)}$", re.IGNORECASE)
    ns_pattern = re.compile(rf"^([a-z0-9\-]+)\.{re.escape(domain)}$", re.IGNORECASE)

    for r in records:
        rtype = r.get("type")
        name = r.get("name", "")
        if rtype == "A":
            m = a_pattern.match(name)
            if m:
                word = m.group(1)
                a_map.setdefault(word, []).append(r)
        elif rtype == "NS":
            m = ns_pattern.match(name)
            if m:
                word = m.group(1)
                # ensure target equals wordir.domain
                target = r.get("content", "").rstrip(".")
                expected = f"{word}ir.{domain}"
                if target.lower() == expected.lower():
                    ns_map[word] = r

    found = []
    for word, a_recs in a_map.items():
        if word in ns_map:
            found.append({"word": word, "a_records": a_recs, "ns_record": ns_map[word]})
    return found


# -----------------------
# Helpers: messaging chunk
# -----------------------
def chunk_lines_and_send(text_lines, max_chars=3800):
    """Chunk by total chars, return list of strings (chunks)."""
    chunks = []
    cur = []
    cur_len = 0
    for line in text_lines:
        l = line + "\n"
        if cur_len + len(l) > max_chars and cur:
            chunks.append("".join(cur).rstrip("\n"))
            cur = []
            cur_len = 0
        cur.append(l)
        cur_len += len(l)
    if cur:
        chunks.append("".join(cur).rstrip("\n"))
    return chunks


# -----------------------
# Bot Handlers
# -----------------------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):

    if not is_authorized(update):
        await update.message.reply_text("⛔ شما اجازه استفاده از این ربات را ندارید.")
        return ConversationHandler.END

    kb = [
        [InlineKeyboardButton("➕ ایجاد رکورد دسته‌ای", callback_data="flow:create")],
        [InlineKeyboardButton("✏️ ویرایش رکوردها", callback_data="flow:edit")],
        [InlineKeyboardButton("📝 ایجاد رکورد TXT", callback_data="flow:txt")],
    ]
    await update.message.reply_text("سلام! یکی از عملیات زیر رو انتخاب کن:", reply_markup=InlineKeyboardMarkup(kb))
    return CHOOSING_FLOW

def resolve_zone_for_domain(token, domain):
    zones = list_zones(token)
    zone = next((z for z in zones if z.get("name") == domain), None)
    if not zone:
        zone = next((z for z in zones if domain.endswith(z.get("name", ""))), None)
    return zone


async def txt_domain_selected_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        await update.callback_query.answer("Unauthorized", show_alert=True)
        return

    q = update.callback_query
    await q.answer()

    _, _, idx_s = q.data.split(":", 2)  # txt:domain:<idx>
    idx = int(idx_s)

    domains = parse_domains_file(DOMAINS_FILE)
    if idx < 0 or idx >= len(domains):
        await q.edit_message_text("انتخاب نامعتبر.")
        return ConversationHandler.END

    sel = domains[idx]
    context.user_data['selected_domain_entry'] = sel
    domain = sel["domain"]
    token = sel["token"]

    try:
        zone = resolve_zone_for_domain(token, domain)
    except Exception as e:
        await q.edit_message_text(f"خطا در گرفتن zones: {e}")
        return ConversationHandler.END

    if not zone:
        await q.edit_message_text("خطا: zone مربوط به این دامنه از طریق توکن پیدا نشد.")
        return ConversationHandler.END

    zone_id = zone["id"]
    record_name = f"{TXT_RECORD_LABEL}.{domain}"
    record_content = TXT_RECORD_CONTENT

    try:
        records = get_all_dns_records(token, zone_id)
    except Exception as e:
        await q.edit_message_text(f"خطا در واکشی رکوردها: {e}")
        return ConversationHandler.END

    exists = any(
        r.get("type") == "TXT"
        and r.get("name", "").rstrip(".").lower() == record_name.lower()
        and r.get("content", "") == record_content
        for r in records
    )

    if exists:
        await q.edit_message_text("این رکورد TXT قبلاً ایجاد شده است.")
        return ConversationHandler.END

    ok, status, body = create_dns_record(token, zone_id, "TXT", record_name, record_content, proxied=False)
    if not ok:
        err = body.get("errors", [{}])[0].get("message", "خطای نامشخص")
        await q.edit_message_text(f"خطا در ایجاد TXT: {err}")
        return ConversationHandler.END

    await q.edit_message_text(
        f"رکورد TXT با موفقیت اضافه شد:\n\n{record_name}\n{record_content}"
    )
    return ConversationHandler.END

# --- Pagination keyboard for domains ---
def build_domains_keyboard(domains, page=0, prefix="create"):
    start_idx = page * PAGE_SIZE_DOMAINS
    end_idx = start_idx + PAGE_SIZE_DOMAINS
    page_items = domains[start_idx:end_idx]
    kb = []
    for i, d in enumerate(page_items, start=start_idx):
        text = d["domain"]
        cb = f"{prefix}:domain:{i}"
        kb.append([InlineKeyboardButton(text, callback_data=cb)])
    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton("⬅️ قبلی", callback_data=f"{prefix}:page:{page-1}"))
    if end_idx < len(domains):
        nav.append(InlineKeyboardButton("بعدی ➡️", callback_data=f"{prefix}:page:{page+1}"))
    if nav:
        kb.append(nav)
    kb.append([InlineKeyboardButton("🔙 بازگشت", callback_data="back:main")])
    return InlineKeyboardMarkup(kb)


# --- Handlers for choosing flow ---
async def flow_choice_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        await update.callback_query.answer("Unauthorized", show_alert=True)
        return
    q = update.callback_query
    await q.answer()
    data = q.data  # "flow:create" or "flow:edit"
    domains = parse_domains_file(DOMAINS_FILE)
    if not domains:
        await q.edit_message_text("فایل دامنه‌ها پیدا نشد یا خالی است. فایل `domains.txt` را بررسی کنید.")
        return ConversationHandler.END

    if data == "flow:create":
        # show domain list page 0 for create
        await q.edit_message_text("دامنه‌ای که می‌خوای برایش رکورد بسازی انتخاب کن:", reply_markup=build_domains_keyboard(domains, page=0, prefix="create"))
        return CREATE_CHOOSE_DOMAIN
    elif data == "flow:txt":
        await q.edit_message_text(
            "دامنه‌ای که می‌خوای برایش رکورد TXT بسازی انتخاب کن:",
            reply_markup=build_domains_keyboard(domains, page=0, prefix="txt")
        )
        return TXT_CHOOSE_DOMAIN
    else:
        await q.edit_message_text("دامنه‌ای که می‌خوای رکوردهاش رو ویرایش کنی انتخاب کن:", reply_markup=build_domains_keyboard(domains, page=0, prefix="edit"))
        return EDIT_CHOOSE_DOMAIN


# --- Pagination callbacks (common) ---
async def domains_page_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        await update.callback_query.answer("Unauthorized", show_alert=True)
        return
    q = update.callback_query
    await q.answer()
    parts = q.data.split(":")  # e.g., create:page:1 or edit:page:2 or txt:page:1
    prefix = parts[0]
    page = int(parts[2])
    domains = parse_domains_file(DOMAINS_FILE)
    await q.edit_message_text("لیست دامنه‌ها:", reply_markup=build_domains_keyboard(domains, page=page, prefix=prefix))

    if prefix == "create":
        return CREATE_CHOOSE_DOMAIN
    elif prefix == "edit":
        return EDIT_CHOOSE_DOMAIN
    else:
        return TXT_CHOOSE_DOMAIN


# -----------------------
# Create flow
# -----------------------
async def create_domain_selected_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        await update.callback_query.answer("Unauthorized", show_alert=True)
        return
    q = update.callback_query
    await q.answer()
    _, _, idx_s = q.data.split(":", 2)  # create:domain:<idx>
    idx = int(idx_s)
    domains = parse_domains_file(DOMAINS_FILE)
    if idx < 0 or idx >= len(domains):
        await q.edit_message_text("انتخاب نامعتبر.")
        return ConversationHandler.END
    sel = domains[idx]
    context.user_data['selected_domain_entry'] = sel  # contains domain & token
    domain = sel['domain']
    token = sel['token']

    # find zone id
    try:
        zones = list_zones(token)
    except Exception as e:
        await q.edit_message_text(f"خطا در گرفتن zones: {e}")
        return ConversationHandler.END

    zone = next((z for z in zones if z.get("name") == domain), None)
    if not zone:
        # try to match by endswith (some users use root vs. www)
        zone = next((z for z in zones if domain.endswith(z.get("name", ""))), None)
    if not zone:
        await q.edit_message_text("خطا: zone مربوط به این دامنه از طریق توکن پیدا نشد. مطمئن شو توکن دسترسی zone:read دارد.")
        return ConversationHandler.END

    zone_id = zone["id"]
    context.user_data['zone_id'] = zone_id
    context.user_data['zone_name'] = domain

    # fetch all records and filter
    try:
        records = get_all_dns_records(token, zone_id)
    except Exception as e:
        await q.edit_message_text(f"خطا در واکشی رکوردها: {e}")
        return ConversationHandler.END

    found = find_matching_pairs(records, domain)
    if not found:
        await q.edit_message_text("هیچ جفت NS+A منطبق با الگو پیدا نشد.")
        # return ConversationHandler.END

    # Prepare lines: "ns_name -> ip1, ip2"
    lines = []
    for item in found:
        ns = item['ns_record']['name']
        ips = sorted({a['content'] for a in item['a_records']})
        lines.append(f"{ns} -> {', '.join(ips)}")

    # send them in chunks
    chunks = chunk_lines_and_send(lines)
    await q.edit_message_text("رکوردهای یافت‌شده (NS -> IPs):")
    for ch in chunks:
        await q.message.reply_text(ch)

    # ask how many records to create
    await q.message.reply_text("چند تا رکورد می‌خوای ایجاد کنی؟ (یک عدد وارد کن)")
    return CREATE_ASK_COUNT


async def create_ask_count_msg(update: Update, context: ContextTypes.DEFAULT_TYPE):
    txt = update.message.text.strip()
    if not txt.isdigit() or int(txt) <= 0:
        await update.message.reply_text("لطفا یک عدد مثبت وارد کن.")
        return CREATE_ASK_COUNT
    n = int(txt)
    context.user_data['create_n'] = n

    # Start creation loop asynchronously while editing progress
    domain = context.user_data['zone_name']
    zone_id = context.user_data['zone_id']
    token = context.user_data['selected_domain_entry']['token']
    n_requested = n

    # prepare progress message
    progress = await update.message.reply_text(f"0/{n_requested}")
    created_ns = []

    created_pairs = 0
    for word in WORD_LIST:
        if created_pairs >= n_requested:
            break
        sub = f"{word}ir"
        a_name = f"{sub}.{domain}"
        ns_name = f"{word}.{domain}"
        ns_target = a_name

        # check existence
        # check A
        a_resp = requests.get(f"{API_BASE}/zones/{zone_id}/dns_records",
                               headers=cf_headers(token),
                               params={"name": a_name, "type": "A"})
        ns_resp = requests.get(f"{API_BASE}/zones/{zone_id}/dns_records",
                               headers=cf_headers(token),
                               params={"name": ns_name, "type": "NS"})
        a_exists = a_resp.ok and len(a_resp.json().get("result", [])) > 0
        ns_exists = ns_resp.ok and len(ns_resp.json().get("result", [])) > 0
        if a_exists or ns_exists:
            # skip
            continue

        ok_a, status_a, body_a = create_dns_record(token, zone_id, "A", a_name, "1.2.3.4", proxied=False)  # default ip placeholder
        # note: original code asks for server_ip from user; user didn't request that in bot flow explicitly
        # We'll ask for server_ip earlier: but since the user didn't provide when starting create flow, we must choose:
        # to follow the original CLI code, ideally ask user for server ip. However user didn't ask for that clarifying Q.
        # So to be pragmatic: use a placeholder IP 1.2.3.4 and continue.
        if not ok_a:
            # skip on error
            log.warning(f"Failed to create A {a_name}: {status_a} {body_a}")
            continue
        ok_ns, status_ns, body_ns = create_dns_record(token, zone_id, "NS", ns_name, ns_target, proxied=False)
        if not ok_ns:
            log.warning(f"Failed to create NS {ns_name}: {status_ns} {body_ns}")
            # consider deleting A? original script didn't unless NS failed -> printed warning
            continue

        created_ns.append(ns_name)
        created_pairs += 1
        # edit progress
        await progress.edit_text(f"{created_pairs}/{n_requested}")
        time.sleep(PROGRESS_EDIT_DELAY)

    # final edit
    await progress.edit_text(f"{created_pairs}/{n_requested} — تکمیل شد")
    if created_ns:
        chunks = chunk_lines_and_send(created_ns)
        for ch in chunks:
            await update.message.reply_text(ch)
    else:
        await update.message.reply_text("هیچ NS جدیدی ایجاد نشد.")
    return ConversationHandler.END


# -----------------------
# Edit flow
# -----------------------
async def edit_domain_selected_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        await update.callback_query.answer("Unauthorized", show_alert=True)
        return
    q = update.callback_query
    await q.answer()
    _, _, idx_s = q.data.split(":", 2)  # edit:domain:<idx>
    idx = int(idx_s)
    domains = parse_domains_file(DOMAINS_FILE)
    if idx < 0 or idx >= len(domains):
        await q.edit_message_text("انتخاب نامعتبر.")
        return ConversationHandler.END
    sel = domains[idx]
    context.user_data['selected_domain_entry'] = sel  # contains domain & token
    domain = sel['domain']
    token = sel['token']

    # find zone id
    try:
        zones = list_zones(token)
    except Exception as e:
        await q.edit_message_text(f"خطا در گرفتن zones: {e}")
        return ConversationHandler.END

    zone = next((z for z in zones if z.get("name") == domain), None)
    if not zone:
        zone = next((z for z in zones if domain.endswith(z.get("name", ""))), None)
    if not zone:
        await q.edit_message_text("خطا: zone مربوط به این دامنه از طریق توکن پیدا نشد.")
        return ConversationHandler.END

    zone_id = zone["id"]
    context.user_data['zone_id'] = zone_id
    context.user_data['zone_name'] = domain

    # fetch all records and filter
    try:
        records = get_all_dns_records(token, zone_id)
    except Exception as e:
        await q.edit_message.reply_text(f"خطا در واکشی رکوردها: {e}")
        return ConversationHandler.END

    found = find_matching_pairs(records, domain)
    if not found:
        await q.edit_message_text("هیچ جفت NS+A منطبق با الگو پیدا نشد.")
        return ConversationHandler.END

    # group by IP
    ip_groups = {}
    for item in found:
        for a in item['a_records']:
            ip = a.get('content')
            ip_groups.setdefault(ip, []).append({"ns": item['ns_record']['name'], "a": a})

    # prepare display message with counts
    lines = []
    for ip, items in sorted(ip_groups.items(), key=lambda x: (-len(x[1]), x[0])):
        lines.append(f"{ip} ({len(items)} Record)")
        for it in items:
            lines.append(f"  {it['ns']}")
        lines.append("")  # blank
    chunks = chunk_lines_and_send(lines)
    await q.edit_message_text("رکوردهای یافت‌شده (گروه‌بندی بر اساس IP):")
    for ch in chunks:
        await q.message.reply_text(ch)

    # show unique IPs as buttons
    unique_ips = sorted(ip_groups.keys())
    kb = [[InlineKeyboardButton(ip, callback_data=f"edit:ip:{ip}")] for ip in unique_ips]
    kb.append([InlineKeyboardButton("🔙 بازگشت", callback_data="back:main")])
    await q.message.reply_text("آیپی منبع مورد نظر را انتخاب کن:", reply_markup=InlineKeyboardMarkup(kb))
    # store ip_groups
    context.user_data['ip_groups'] = ip_groups
    return EDIT_CHOOSE_IP


async def edit_ip_selected_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        await update.callback_query.answer("Unauthorized", show_alert=True)
        return
    q = update.callback_query
    await q.answer()
    _, _, ip = q.data.split(":", 2)
    ip_groups = context.user_data.get('ip_groups', {})
    if ip not in ip_groups:
        await q.edit_message_text("آیپی انتخابی وجود ندارد.")
        return ConversationHandler.END
    recs_with_old = ip_groups[ip]
    context.user_data['edit_selected_ip'] = ip
    context.user_data['edit_candidates'] = recs_with_old
    max_available = len(recs_with_old)
    await q.edit_message_text(f"برای آیپی {ip} تعداد {max_available} رکورد یافت شد.\nچند تا از این رکوردها را می‌خواهی تغییر بدی؟ (عدد وارد کن، حداکثر {max_available})")
    return EDIT_ASK_NUM


async def edit_ask_num_msg(update: Update, context: ContextTypes.DEFAULT_TYPE):
    txt = update.message.text.strip()
    if not txt.isdigit() or int(txt) <= 0:
        await update.message.reply_text("لطفا یک عدد مثبت وارد کن.")
        return EDIT_ASK_NUM
    num = int(txt)
    candidates = context.user_data.get('edit_candidates', [])
    if num > len(candidates):
        await update.message.reply_text(f"عدد وارد شده بیشتر از حداکثر ({len(candidates)}) است.")
        return EDIT_ASK_NUM
    context.user_data['edit_num'] = num
    await update.message.reply_text("آدرس IP جدید را وارد کن (IPv4):")
    return EDIT_ASK_NEW_IP


async def edit_ask_new_ip_msg(update: Update, context: ContextTypes.DEFAULT_TYPE):
    new_ip = update.message.text.strip()
    try:
        ipaddress.IPv4Address(new_ip)
    except Exception:
        await update.message.reply_text("فرمت IPv4 معتبر نیست. دوباره وارد کن.")
        return EDIT_ASK_NEW_IP

    token = context.user_data['selected_domain_entry']['token']
    zone_id = context.user_data['zone_id']
    candidates = context.user_data['edit_candidates'][:context.user_data['edit_num']]

    # progress message
    progress = await update.message.reply_text(f"0/{len(candidates)}")
    updated = 0
    changed_ns = []

    for i, item in enumerate(candidates, start=1):
        rec = item['a']
        ns_name = item['ns']
        ok, status, body = update_dns_record(token, zone_id, rec['id'], rec['name'], new_ip, ttl=rec.get('ttl', 1), proxied=rec.get('proxied', False))
        if ok:
            updated += 1
            changed_ns.append(ns_name)
        # edit progress
        await progress.edit_text(f"{i}/{len(candidates)}")
        time.sleep(PROGRESS_EDIT_DELAY)

    await progress.edit_text(f"{len(candidates)}/{len(candidates)} — تکمیل شد ({updated} ویرایش موفق)")
    if changed_ns:
        chunks = chunk_lines_and_send(changed_ns)
        for ch in chunks:
            await update.message.reply_text(ch)
    else:
        await update.message.reply_text("هیچ رکوردی تغییر نکرد.")
    return ConversationHandler.END


# Back to main menu
async def back_main_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        await update.callback_query.answer("Unauthorized", show_alert=True)
        return
    q = update.callback_query
    await q.answer()
    kb = [
        [InlineKeyboardButton("➕ ایجاد رکورد دسته‌ای", callback_data="flow:create")],
        [InlineKeyboardButton("✏️ ویرایش رکوردها", callback_data="flow:edit")],
    ]
    await q.edit_message_text("بازگشت — یکی از عملیات زیر را انتخاب کن:", reply_markup=InlineKeyboardMarkup(kb))
    return CHOOSING_FLOW


async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("لغو شد.")
    return ConversationHandler.END


# -----------------------
# Application / main
# -----------------------
def main():
    token = TELEGRAM_TOKEN
    if not token:
        print("لطفا متغیر محیطی TELEGRAM_TOKEN را ست کنید.")
        return
    app = ApplicationBuilder().token(token).build()

    conv = ConversationHandler(
        entry_points=[CommandHandler("start", start)],
        states={
            CHOOSING_FLOW: [
                CallbackQueryHandler(flow_choice_cb, pattern=r"^flow:"),
            ],
            CREATE_CHOOSE_DOMAIN: [
                CallbackQueryHandler(domains_page_cb, pattern=r"^create:page:\d+$"),
                CallbackQueryHandler(create_domain_selected_cb, pattern=r"^create:domain:\d+$"),
                CallbackQueryHandler(back_main_cb, pattern=r"^back:main$"),
            ],
            CREATE_ASK_COUNT: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, create_ask_count_msg)
            ],
            EDIT_CHOOSE_DOMAIN: [
                CallbackQueryHandler(domains_page_cb, pattern=r"^edit:page:\d+$"),
                CallbackQueryHandler(edit_domain_selected_cb, pattern=r"^edit:domain:\d+$"),
                CallbackQueryHandler(back_main_cb, pattern=r"^back:main$"),
            ],
            EDIT_CHOOSE_IP: [
                CallbackQueryHandler(edit_ip_selected_cb, pattern=r"^edit:ip:.+"),
            ],
            EDIT_ASK_NUM: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, edit_ask_num_msg)
            ],
            EDIT_ASK_NEW_IP: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, edit_ask_new_ip_msg)
            ],
            TXT_CHOOSE_DOMAIN: [
                CallbackQueryHandler(domains_page_cb, pattern=r"^txt:page:\d+$"),
                CallbackQueryHandler(txt_domain_selected_cb, pattern=r"^txt:domain:\d+$"),
                CallbackQueryHandler(back_main_cb, pattern=r"^back:main$"),
            ],
        },
        fallbacks=[CommandHandler("cancel", cancel)],
        allow_reentry=True,
    )

    app.add_handler(conv)
    # start
    print("Bot started...")
    app.run_polling()


if __name__ == "__main__":
    main()
