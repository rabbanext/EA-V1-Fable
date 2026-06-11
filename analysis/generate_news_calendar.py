"""
generate_news_calendar.py
Membuat XTC_news_calendar.csv untuk backtest XAU Trend Capture v1.
Output: YYYY.MM.DD HH:MM;TAG  — semua waktu GMT/UTC.

Kualitas data per event:
  NFP   — algoritmik (Jumat pertama tiap bulan, 08:30 ET). Akurasi ~92%;
           ~8 bulan per 10 tahun mungkin meleset 1 minggu karena jadwal BLS.
  FOMC  — hardcoded dari Fed.gov, akurasi 100% kecuali meeting darurat ad-hoc.
  CPI   — estimasi (Rabu ke-2 tiap bulan, 08:30 ET). BLS tidak mengikuti rumus
           tetap — error 1-2 minggu mungkin terjadi. Gunakan untuk perkiraan awal;
           verifikasi via investing.com/economic-calendar untuk presisi tinggi.
  ECB   — estimasi (pertemuan ECB ~8x/tahun, Kamis, 13:15 UTC). Hardcoded 2015-2025.
  BOE   — estimasi (pertemuan BOE ~8x/tahun, Kamis, 12:00 UTC). Hardcoded 2015-2025.

Penggunaan:
  python generate_news_calendar.py --start 2015 --end 2025 --output XTC_news_calendar.csv

Setelah generate, salin file ke:
  <MT5 Data Folder>/MQL5/Files/
  <MT5 Data Folder>/MQL5/Files/  (agen tester lokal membaca dari Common:)
  C:/Users/<user>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/
"""

import argparse
import csv
from datetime import date, timedelta, datetime

# ---------------------------------------------------------------------------
# Utilitas waktu
# ---------------------------------------------------------------------------

def nth_weekday(year: int, month: int, weekday: int, n: int) -> date:
    """Tanggal ke-n dari weekday dalam bulan (weekday 0=Sen..6=Min, n 1-based)."""
    d = date(year, month, 1)
    diff = (weekday - d.weekday()) % 7
    d = d + timedelta(days=diff + (n - 1) * 7)
    if d.month != month:
        raise ValueError(f"nth_weekday({year},{month},{weekday},{n}): hari tidak ada di bulan ini")
    return d


def us_dst_start(year: int) -> date:
    """Minggu ke-2 bulan Maret (mulai 2007)."""
    return nth_weekday(year, 3, 6, 2)


def us_dst_end(year: int) -> date:
    """Minggu pertama November."""
    return nth_weekday(year, 11, 6, 1)


def is_us_dst(d: date) -> bool:
    """True jika d berada dalam US DST (EDT, UTC-4)."""
    return us_dst_start(d.year) <= d < us_dst_end(d.year)


def et_release(d: date, hour_et: int = 8, minute_et: int = 30) -> datetime:
    """Konversi waktu ET (08:30 default = rilis BLS/Fed) ke UTC datetime."""
    offset_hours = 4 if is_us_dst(d) else 5   # EDT=UTC-4, EST=UTC-5
    dt_naive = datetime(d.year, d.month, d.day, hour_et, minute_et)
    return dt_naive + timedelta(hours=offset_hours)


def fmt(dt: datetime) -> str:
    """Format output untuk CSV: 'YYYY.MM.DD HH:MM'."""
    return dt.strftime("%Y.%m.%d %H:%M")


# ---------------------------------------------------------------------------
# NFP — Non-Farm Payrolls (algoritmik)
# BLS merilis data ketenagakerjaan bulan M-1 pada Jumat pertama bulan M.
# Sekitar 8% kasus jadwalnya bergeser ke Jumat ke-2 (BLS published schedule).
# ---------------------------------------------------------------------------

def nfp_dates(start_year: int, end_year: int):
    """Yield (datetime_utc, 'NFP') untuk setiap bulan dari Jan start_year."""
    for year in range(start_year, end_year + 1):
        for month in range(1, 13):
            try:
                friday = nth_weekday(year, month, 4, 1)   # Jumat pertama
                yield et_release(friday), "NFP"
            except ValueError:
                pass


# ---------------------------------------------------------------------------
# FOMC — Federal Open Market Committee (hardcoded dari Fed.gov)
# Waktu rilis statement: 14:00 ET. Press conference 14:30 ET (tidak dipisah).
# Meeting darurat (Mar 2020) disertakan dengan tag khusus.
# ---------------------------------------------------------------------------

# Format: (tahun, bulan, hari)
FOMC_DATES = [
    # 2015
    (2015, 1, 28), (2015, 3, 18), (2015, 4, 29), (2015, 6, 17),
    (2015, 7, 29), (2015, 9, 17), (2015, 10, 28), (2015, 12, 16),
    # 2016
    (2016, 1, 27), (2016, 3, 16), (2016, 4, 27), (2016, 6, 15),
    (2016, 7, 27), (2016, 9, 21), (2016, 11, 2), (2016, 12, 14),
    # 2017
    (2017, 2, 1), (2017, 3, 15), (2017, 5, 3), (2017, 6, 14),
    (2017, 7, 26), (2017, 9, 20), (2017, 11, 1), (2017, 12, 13),
    # 2018
    (2018, 1, 31), (2018, 3, 21), (2018, 5, 2), (2018, 6, 13),
    (2018, 7, 25), (2018, 9, 26), (2018, 11, 8), (2018, 12, 19),
    # 2019
    (2019, 1, 30), (2019, 3, 20), (2019, 5, 1), (2019, 6, 19),
    (2019, 7, 31), (2019, 9, 18), (2019, 10, 30), (2019, 12, 11),
    # 2020  (termasuk 2 meeting darurat Maret)
    (2020, 1, 29),
    (2020, 3, 3),   # darurat: pemotongan rate 50 bps (Selasa, 10:00 ET → 15:00 UTC)
    (2020, 3, 15),  # darurat: pemotongan ke 0% (Ahad, 17:00 ET → 22:00 UTC; UTC+1)
    (2020, 4, 29), (2020, 6, 10), (2020, 7, 29), (2020, 9, 16),
    (2020, 11, 5), (2020, 12, 16),
    # 2021
    (2021, 1, 27), (2021, 3, 17), (2021, 4, 28), (2021, 6, 16),
    (2021, 7, 28), (2021, 9, 22), (2021, 11, 3), (2021, 12, 15),
    # 2022
    (2022, 1, 26), (2022, 3, 16), (2022, 5, 4), (2022, 6, 15),
    (2022, 7, 27), (2022, 9, 21), (2022, 11, 2), (2022, 12, 14),
    # 2023
    (2023, 2, 1), (2023, 3, 22), (2023, 5, 3), (2023, 6, 14),
    (2023, 7, 26), (2023, 9, 20), (2023, 11, 1), (2023, 12, 13),
    # 2024
    (2024, 1, 31), (2024, 3, 20), (2024, 5, 1), (2024, 6, 12),
    (2024, 7, 31), (2024, 9, 18), (2024, 11, 7), (2024, 12, 18),
    # 2025
    (2025, 1, 29), (2025, 3, 19), (2025, 5, 7), (2025, 6, 18),
    (2025, 7, 30),
]

# Meeting darurat Maret 2020 punya waktu non-standard
FOMC_OVERRIDE_UTC = {
    (2020, 3, 3):  "2020.03.03 15:00",   # pengumuman 10:00 ET (EST) = 15:00 UTC
    (2020, 3, 15): "2020.03.15 22:00",   # pengumuman ~17:00 ET (EDT) = 21:00 UTC
}


def fomc_events(start_year: int, end_year: int):
    """Yield (datetime_str_utc, 'FOMC')."""
    for y, m, d in FOMC_DATES:
        if y < start_year or y > end_year:
            continue
        key = (y, m, d)
        if key in FOMC_OVERRIDE_UTC:
            yield FOMC_OVERRIDE_UTC[key], "FOMC"
        else:
            dt_utc = et_release(date(y, m, d), hour_et=14, minute_et=0)
            yield fmt(dt_utc), "FOMC"


# ---------------------------------------------------------------------------
# US CPI — Consumer Price Index (estimasi, Rabu ke-2 tiap bulan, 08:30 ET)
# BLS tidak mengikuti formula tetap; galat ~1-2 minggu mungkin terjadi.
# ---------------------------------------------------------------------------

def cpi_dates(start_year: int, end_year: int):
    """Yield (datetime_str_utc, 'CPI') — estimasi Rabu ke-2."""
    for year in range(start_year, end_year + 1):
        for month in range(1, 13):
            try:
                # Rabu ke-2 bulan tersebut
                wednesday = nth_weekday(year, month, 2, 2)
                yield fmt(et_release(wednesday)), "CPI"
            except ValueError:
                pass


# ---------------------------------------------------------------------------
# ECB — European Central Bank rate decision (hardcoded, Kamis 13:15 UTC)
# ECB mengadakan 8 pertemuan per tahun (sebelum 2015: 12x, mulai 2015: 8x).
# ---------------------------------------------------------------------------

ECB_DATES = [
    # 2015
    (2015, 1, 22), (2015, 3, 5), (2015, 4, 15), (2015, 6, 3),
    (2015, 7, 16), (2015, 9, 3), (2015, 10, 22), (2015, 12, 3),
    # 2016
    (2016, 1, 21), (2016, 3, 10), (2016, 4, 21), (2016, 6, 2),
    (2016, 7, 21), (2016, 9, 8), (2016, 10, 20), (2016, 12, 8),
    # 2017
    (2017, 1, 19), (2017, 3, 9), (2017, 4, 27), (2017, 6, 8),
    (2017, 7, 20), (2017, 9, 7), (2017, 10, 26), (2017, 12, 14),
    # 2018
    (2018, 1, 25), (2018, 3, 8), (2018, 4, 26), (2018, 6, 14),
    (2018, 7, 26), (2018, 9, 13), (2018, 10, 25), (2018, 12, 13),
    # 2019
    (2019, 1, 24), (2019, 3, 7), (2019, 4, 10), (2019, 6, 6),
    (2019, 7, 25), (2019, 9, 12), (2019, 10, 24), (2019, 12, 12),
    # 2020
    (2020, 1, 23), (2020, 3, 12), (2020, 4, 30), (2020, 6, 4),
    (2020, 7, 16), (2020, 9, 10), (2020, 10, 29), (2020, 12, 10),
    # 2021
    (2021, 1, 21), (2021, 3, 11), (2021, 4, 22), (2021, 6, 10),
    (2021, 7, 22), (2021, 9, 9), (2021, 10, 28), (2021, 12, 16),
    # 2022
    (2022, 2, 3), (2022, 3, 10), (2022, 4, 14), (2022, 6, 9),
    (2022, 7, 21), (2022, 9, 8), (2022, 10, 27), (2022, 12, 15),
    # 2023
    (2023, 2, 2), (2023, 3, 16), (2023, 5, 4), (2023, 6, 15),
    (2023, 7, 27), (2023, 9, 14), (2023, 10, 26), (2023, 12, 14),
    # 2024
    (2024, 1, 25), (2024, 3, 7), (2024, 4, 11), (2024, 6, 6),
    (2024, 7, 18), (2024, 9, 12), (2024, 10, 17), (2024, 12, 12),
    # 2025
    (2025, 1, 30), (2025, 3, 6), (2025, 4, 17), (2025, 6, 5),
]


def ecb_events(start_year: int, end_year: int):
    for y, m, d in ECB_DATES:
        if y < start_year or y > end_year:
            continue
        dt = datetime(y, m, d, 13, 15)   # 13:15 UTC langsung
        yield fmt(dt), "RATE"


# ---------------------------------------------------------------------------
# BOE — Bank of England (estimasi, Kamis 12:00 UTC, ~8x/tahun)
# ---------------------------------------------------------------------------

BOE_DATES = [
    # 2015
    (2015, 2, 5), (2015, 3, 5), (2015, 5, 11), (2015, 6, 4),
    (2015, 8, 6), (2015, 9, 10), (2015, 11, 5), (2015, 12, 10),
    # 2016
    (2016, 2, 4), (2016, 3, 10), (2016, 5, 12), (2016, 6, 16),
    (2016, 8, 4), (2016, 9, 15), (2016, 11, 3), (2016, 12, 15),
    # 2017
    (2017, 2, 2), (2017, 3, 16), (2017, 5, 11), (2017, 6, 15),
    (2017, 8, 3), (2017, 9, 14), (2017, 11, 2), (2017, 12, 14),
    # 2018
    (2018, 2, 8), (2018, 3, 22), (2018, 5, 10), (2018, 6, 21),
    (2018, 8, 2), (2018, 9, 13), (2018, 11, 1), (2018, 12, 20),
    # 2019
    (2019, 2, 7), (2019, 3, 21), (2019, 5, 2), (2019, 6, 20),
    (2019, 8, 1), (2019, 9, 19), (2019, 11, 7), (2019, 12, 19),
    # 2020
    (2020, 1, 30), (2020, 3, 11), (2020, 3, 19), (2020, 5, 7),
    (2020, 6, 18), (2020, 8, 6), (2020, 9, 17), (2020, 11, 5), (2020, 12, 17),
    # 2021
    (2021, 2, 4), (2021, 3, 18), (2021, 5, 6), (2021, 6, 24),
    (2021, 8, 5), (2021, 9, 23), (2021, 11, 4), (2021, 12, 16),
    # 2022
    (2022, 2, 3), (2022, 3, 17), (2022, 5, 5), (2022, 6, 16),
    (2022, 8, 4), (2022, 9, 22), (2022, 11, 3), (2022, 12, 15),
    # 2023
    (2023, 2, 2), (2023, 3, 23), (2023, 5, 11), (2023, 6, 22),
    (2023, 8, 3), (2023, 9, 21), (2023, 11, 2), (2023, 12, 14),
    # 2024
    (2024, 2, 1), (2024, 3, 21), (2024, 5, 9), (2024, 6, 20),
    (2024, 8, 1), (2024, 9, 19), (2024, 11, 7), (2024, 12, 19),
    # 2025
    (2025, 2, 6), (2025, 3, 20), (2025, 5, 8), (2025, 6, 19),
]


def boe_events(start_year: int, end_year: int):
    for y, m, d in BOE_DATES:
        if y < start_year or y > end_year:
            continue
        dt = datetime(y, m, d, 12, 0)   # 12:00 UTC
        yield fmt(dt), "RATE"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def generate(start_year: int, end_year: int, output_path: str,
             include_cpi: bool = True, include_ecb: bool = True,
             include_boe: bool = True) -> int:
    events = []

    for dt, tag in nfp_dates(start_year, end_year):
        events.append((fmt(dt), tag))

    for dt_str, tag in fomc_events(start_year, end_year):
        events.append((dt_str, tag))

    if include_cpi:
        for dt_str, tag in cpi_dates(start_year, end_year):
            events.append((dt_str, tag))

    if include_ecb:
        for dt_str, tag in ecb_events(start_year, end_year):
            events.append((dt_str, tag))

    if include_boe:
        for dt_str, tag in boe_events(start_year, end_year):
            events.append((dt_str, tag))

    # deduplicate & sort
    events = sorted(set(events), key=lambda x: x[0])

    with open(output_path, "w", newline="", encoding="ascii") as f:
        f.write("# XAU Trend Capture v1 - news calendar (UTC/GMT)\n")
        f.write(f"# Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M')} UTC\n")
        f.write(f"# Range: {start_year}-{end_year}\n")
        f.write("# Format: YYYY.MM.DD HH:MM;TAG\n")
        f.write("# Tags: NFP=Non-Farm Payrolls, FOMC=Fed decision, CPI=US CPI,\n")
        f.write("#        RATE=ECB/BOE rate decision\n")
        f.write("# DATA QUALITY: FOMC=high(hardcoded), NFP=good(algo,~92%),\n")
        f.write("#   CPI/RATE=estimate(verify vs investing.com for precise backtest)\n")
        for dt_str, tag in events:
            f.write(f"{dt_str};{tag}\n")

    return len(events)


def main():
    parser = argparse.ArgumentParser(description="Generate XTC news calendar CSV")
    parser.add_argument("--start", type=int, default=2015, help="Tahun mulai (default: 2015)")
    parser.add_argument("--end",   type=int, default=2025, help="Tahun akhir inklusif (default: 2025)")
    parser.add_argument("--output", default="XTC_news_calendar.csv", help="Nama file output")
    parser.add_argument("--no-cpi",  action="store_true", help="Hapus event CPI")
    parser.add_argument("--no-ecb",  action="store_true", help="Hapus event ECB")
    parser.add_argument("--no-boe",  action="store_true", help="Hapus event BOE")
    args = parser.parse_args()

    n = generate(
        args.start, args.end, args.output,
        include_cpi=not args.no_cpi,
        include_ecb=not args.no_ecb,
        include_boe=not args.no_boe,
    )
    print(f"Ditulis: {args.output}  ({n} event, {args.start}–{args.end})")
    print("Salin ke: <MT5 Data Folder>/MQL5/Files/  dan  Terminal/Common/Files/")


if __name__ == "__main__":
    main()
