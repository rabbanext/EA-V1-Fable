#!/usr/bin/env python3
"""
XAU Trend Capture v1 — Multi-Pass Comparison (Langkah 4)
Membandingkan 6 kombinasi: slope {ON,OFF} × time_stop {NONE, 48, 96}.

Usage:
    python compare_passes.py \
        XTC_trades_XAUUSDm_slope1_ts48.csv:slope=ON,TS=48 \
        XTC_trades_XAUUSDm_slope1_ts96.csv:slope=ON,TS=96 \
        XTC_trades_XAUUSDm_slope1_ts0.csv:slope=ON,TS=NONE \
        XTC_trades_XAUUSDm_slope0_ts48.csv:slope=OFF,TS=48 \
        XTC_trades_XAUUSDm_slope0_ts96.csv:slope=OFF,TS=96 \
        XTC_trades_XAUUSDm_slope0_ts0.csv:slope=OFF,TS=NONE \
        --out analysis/output

    Each arg is path:label (colon separator).
    Any subset of the 6 passes can be provided.
"""

import argparse
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np
import pandas as pd
import warnings
warnings.filterwarnings("ignore")

INITIAL_EQUITY  = 10_000.0
TARGET_RISK_PCT = 0.5
DPU             = 100.0
VOL_STEP        = 0.01
GAP_CAP_USD     = 50.0
GAP_PCT         = 2.0

TEXT_COLOR = "#c9d1d9"
ACCENT     = "#58a6ff"
GREEN      = "#3fb950"
RED        = "#f85149"
ORANGE     = "#d29922"
GRAY       = "#8b949e"
PALETTE    = [ACCENT, GREEN, ORANGE, RED, "#bc8cff", "#ff7b72"]

STYLE = dict(dpi=130, facecolor="#0d1117")


def load(path: str) -> pd.DataFrame:
    df = pd.read_csv(path, sep=";", parse_dates=["time_in", "time_out"])
    df = df.sort_values("time_in").reset_index(drop=True)
    df["year"]    = df["time_in"].dt.year
    df["cum_net"] = df["net"].cumsum()
    df["equity"]  = INITIAL_EQUITY + df["cum_net"]
    df["peak"]    = df["equity"].cummax()
    df["dd_pct"]  = (df["equity"] - df["peak"]) / df["peak"] * 100
    df["cum_r"]   = df["r_net"].cumsum()
    target_risk   = INITIAL_EQUITY * TARGET_RISK_PCT / 100
    df["risk_ratio"] = df["risk_usd"] / target_risk
    df["win"]     = df["r_net"] > 0
    df["gap_cap_binding"] = df["lots"] >= (GAP_PCT / 100 * INITIAL_EQUITY) / (GAP_CAP_USD * DPU) - 1e-4
    return df


def metrics(df: pd.DataFrame, label: str) -> dict:
    n       = len(df)
    r       = df["r_net"]
    wins    = df["win"].sum()
    wr      = wins / n
    avg_win = r[r > 0].mean() if wins > 0 else 0.0
    avg_los = r[r <= 0].mean() if (n - wins) > 0 else 0.0
    exp     = wr * avg_win + (1 - wr) * avg_los
    pf_r    = r[r > 0].sum() / abs(r[r <= 0].sum()) if r[r <= 0].sum() != 0 else np.inf
    years   = (df["time_in"].iloc[-1] - df["time_in"].iloc[0]).days / 365.25
    total_r = r.sum()
    sharpe  = (exp / r.std()) * np.sqrt(n / years) if r.std() > 0 and years > 0 else 0.0
    max_dd  = df["dd_pct"].min()
    swap_r  = df["r_swap"].sum()
    net_usd = df["net"].sum()
    swap_usd = df["swap"].sum()
    return dict(
        label=label, n=n, wr=wr, payoff=avg_win / abs(avg_los) if avg_los else np.inf,
        exp=exp, pf_r=pf_r, total_r=total_r, r_per_yr=total_r / years,
        sharpe=sharpe, max_dd=max_dd, swap_r=swap_r,
        net_usd=net_usd, swap_usd=swap_usd,
        avg_risk_ratio=df["risk_ratio"].mean(),
        gap_bind_pct=df["gap_cap_binding"].mean() * 100,
        years=years,
    )


def plot_equity_curves(dfs, labels, colors, out: Path):
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 7), facecolor=STYLE["facecolor"],
                                    gridspec_kw={"height_ratios": [3, 1]})
    for ax in (ax1, ax2):
        ax.set_facecolor("#161b22")
        for sp in ax.spines.values(): sp.set_edgecolor("#30363d")
        ax.tick_params(colors=TEXT_COLOR)

    for df, lbl, col in zip(dfs, labels, colors):
        ax1.plot(df["time_in"], df["equity"], color=col, lw=1.2, label=lbl)
        ax2.plot(df["time_in"], df["dd_pct"], color=col, lw=0.8, alpha=0.7)

    ax1.axhline(INITIAL_EQUITY, color=GRAY, lw=0.7, ls="--")
    ax1.set_ylabel("Equity (USD)", color=TEXT_COLOR)
    ax1.set_title("Equity Curves — Semua 6 Kombinasi", color=TEXT_COLOR)
    ax1.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=8)
    ax1.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f"${v:,.0f}"))

    ax2.axhline(0, color=GRAY, lw=0.7)
    ax2.set_ylabel("DD %", color=TEXT_COLOR)
    ax2.set_xlabel("Date", color=TEXT_COLOR)

    fig.tight_layout()
    fig.savefig(out / "compare_equity.png", **STYLE)
    plt.close(fig)


def plot_r_curves(dfs, labels, colors, out: Path):
    fig, ax = plt.subplots(figsize=(12, 5), facecolor=STYLE["facecolor"])
    ax.set_facecolor("#161b22")
    for sp in ax.spines.values(): sp.set_edgecolor("#30363d")
    ax.tick_params(colors=TEXT_COLOR)

    for df, lbl, col in zip(dfs, labels, colors):
        ax.plot(df["time_in"], df["cum_r"], color=col, lw=1.2, label=lbl)
    ax.axhline(0, color=GRAY, lw=0.8)
    ax.set_ylabel("Cumulative R", color=TEXT_COLOR)
    ax.set_xlabel("Date", color=TEXT_COLOR)
    ax.set_title("Cumulative R — Semua 6 Kombinasi", color=TEXT_COLOR)
    ax.legend(facecolor="#21262d", labelcolor=TEXT_COLOR, fontsize=8)

    fig.tight_layout()
    fig.savefig(out / "compare_cumR.png", **STYLE)
    plt.close(fig)


def plot_bar_comparison(mets: list, out: Path):
    labels  = [m["label"] for m in mets]
    n       = len(mets)
    x       = np.arange(n)

    fig, axes = plt.subplots(2, 3, figsize=(14, 8), facecolor=STYLE["facecolor"])
    axes = axes.flatten()
    for ax in axes:
        ax.set_facecolor("#161b22")
        for sp in ax.spines.values(): sp.set_edgecolor("#30363d")
        ax.tick_params(colors=TEXT_COLOR, labelsize=7)

    def bar(ax, vals, title, fmt=".2f", ref=None):
        colors = [GREEN if v >= 0 else RED for v in vals]
        ax.bar(x, vals, color=colors, alpha=0.85, width=0.6)
        if ref is not None:
            ax.axhline(ref, color=ORANGE, lw=1.0, ls="--", alpha=0.8)
        ax.set_xticks(x); ax.set_xticklabels(labels, rotation=30, ha="right", fontsize=7)
        ax.set_title(title, color=TEXT_COLOR, fontsize=9)
        ax.axhline(0, color=GRAY, lw=0.7)
        for i, v in enumerate(vals):
            ax.text(i, v + (max(vals) * 0.02 if v >= 0 else min(vals) * 0.02),
                    f"{v:{fmt}}", ha="center", color=TEXT_COLOR, fontsize=7)

    bar(axes[0], [m["total_r"] for m in mets], "Total R (9yr)", ".1f")
    bar(axes[1], [m["r_per_yr"] for m in mets], "R per Year", ".2f")
    bar(axes[2], [m["pf_r"] for m in mets], "Profit Factor (R)", ".3f", ref=1.0)
    bar(axes[3], [m["exp"] * 100 for m in mets], "Expectancy (×100 R)", ".3f")
    bar(axes[4], [m["max_dd"] for m in mets], "Max Drawdown %", ".1f")
    bar(axes[5], [m["swap_usd"] for m in mets], "Total Swap Cost ($)", ".0f")

    fig.suptitle("Comparison: slope×TS kombinasi", color=TEXT_COLOR, y=1.01, fontsize=11)
    fig.tight_layout()
    fig.savefig(out / "compare_bars.png", **STYLE, bbox_inches="tight")
    plt.close(fig)


def print_table(mets: list):
    hdr = (f"{'Pass':<20} {'N':>4} {'TotalR':>8} {'R/yr':>7} {'PF-R':>6} "
           f"{'Exp':>8} {'WR%':>5} {'Payoff':>7} {'MaxDD%':>7} "
           f"{'Sharpe':>7} {'SwapUSD':>9}")
    sep = "-" * len(hdr)
    print("\n" + "=" * len(hdr))
    print("XAU Trend Capture v1 — Comparison Table")
    print("=" * len(hdr))
    print(hdr)
    print(sep)
    for m in mets:
        print(f"{m['label']:<20} {m['n']:>4} {m['total_r']:>+8.2f} {m['r_per_yr']:>+7.2f} "
              f"{m['pf_r']:>6.3f} {m['exp']:>+8.4f} {m['wr']*100:>5.1f} {m['payoff']:>7.2f} "
              f"{m['max_dd']:>7.2f} {m['sharpe']:>7.2f} {m['swap_usd']:>+9.2f}")
    print(sep)
    # Best by total R
    best_r = max(mets, key=lambda m: m["total_r"])
    best_dd = max(mets, key=lambda m: -m["max_dd"])
    print(f"\nBest total R  : {best_r['label']}  ({best_r['total_r']:+.2f}R)")
    print(f"Best max DD   : {best_dd['label']}  ({best_dd['max_dd']:.2f}%)")
    print("=" * len(hdr))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("passes", nargs="+",
                        help="path:label pairs, e.g. trades.csv:slope=ON,TS=48")
    parser.add_argument("--out", default="analysis/output")
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    dfs, labels, mets = [], [], []
    colors = PALETTE[:len(args.passes)]

    for i, spec in enumerate(args.passes):
        if ":" in spec:
            path, label = spec.split(":", 1)
        else:
            path, label = spec, Path(spec).stem
        print(f"Loading {path} → '{label}' …")
        try:
            df = load(path)
            m  = metrics(df, label)
            dfs.append(df); labels.append(label); mets.append(m)
            print(f"  {len(df)} trades, {m['total_r']:+.2f}R total")
        except Exception as e:
            print(f"  ERROR loading {path}: {e}")

    if not dfs:
        print("No valid files loaded. Exiting.")
        sys.exit(1)

    print_table(mets)

    print("\nGenerating plots …")
    if len(dfs) > 1:
        plot_equity_curves(dfs, labels, colors, out)
        print("  compare_equity.png ✓")
        plot_r_curves(dfs, labels, colors, out)
        print("  compare_cumR.png ✓")
    if len(dfs) >= 2:
        plot_bar_comparison(mets, out)
        print("  compare_bars.png ✓")
    else:
        print("  (need ≥2 passes for bar comparison)")

    print(f"\nOutput: {out.resolve()}")


if __name__ == "__main__":
    main()
