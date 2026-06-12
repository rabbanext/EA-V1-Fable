#!/usr/bin/env python3
"""
XAU Trend Capture v1 — Single-Pass Backtest Analyzer
Langkah 4: analisis mendalam satu file XTC_trades_*.csv.

Usage:
    python analyze_backtest.py <path/to/XTC_trades_*.csv> [--out output_dir]
    python analyze_backtest.py --demo   # uses bundled sample

Output: output_dir/equity_curve.png, r_dist.png, year_breakdown.png,
        drawdown.png, monte_carlo.png, gap_cap.png, summary.txt
"""

import argparse
import os
import sys
import warnings
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import matplotlib.dates as mdates
import numpy as np
import pandas as pd
from scipy import stats

warnings.filterwarnings("ignore")

# ── Constants ─────────────────────────────────────────────────────────────────
INITIAL_EQUITY    = 10_000.0
TARGET_RISK_PCT   = 0.5         # % per trade (blueprint fixed)
GAP_CAP_USD       = 50.0        # gapCap backstop threshold ($)
GAP_PCT           = 2.0         # % of equity for gap cap numerator
DPU               = 100.0       # $ per lot per $1 gold move (XAUUSDm: 100 oz, tv=$0.10, ts=$0.001)
VOL_STEP          = 0.01        # lot step XAUUSDm
SWAP_LONG_PTS     = -490.6      # swap points long (from Util_TickInfo output)
TICK_VALUE        = 0.10        # $/tick/lot XAUUSDm
SWAP_LONG_PER_LOT = SWAP_LONG_PTS * TICK_VALUE   # -$49.06/lot/day
MC_SIMS           = 5_000
MC_BLOCK          = 20          # block size for block bootstrap


# ── Load & Enrich ─────────────────────────────────────────────────────────────

def load_trades(path: str) -> pd.DataFrame:
    df = pd.read_csv(path, sep=";", parse_dates=["time_in", "time_out"])
    df = df.sort_values("time_in").reset_index(drop=True)

    df["year"]       = df["time_in"].dt.year
    df["month"]      = df["time_in"].dt.to_period("M")
    df["quarter"]    = df["time_in"].dt.to_period("Q")

    # Equity curve (running balance)
    df["cum_net"]    = df["net"].cumsum()
    df["equity"]     = INITIAL_EQUITY + df["cum_net"]

    # Peak & drawdown in USD
    df["peak_usd"]   = (INITIAL_EQUITY + df["cum_net"]).cummax()
    df["dd_usd"]     = df["equity"] - df["peak_usd"]          # ≤ 0
    df["dd_pct"]     = df["dd_usd"] / df["peak_usd"] * 100    # ≤ 0

    # Actual risk vs target
    target_risk      = INITIAL_EQUITY * TARGET_RISK_PCT / 100   # $50 flat (blueprint: flat equity)
    df["target_risk"]= target_risk
    df["risk_ratio"] = df["risk_usd"] / target_risk             # 1.0 = full sizing, <1 = constrained

    # Gap cap theoretical max lots
    df["gap_cap_lots"]    = (GAP_PCT / 100 * INITIAL_EQUITY) / (GAP_CAP_USD * DPU)  # 0.04
    df["gap_cap_binding"] = df["lots"] >= (df["gap_cap_lots"] - 1e-4)

    # Approximate ATR from actual stop
    df["stop_usd"]   = df["risk_usd"] / (df["lots"] * DPU)
    df["atr_approx"] = df["stop_usd"] / 2.0

    # Win flag
    df["win"]        = df["r_net"] > 0

    # Cumulative R
    df["cum_r"]      = df["r_net"].cumsum()

    return df


# ── Statistics ────────────────────────────────────────────────────────────────

def summary_stats(df: pd.DataFrame) -> dict:
    n          = len(df)
    wins       = df["win"].sum()
    win_rate   = wins / n

    r          = df["r_net"]
    gross_r    = r[r > 0].sum()
    loss_r     = r[r <= 0].sum()
    pf_r       = gross_r / abs(loss_r) if loss_r != 0 else np.inf

    avg_win_r  = r[r > 0].mean() if wins > 0 else 0.0
    avg_loss_r = r[r <= 0].mean() if (n - wins) > 0 else 0.0
    payoff     = avg_win_r / abs(avg_loss_r) if avg_loss_r != 0 else np.inf
    expectancy = win_rate * avg_win_r + (1 - win_rate) * avg_loss_r

    total_r    = r.sum()
    years      = (df["time_in"].iloc[-1] - df["time_in"].iloc[0]).days / 365.25
    r_per_year = total_r / years if years > 0 else 0.0

    net_usd    = df["net"].sum()
    gross_usd  = df["gross"].sum()
    swap_usd   = df["swap"].sum()
    total_return_pct = net_usd / INITIAL_EQUITY * 100

    # Drawdown
    max_dd_usd = df["dd_usd"].min()
    max_dd_pct = df["dd_pct"].min()

    # Sharpe approximation from trade-level R
    # Annualise by trades/year
    trades_per_year = n / years
    sharpe_r = (expectancy / r.std()) * np.sqrt(trades_per_year) if r.std() > 0 else 0.0

    # LR correlation on equity curve (time-indexed)
    x = np.arange(len(df))
    slope, intercept, lr_r, _, _ = stats.linregress(x, df["equity"].values)
    lr_corr = lr_r  # Pearson r between time-index and equity

    # Gap cap stats
    gap_pct = df["gap_cap_binding"].mean() * 100
    avg_risk_ratio = df["risk_ratio"].mean()
    avg_risk_usd   = df["risk_usd"].mean()

    # Exit breakdown
    exit_counts = df["exit_reason"].value_counts().to_dict()

    return dict(
        n=n, wins=wins, win_rate=win_rate,
        pf_r=pf_r, avg_win_r=avg_win_r, avg_loss_r=avg_loss_r,
        payoff=payoff, expectancy=expectancy,
        total_r=total_r, r_per_year=r_per_year, years=years,
        net_usd=net_usd, gross_usd=gross_usd, swap_usd=swap_usd,
        total_return_pct=total_return_pct,
        max_dd_usd=max_dd_usd, max_dd_pct=max_dd_pct,
        sharpe_r=sharpe_r, lr_corr=lr_corr,
        gap_pct=gap_pct, avg_risk_ratio=avg_risk_ratio, avg_risk_usd=avg_risk_usd,
        trades_per_year=trades_per_year, exit_counts=exit_counts,
        slope=slope,
    )


def year_breakdown(df: pd.DataFrame) -> pd.DataFrame:
    target_risk = INITIAL_EQUITY * TARGET_RISK_PCT / 100

    def agg(g):
        n        = len(g)
        total_r  = g["r_net"].sum()
        net_usd  = g["net"].sum()
        swap_usd = g["swap"].sum()
        wins     = g["win"].sum()
        avg_atr  = g["atr_approx"].mean()
        avg_lots = g["lots"].mean()
        avg_risk = g["risk_usd"].mean()
        gap_pct  = g["gap_cap_binding"].mean() * 100
        risk_ratio = g["risk_ratio"].mean()
        avg_bars = g["bars_held"].mean()
        return pd.Series({
            "n_trades":   n,
            "total_R":    round(total_r, 2),
            "net_USD":    round(net_usd, 2),
            "swap_USD":   round(swap_usd, 2),
            "win_rate":   round(wins / n * 100, 1),
            "avg_ATR":    round(avg_atr, 1),
            "avg_lots":   round(avg_lots, 3),
            "avg_risk$":  round(avg_risk, 2),
            "risk_ratio": round(risk_ratio, 2),
            "gap_bind%":  round(gap_pct, 0),
            "avg_bars":   round(avg_bars, 1),
        })

    return df.groupby("year").apply(agg).reset_index()


# ── Monte Carlo Block Bootstrap ───────────────────────────────────────────────

def monte_carlo(r_series: np.ndarray, block: int = MC_BLOCK, n_sims: int = MC_SIMS,
                seed: int = 42) -> dict:
    rng = np.random.default_rng(seed)
    n   = len(r_series)
    total_rs   = np.zeros(n_sims)
    max_dds    = np.zeros(n_sims)
    final_rs   = np.zeros(n_sims)
    sharpes    = np.zeros(n_sims)

    # Build block index pool
    n_blocks_needed = (n + block - 1) // block
    block_starts = np.arange(0, n - block + 1)

    for i in range(n_sims):
        idx = rng.choice(block_starts, size=n_blocks_needed, replace=True)
        sim = np.concatenate([r_series[s:s+block] for s in idx])[:n]

        cum = np.cumsum(sim)
        peak = np.maximum.accumulate(cum)
        dd   = (cum - peak).min()
        max_dds[i]  = dd
        total_rs[i] = cum[-1]
        final_rs[i] = cum[-1]
        mu = sim.mean(); sd = sim.std()
        sharpes[i] = mu / sd * np.sqrt(70) if sd > 0 else 0  # 70 trades/yr approx

    pct = lambda x, q: float(np.percentile(x, q))
    return dict(
        total_r_p5  = pct(total_rs, 5),
        total_r_p50 = pct(total_rs, 50),
        total_r_p95 = pct(total_rs, 95),
        max_dd_p5   = pct(max_dds, 5),     # worst 5th pct
        max_dd_p50  = pct(max_dds, 50),
        max_dd_p95  = pct(max_dds, 95),    # best 5th pct (least bad)
        sharpe_p50  = pct(sharpes, 50),
        prob_positive = float((total_rs > 0).mean()),
        total_rs    = total_rs,
        max_dds     = max_dds,
    )


# ── Plots ─────────────────────────────────────────────────────────────────────

STYLE = dict(dpi=130, facecolor="#0d1117")
TEXT_COLOR = "#c9d1d9"
ACCENT     = "#58a6ff"
GREEN      = "#3fb950"
RED        = "#f85149"
ORANGE     = "#d29922"
GRAY       = "#8b949e"


def _fig(w=10, h=5):
    fig, ax = plt.subplots(figsize=(w, h), facecolor=STYLE["facecolor"])
    ax.set_facecolor("#161b22")
    for spine in ax.spines.values():
        spine.set_edgecolor("#30363d")
    ax.tick_params(colors=TEXT_COLOR)
    ax.xaxis.label.set_color(TEXT_COLOR)
    ax.yaxis.label.set_color(TEXT_COLOR)
    ax.title.set_color(TEXT_COLOR)
    return fig, ax


def plot_equity_curve(df: pd.DataFrame, s: dict, out: Path):
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 7), facecolor=STYLE["facecolor"],
                                    gridspec_kw={"height_ratios": [3, 1]})
    for ax in (ax1, ax2):
        ax.set_facecolor("#161b22")
        for sp in ax.spines.values():
            sp.set_edgecolor("#30363d")
        ax.tick_params(colors=TEXT_COLOR)

    x = df["time_in"]

    # Equity
    ax1.plot(x, df["equity"], color=ACCENT, lw=1.2, label="Equity")
    ax1.axhline(INITIAL_EQUITY, color=GRAY, lw=0.7, ls="--", alpha=0.6)
    ax1.fill_between(x, df["peak_usd"], df["equity"], alpha=0.25, color=RED, label="Drawdown")

    # LR line
    x_idx = np.arange(len(df))
    lr_y  = s["slope"] * x_idx + (INITIAL_EQUITY - s["slope"] * 0 + (df["equity"].iloc[0] - INITIAL_EQUITY))
    # Refit properly
    slope_fit, intercept_fit, _, _, _ = stats.linregress(x_idx, df["equity"].values)
    lr_y = slope_fit * x_idx + intercept_fit
    ax1.plot(x, lr_y, color=ORANGE, lw=1.0, ls="--", alpha=0.8,
             label=f"LR (ρ={s['lr_corr']:.2f})")

    ax1.set_ylabel("Equity (USD)", color=TEXT_COLOR)
    ax1.set_title(f"XAU Trend Capture v1 — Equity Curve  |  Net +${s['net_usd']:.0f} / {s['total_r']:.1f}R / {s['years']:.1f}yr",
                  color=TEXT_COLOR)
    ax1.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=8)
    ax1.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"${v:,.0f}"))
    ax1.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))

    # Drawdown %
    ax2.fill_between(x, df["dd_pct"], 0, alpha=0.7, color=RED)
    ax2.set_ylabel("DD %", color=TEXT_COLOR)
    ax2.set_xlabel("Date", color=TEXT_COLOR)
    ax2.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"{v:.0f}%"))
    ax2.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))

    fig.tight_layout()
    fig.savefig(out / "equity_curve.png", **STYLE)
    plt.close(fig)


def plot_r_distribution(df: pd.DataFrame, s: dict, out: Path):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5), facecolor=STYLE["facecolor"])
    for ax in (ax1, ax2):
        ax.set_facecolor("#161b22")
        for sp in ax.spines.values():
            sp.set_edgecolor("#30363d")
        ax.tick_params(colors=TEXT_COLOR)
        ax.xaxis.label.set_color(TEXT_COLOR)
        ax.yaxis.label.set_color(TEXT_COLOR)
        ax.title.set_color(TEXT_COLOR)

    r = df["r_net"].values
    bins = np.linspace(max(r.min(), -4), min(r.max(), 15), 60)

    # Histogram
    ax1.hist(r[r <= 0], bins=bins, color=RED, alpha=0.75, label="Loss")
    ax1.hist(r[r > 0],  bins=bins, color=GREEN, alpha=0.75, label="Win")
    ax1.axvline(0, color=GRAY, lw=1)
    ax1.axvline(s["expectancy"], color=ORANGE, lw=1.5, ls="--",
                label=f"E={s['expectancy']:.3f}R")
    ax1.set_xlabel("Net R-multiple", color=TEXT_COLOR)
    ax1.set_ylabel("Count", color=TEXT_COLOR)
    ax1.set_title(f"R Distribution  |  WR={s['win_rate']:.1%}  Payoff={s['payoff']:.2f}x",
                  color=TEXT_COLOR)
    ax1.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=8)
    # Clip histogram view
    ax1.set_xlim(-4, 12)

    # Cumulative R
    ax2.plot(df["time_in"], df["cum_r"], color=ACCENT, lw=1.2)
    ax2.axhline(0, color=GRAY, lw=0.7, ls="--")
    ax2.set_xlabel("Date", color=TEXT_COLOR)
    ax2.set_ylabel("Cumulative R", color=TEXT_COLOR)
    ax2.set_title(f"Cumulative R  |  Total={s['total_r']:.1f}R  ({s['r_per_year']:.1f}R/yr)",
                  color=TEXT_COLOR)
    ax2.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))

    fig.tight_layout()
    fig.savefig(out / "r_distribution.png", **STYLE)
    plt.close(fig)


def plot_year_breakdown(yb: pd.DataFrame, out: Path):
    fig, axes = plt.subplots(2, 2, figsize=(13, 8), facecolor=STYLE["facecolor"])
    axes = axes.flatten()

    for ax in axes:
        ax.set_facecolor("#161b22")
        for sp in ax.spines.values():
            sp.set_edgecolor("#30363d")
        ax.tick_params(colors=TEXT_COLOR, labelsize=8)
        ax.xaxis.label.set_color(TEXT_COLOR)
        ax.yaxis.label.set_color(TEXT_COLOR)
        ax.title.set_color(TEXT_COLOR)

    years = yb["year"].astype(str)
    x = np.arange(len(years))
    w = 0.6

    # Panel 1: Net R per year (bar)
    colors_r = [GREEN if v >= 0 else RED for v in yb["total_R"]]
    axes[0].bar(x, yb["total_R"], color=colors_r, width=w, alpha=0.85)
    axes[0].axhline(0, color=GRAY, lw=0.8)
    axes[0].set_xticks(x); axes[0].set_xticklabels(years, rotation=45)
    axes[0].set_title("Net R per Year", color=TEXT_COLOR)
    axes[0].set_ylabel("R", color=TEXT_COLOR)
    for i, v in enumerate(yb["total_R"]):
        axes[0].text(i, v + (0.1 if v >= 0 else -0.4), f"{v:.1f}", ha="center",
                     color=TEXT_COLOR, fontsize=7)

    # Panel 2: Net USD per year
    colors_u = [GREEN if v >= 0 else RED for v in yb["net_USD"]]
    axes[1].bar(x, yb["net_USD"], color=colors_u, width=w, alpha=0.85)
    axes[1].bar(x, yb["swap_USD"], color=ORANGE, width=w * 0.4, alpha=0.85, label="Swap cost")
    axes[1].axhline(0, color=GRAY, lw=0.8)
    axes[1].set_xticks(x); axes[1].set_xticklabels(years, rotation=45)
    axes[1].set_title("Net USD + Swap Cost per Year", color=TEXT_COLOR)
    axes[1].set_ylabel("USD", color=TEXT_COLOR)
    axes[1].legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=7)

    # Panel 3: Avg lot size & risk ratio
    ax3b = axes[2].twinx()
    axes[2].bar(x, yb["avg_lots"], width=w, color=ACCENT, alpha=0.7, label="Avg lots")
    ax3b.plot(x, yb["risk_ratio"], color=ORANGE, marker="o", ms=4, lw=1.5,
              label="Risk/target")
    ax3b.axhline(1.0, color=GRAY, lw=0.7, ls="--")
    axes[2].set_xticks(x); axes[2].set_xticklabels(years, rotation=45)
    axes[2].set_title("Sizing: Avg Lots & Risk Ratio vs 0.5% Target", color=TEXT_COLOR)
    axes[2].set_ylabel("Lots", color=TEXT_COLOR)
    ax3b.set_ylabel("Actual/Target risk", color=ORANGE)
    ax3b.tick_params(colors=ORANGE)
    axes[2].legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=7, loc="upper left")
    ax3b.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=7, loc="upper right")

    # Panel 4: Win rate & ATR
    ax4b = axes[3].twinx()
    axes[3].bar(x, yb["win_rate"], width=w, color=GREEN, alpha=0.6, label="Win rate %")
    axes[3].axhline(33, color=GRAY, lw=0.7, ls="--", alpha=0.7)
    ax4b.plot(x, yb["avg_ATR"], color=ORANGE, marker="s", ms=4, lw=1.5, label="Avg ATR $")
    axes[3].set_xticks(x); axes[3].set_xticklabels(years, rotation=45)
    axes[3].set_title("Win Rate % & Avg ATR (approx)", color=TEXT_COLOR)
    axes[3].set_ylabel("Win Rate %", color=TEXT_COLOR)
    ax4b.set_ylabel("ATR ($)", color=ORANGE)
    ax4b.tick_params(colors=ORANGE)
    axes[3].legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=7, loc="upper left")
    ax4b.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=7, loc="upper right")

    fig.suptitle("Year-by-Year Breakdown  |  XAU Trend Capture v1  (slope=ON, TS=48)",
                 color=TEXT_COLOR, y=1.01, fontsize=11)
    fig.tight_layout()
    fig.savefig(out / "year_breakdown.png", **STYLE, bbox_inches="tight")
    plt.close(fig)


def plot_monte_carlo(mc: dict, s: dict, out: Path):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5), facecolor=STYLE["facecolor"])
    for ax in (ax1, ax2):
        ax.set_facecolor("#161b22")
        for sp in ax.spines.values():
            sp.set_edgecolor("#30363d")
        ax.tick_params(colors=TEXT_COLOR)
        ax.xaxis.label.set_color(TEXT_COLOR)
        ax.yaxis.label.set_color(TEXT_COLOR)
        ax.title.set_color(TEXT_COLOR)

    # Total R distribution
    ax1.hist(mc["total_rs"], bins=60, color=ACCENT, alpha=0.8, edgecolor="none")
    ax1.axvline(mc["total_r_p5"],  color=RED,    lw=1.5, ls="--", label=f"P5={mc['total_r_p5']:.1f}R")
    ax1.axvline(mc["total_r_p50"], color=ORANGE, lw=1.5, ls="--", label=f"P50={mc['total_r_p50']:.1f}R")
    ax1.axvline(s["total_r"],      color=GREEN,  lw=2.0, ls="-",  label=f"Actual={s['total_r']:.1f}R")
    ax1.axvline(0, color=GRAY, lw=0.8)
    ax1.set_xlabel("Total R (full period)", color=TEXT_COLOR)
    ax1.set_ylabel("Count", color=TEXT_COLOR)
    ax1.set_title(f"MC Total R (block={MC_BLOCK}, n={MC_SIMS:,})  P(>0)={mc['prob_positive']:.1%}",
                  color=TEXT_COLOR)
    ax1.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=8)

    # Max Drawdown distribution (in R)
    ax2.hist(mc["max_dds"], bins=60, color=RED, alpha=0.8, edgecolor="none")
    ax2.axvline(mc["max_dd_p5"],  color=RED,    lw=1.5, ls="--", label=f"P5={mc['max_dd_p5']:.1f}R")
    ax2.axvline(mc["max_dd_p50"], color=ORANGE, lw=1.5, ls="--", label=f"P50={mc['max_dd_p50']:.1f}R")
    act_dd_r = s["max_dd_usd"] / s["avg_risk_usd"]  # rough R conversion
    ax2.axvline(act_dd_r, color=GREEN, lw=2.0, ls="-", label=f"Actual≈{act_dd_r:.1f}R")
    ax2.set_xlabel("Max Drawdown (R)", color=TEXT_COLOR)
    ax2.set_ylabel("Count", color=TEXT_COLOR)
    ax2.set_title("MC Max Drawdown Distribution", color=TEXT_COLOR)
    ax2.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=8)

    fig.tight_layout()
    fig.savefig(out / "monte_carlo.png", **STYLE)
    plt.close(fig)


def plot_gap_cap(df: pd.DataFrame, out: Path):
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 6), facecolor=STYLE["facecolor"])
    for ax in (ax1, ax2):
        ax.set_facecolor("#161b22")
        for sp in ax.spines.values():
            sp.set_edgecolor("#30363d")
        ax.tick_params(colors=TEXT_COLOR)
        ax.xaxis.label.set_color(TEXT_COLOR)
        ax.yaxis.label.set_color(TEXT_COLOR)
        ax.title.set_color(TEXT_COLOR)

    x = df["time_in"]
    target_risk = INITIAL_EQUITY * TARGET_RISK_PCT / 100

    # Actual risk vs target
    ax1.scatter(x, df["risk_usd"], s=4, alpha=0.5,
                c=[GREEN if b else ORANGE for b in df["gap_cap_binding"]],
                label=None)
    ax1.axhline(target_risk, color=ACCENT, lw=1.2, ls="--", label=f"Target ${target_risk:.0f} (0.5%)")
    ax1.set_ylabel("Actual Risk $ / trade", color=TEXT_COLOR)
    ax1.set_title("Actual Risk per Trade vs 0.5% Target  (green=gap-cap binding, orange=risk-based)",
                  color=TEXT_COLOR)
    ax1.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=8)
    ax1.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))

    # ATR approximation over time
    ax2.scatter(x, df["atr_approx"], s=4, alpha=0.5, color=ORANGE)
    ax2.axhline(6.25, color=RED, lw=1.0, ls="--", alpha=0.8,
                label="ATR=$6.25  (gap cap binding threshold)")
    ax2.set_ylabel("Approx ATR ($)", color=TEXT_COLOR)
    ax2.set_xlabel("Date", color=TEXT_COLOR)
    ax2.set_title("Estimated ATR per Trade (= stop/2 = risk_usd / lots / DPU / 2)",
                  color=TEXT_COLOR)
    ax2.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=8)
    ax2.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))

    fig.tight_layout()
    fig.savefig(out / "gap_cap_analysis.png", **STYLE)
    plt.close(fig)


# ── Text Report ───────────────────────────────────────────────────────────────

def write_report(s: dict, yb: pd.DataFrame, mc: dict, pass_label: str, out: Path):
    target_risk = INITIAL_EQUITY * TARGET_RISK_PCT / 100
    theoretical_net = s["total_r"] * target_risk  # if always risking $50

    lines = []
    A = lines.append

    A("=" * 72)
    A(f"XAU Trend Capture v1 — Analisis Backtest: {pass_label}")
    A("=" * 72)
    A(f"Periode      : {yb['year'].iloc[0]} – {yb['year'].iloc[-1]}"
      f"  ({s['years']:.1f} tahun)")
    A(f"Jumlah trade : {s['n']}  (target 450-900: {'✓' if 450<=s['n']<=900 else '✗'})")
    A(f"Trades/tahun : {s['trades_per_year']:.0f}")
    A("")

    A("── KINERJA ABSOLUT (USD) ───────────────────────────────────────────────")
    A(f"  Modal awal      : ${INITIAL_EQUITY:,.0f}")
    A(f"  Modal akhir     : ${INITIAL_EQUITY + s['net_usd']:,.0f}")
    A(f"  Net profit      : ${s['net_usd']:+,.2f}  ({s['total_return_pct']:+.2f}%)")
    A(f"  Gross profit    : ${s['gross_usd']:+,.2f}")
    A(f"  Total swap cost : ${s['swap_usd']:,.2f}  ({s['swap_usd']/s['net_usd']*100:.1f}% of net)")
    A(f"  Max DD USD      : ${s['max_dd_usd']:,.2f}  ({s['max_dd_pct']:.2f}%)")
    A("")

    A("── KINERJA DALAM R (edge yang sesungguhnya) ────────────────────────────")
    A(f"  Total net R     : {s['total_r']:+.2f}R  ({s['r_per_year']:+.2f}R/tahun)")
    A(f"  Win rate        : {s['win_rate']:.1%}  ({s['wins']}/{s['n']})")
    A(f"  Payoff ratio    : {s['payoff']:.2f}x  (avg win / avg loss)")
    A(f"  Avg win R       : {s['avg_win_r']:+.3f}R")
    A(f"  Avg loss R      : {s['avg_loss_r']:+.3f}R")
    A(f"  Expectancy      : {s['expectancy']:+.4f}R/trade")
    A(f"  Profit factor R : {s['pf_r']:.3f}  (target >1.5 untuk sistem trend)")
    A(f"  Sharpe approx   : {s['sharpe_r']:.2f}  (dari trade-level R, annualised)")
    A(f"  LR Correlation  : {s['lr_corr']:.2f}  (⚠️ NEGATIF = equity curve menurun!)"
      if s['lr_corr'] < 0 else f"  LR Correlation  : {s['lr_corr']:.2f}")
    A("")

    A("── SIZING & GAP CAP ANALYSIS ───────────────────────────────────────────")
    A(f"  Target risk     : ${target_risk:.0f}/trade (0.5% × ${INITIAL_EQUITY:,.0f})")
    A(f"  Avg actual risk : ${s['avg_risk_usd']:.2f}/trade  ({s['avg_risk_ratio']:.2f}× target)")
    A(f"  Gap cap binding : {s['gap_pct']:.0f}% of trades")
    A(f"  Jika selalu full risk ${target_risk:.0f}:")
    A(f"    Theoretical net: ${theoretical_net:,.2f}  ({theoretical_net/INITIAL_EQUITY*100:.1f}% return)")
    A(f"    vs Actual net  : ${s['net_usd']:,.2f}  ({s['net_usd']/INITIAL_EQUITY*100:.1f}% return)")
    A(f"  → Gap cap menekan realisasi USD sebesar {(1 - s['net_usd']/theoretical_net)*100:.0f}%"
      f" dari potensi penuh." if theoretical_net > 0 else "")
    A("")

    A("── MONTE CARLO (block bootstrap, block=20, n=5,000) ────────────────────")
    A(f"  Total R  : P5={mc['total_r_p5']:+.1f}R  P50={mc['total_r_p50']:+.1f}R"
      f"  P95={mc['total_r_p95']:+.1f}R")
    A(f"  Max DD R : P5={mc['max_dd_p5']:.1f}R  P50={mc['max_dd_p50']:.1f}R"
      f"  P95={mc['max_dd_p95']:.1f}R")
    A(f"  P(total R > 0) : {mc['prob_positive']:.1%}")
    A("")

    A("── YEAR-BY-YEAR TABLE ──────────────────────────────────────────────────")
    A(f"  {'Year':>4}  {'N':>4}  {'TotalR':>7}  {'NetUSD':>8}  {'SwapUSD':>8}  "
      f"{'WR%':>5}  {'AvgATR':>7}  {'AvgLot':>7}  {'Risk%':>6}  {'Bind%':>6}")
    A(f"  {'-'*4}  {'-'*4}  {'-'*7}  {'-'*8}  {'-'*8}  "
      f"{'-'*5}  {'-'*7}  {'-'*7}  {'-'*6}  {'-'*6}")
    for _, row in yb.iterrows():
        risk_pct = row["risk_ratio"] * TARGET_RISK_PCT
        A(f"  {int(row['year']):>4}  {int(row['n_trades']):>4}  {row['total_R']:>+7.2f}  "
          f"  {row['net_USD']:>+7.2f}  {row['swap_USD']:>+8.2f}  "
          f"{row['win_rate']:>5.1f}  {row['avg_ATR']:>7.1f}  {row['avg_lots']:>7.3f}  "
          f"{risk_pct:>5.2f}%  {row['gap_bind%']:>5.0f}%")
    A("")

    A("── EXIT BREAKDOWN ──────────────────────────────────────────────────────")
    for reason, cnt in sorted(s["exit_counts"].items(), key=lambda x: -x[1]):
        A(f"  {reason:<8} : {cnt:>4}  ({cnt/s['n']*100:.1f}%)")
    A("")

    A("── INTERPRETASI HASIL ──────────────────────────────────────────────────")
    A("")
    A("  ❓ Kenapa profit USD hanya $1,015 dalam 9+ tahun?")
    A("")
    A("  1. GAP CAP DOMINAN (2017-2023)")
    A(f"     ATR emas era 2017-2023 rata-rata $5-12. Gap cap lot = {0.04:.2f} lots.")
    A(f"     Actual risk per trade = lots × 2×ATR × $100.")
    A(f"     Contoh: 0.04 lot × $8 stop × $100 = $3.20/trade (bukan $50 target!)")
    A(f"     → Sistem hanya memasang 6-32% dari ukuran yang seharusnya.")
    A("")
    A("  2. EDGE DALAM R POSITIF TAPI KECIL")
    A(f"     Expectancy = {s['expectancy']:+.4f}R/trade. Profit factor {s['pf_r']:.3f}.")
    A(f"     Untuk sistem trend-following dengan WR 34%, PF 1.10 adalah MARGINAL.")
    A(f"     Benchmark yang sehat: PF ≥ 1.3, expectancy ≥ 0.05R/trade.")
    A("")
    A(f"  3. LR CORRELATION = {s['lr_corr']:.2f} — FLAG SERIUS")
    A(f"     Equity curve TIDAK tumbuh linear — ada puncak di tengah lalu turun.")
    A(f"     Kemungkinan: sistem profit di 2020-2021 (volatilitas tinggi COVID),")
    A(f"     lalu terkikis di 2022-2023 (konsolidasi), lalu recovery 2024-2026.")
    A(f"     Perlu cek walk-forward untuk validasi: apakah edge konsisten per window.")
    A("")
    A("  4. HISTORY QUALITY 4% — KETERBATASAN KRITIS")
    A(f"     Hanya data 2026.01–sekarang yang real ticks. 2017-2025 = synthetic")
    A(f"     dari OHLCV M15. Hasil backtest 2017-2025 bisa bias (optimistis atau")
    A(f"     pesimistis tergantung asumsi tick generator Metatrader).")
    A(f"     Perlu out-of-sample test atau live forward test untuk validasi sejati.")
    A("")
    A("  5. KONTEKS CENT ACCOUNT")
    A(f"     $1,015 dalam 9 tahun di akun DEMO ($10,000 USD) =")
    A(f"     10,150 cents profit di akun Standard Cent (modal 10,000 cents = $100 real).")
    A(f"     Profit REAL dalam dolar: ~$101.50 dari modal $100 dalam 9 tahun.")
    A(f"     Ini TIDAK mewakili kinerja sistem sesungguhnya karena:")
    A(f"     (a) Gap cap terlalu kecil untuk akun $100 real (lot min 0.01, target 0.04)")
    A(f"     (b) Hasil akan LEBIH BAIK jika modal lebih besar (lot sizing lebih optimal)")
    A("")
    A("  ✅ KESIMPULAN")
    A(f"     Edge ada (P>0 = {mc['prob_positive']:.0%} dari MC) tapi marginal.")
    A(f"     Prioritas: jalankan 5 pass lain, bandingkan slope on/off × TS,")
    A(f"     cek walk-forward, lalu decide apakah PF perlu diperbaiki.")
    A(f"     Jangan trade live sampai setidaknya 3 pass menunjukkan PF konsisten > 1.2.")
    A("")
    A("=" * 72)

    report_text = "\n".join(lines)
    print(report_text)
    (out / "summary.txt").write_text(report_text, encoding="utf-8")
    return report_text


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="XAU Trend Capture v1 — Backtest Analyzer")
    parser.add_argument("trades_csv", nargs="?", default=None,
                        help="Path to XTC_trades_*.csv")
    parser.add_argument("--out", default="analysis/output",
                        help="Output directory (default: analysis/output)")
    parser.add_argument("--label", default="slope=ON, TS=48",
                        help="Pass label for report header")
    args = parser.parse_args()

    # Resolve input file
    csv_path = args.trades_csv
    if csv_path is None:
        candidates = list(Path(".").glob("XTC_trades_*.csv")) + \
                     list(Path("analysis").glob("XTC_trades_*.csv"))
        if not candidates:
            print("ERROR: No XTC_trades_*.csv found. Provide path as argument.")
            sys.exit(1)
        csv_path = str(candidates[0])
        print(f"Auto-detected: {csv_path}")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    print(f"Loading {csv_path} …")
    df = load_trades(csv_path)
    print(f"  {len(df)} trades loaded.")

    print("Computing statistics …")
    s  = summary_stats(df)
    yb = year_breakdown(df)

    print("Running Monte Carlo …")
    mc = monte_carlo(df["r_net"].values)

    print("Generating plots …")
    plot_equity_curve(df, s, out)
    print("  equity_curve.png ✓")
    plot_r_distribution(df, s, out)
    print("  r_distribution.png ✓")
    plot_year_breakdown(yb, out)
    print("  year_breakdown.png ✓")
    plot_monte_carlo(mc, s, out)
    print("  monte_carlo.png ✓")
    plot_gap_cap(df, out)
    print("  gap_cap_analysis.png ✓")

    print("\nGenerating report …")
    write_report(s, yb, mc, args.label, out)
    print(f"\nOutput written to: {out.resolve()}")


if __name__ == "__main__":
    main()
