#!/usr/bin/env python3
"""Track what boxd costs, sample by sample.

Every run of `sample` stores one line in ~/.kanban-code/boxd-spend/samples.jsonl:
the credit balance of the org from `boxd manage billing --json` and, for every
machine of the org, its status and the cost the rate card gives it since the
last sample. Machines owned by the account of this Mac get their memory and
disk use read while they run (`boxd machine exec` is never sent to a paused
machine: it would wake it up). The last known use stands in while a machine is
in standby, which is what boxd bills for memory then.

`report` prints the spend per machine, per Kanban card, per day, and the
projection of a month at the average of the period.

`install` writes a LaunchAgent that runs `sample` every 5 minutes.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()
DATA_DIR = Path(os.environ.get("BOXD_SPEND_DIR", HOME / ".kanban-code" / "boxd-spend"))
SAMPLES = DATA_DIR / "samples.jsonl"
STATE = DATA_DIR / "state.json"
LINKS = HOME / ".kanban-code" / "links.json"
LAUNCH_AGENT_LABEL = "ai.langwatch.boxd-spend"
LAUNCH_AGENT = HOME / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"

# Rate card, EUR per hour. https://boxd.sh/pricing
RATE_VCPU_HOUR = 0.049  # while the machine runs
RATE_RAM_GIB_HOUR = 0.015  # memory in use, running or in standby
RATE_DISK_GIB_HOUR = 0.0001  # disk in use, every state

# The org default size. `boxd machine get` does not report the size of a
# machine, so this stands in until a sample of `nproc` and `free` on a
# running machine says otherwise.
DEFAULT_VCPU = 4
# Memory in use assumed for a machine that was never probed (a machine of
# another member, or one that was never seen running).
ASSUMED_MEMORY_USED_GIB = 6.0

RUNNING = {"running", "booting"}
STANDBY = {"standby", "suspended", "pausing"}
COLD = {"stopped", "hibernated", "stopping", "hibernating"}


def boxd_path() -> str:
    for candidate in (HOME / ".local" / "bin" / "boxd", Path("/opt/homebrew/bin/boxd"), Path("/usr/local/bin/boxd")):
        if candidate.exists():
            return str(candidate)
    return "boxd"


def run_json(args: list[str], timeout: int = 60):
    result = subprocess.run([boxd_path(), *args, "--json"], capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(f"boxd {' '.join(args)} failed: {result.stderr.strip()}")
    # The CLI appends an update notice to stdout on some versions.
    text = result.stdout.strip()
    start = min(i for i in (text.find("{"), text.find("[")) if i >= 0)
    end = max(text.rfind("}"), text.rfind("]"))
    return json.loads(text[start : end + 1])


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(STATE)


def machine_cards() -> dict[str, str]:
    """Machine name to a short label of the Kanban card that uses it."""
    try:
        data = json.loads(LINKS.read_text())
    except (OSError, ValueError):
        return {}
    links = data.get("links", data) if isinstance(data, dict) else data
    entries = links.values() if isinstance(links, dict) else links
    out: dict[str, str] = {}
    for link in entries:
        remote = link.get("remote") if isinstance(link, dict) else None
        if not remote or not remote.get("machineName"):
            continue
        title = (link.get("sessionLink") or {}).get("title") or (link.get("promptBody") or "").strip().splitlines()[:1]
        if isinstance(title, list):
            title = title[0] if title else ""
        label = f"{link.get('id', '?')} {title}".strip()
        out[remote["machineName"]] = label[:70]
    return out


def probe_usage(name: str) -> dict | None:
    """vCPU count, memory in use and disk in use of a running machine."""
    command = "nproc; free -b | awk '/Mem:/{print $3}'; df -B1 --output=used / | tail -1"
    try:
        result = subprocess.run(
            [boxd_path(), "machine", "exec", "--timeout", "20", name, "--", "sh", "-c", command],
            capture_output=True,
            text=True,
            timeout=40,
        )
    except subprocess.TimeoutExpired:
        return None
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip().isdigit()]
    if len(lines) < 3:
        return None
    return {
        "vcpu": int(lines[0]),
        "memory_used_gib": int(lines[1]) / 2**30,
        "disk_used_gib": int(lines[2]) / 2**30,
    }


def hourly_rate(status: str, vcpu: int, memory_used_gib: float, disk_used_gib: float) -> float:
    rate = RATE_DISK_GIB_HOUR * disk_used_gib
    if status in RUNNING:
        rate += RATE_VCPU_HOUR * vcpu + RATE_RAM_GIB_HOUR * memory_used_gib
    elif status in STANDBY:
        rate += RATE_RAM_GIB_HOUR * memory_used_gib
    return rate


def sample(args: argparse.Namespace) -> None:
    now = time.time()
    state = load_state()
    billing = run_json(["manage", "billing"])
    my_names = {m["name"] for m in run_json(["machine", "list"])}
    cards = machine_cards()
    last_time = state.get("last_sample_at")
    hours = (now - last_time) / 3600 if last_time else 0.0
    # A gap longer than an hour (the Mac slept, the agent was off) is not
    # charged to the machines: the org balance still carries the truth.
    if hours > 1:
        hours = 0.0

    usage = state.setdefault("usage", {})
    machines = []
    estimate_total = 0.0
    estimate_mine = 0.0
    for vm in billing.get("vms", []):
        name = vm["name"]
        status = vm.get("status", "unknown")
        mine = name in my_names
        known = usage.get(name, {})
        if mine and status in RUNNING and not args.no_probe:
            probed = probe_usage(name)
            if probed:
                known.update(probed)
                known["probed_at"] = now
        if status in COLD:
            # Memory is released; disk stays.
            memory_used = 0.0
        else:
            memory_used = known.get("memory_used_gib", ASSUMED_MEMORY_USED_GIB)
        vcpu = known.get("vcpu", DEFAULT_VCPU)
        disk_used = known.get("disk_used_gib", 0.0)
        rate = hourly_rate(status, vcpu, memory_used, disk_used)
        cost = rate * hours
        usage[name] = known
        estimate_total += cost
        if mine:
            estimate_mine += cost
        machines.append(
            {
                "name": name,
                "status": status,
                "mine": mine,
                "owner": vm.get("owner_name"),
                "card": cards.get(name),
                "vcpu": vcpu,
                "memory_used_gib": round(memory_used, 2),
                "disk_used_gib": round(disk_used, 2),
                "rate_eur_hour": round(rate, 5),
                "cost_eur": round(cost, 6),
                "estimated_size": "vcpu" not in known,
            }
        )

    balance = billing.get("balance_micro_eur", 0) / 1e6
    accruing = billing.get("accruing_micro_eur", 0) / 1e6
    charged = None
    if "balance_eur" in state:
        # Spend since the last sample as boxd counts it: what left the
        # balance plus what accrued and is not yet taken from it. An accrual
        # that settles moves from one to the other and adds nothing.
        charged = round((state["balance_eur"] - balance) + (accruing - state["accruing_eur"]), 6)

    line = {
        "at": datetime.fromtimestamp(now, tz=timezone.utc).isoformat(timespec="seconds"),
        "hours": round(hours, 5),
        "balance_eur": round(balance, 6),
        "accruing_eur": round(accruing, 6),
        "org_charged_eur": charged,
        "estimate_total_eur": round(estimate_total, 6),
        "estimate_mine_eur": round(estimate_mine, 6),
        "machines": machines,
    }
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with SAMPLES.open("a") as handle:
        handle.write(json.dumps(line) + "\n")

    state.update({"last_sample_at": now, "balance_eur": balance, "accruing_eur": accruing})
    save_state(state)
    if not args.quiet:
        print(
            f"{line['at']} balance €{balance:.2f} accruing €{accruing:.4f}"
            f" charged {('€%.4f' % charged) if charged is not None else '-'}"
            f" estimate mine €{estimate_mine:.4f} / org €{estimate_total:.4f}"
        )


def read_samples(since: datetime | None):
    if not SAMPLES.exists():
        return []
    out = []
    with SAMPLES.open() as handle:
        for raw in handle:
            try:
                line = json.loads(raw)
            except ValueError:
                continue
            at = datetime.fromisoformat(line["at"])
            if since and at < since:
                continue
            line["_at"] = at
            out.append(line)
    return out


def report(args: argparse.Namespace) -> None:
    since = datetime.now(timezone.utc) - timedelta(days=args.days) if args.days else None
    samples = read_samples(since)
    if not samples:
        print("No samples yet. Run `boxd-spend.py sample` or `install`.")
        return
    first, last = samples[0]["_at"], samples[-1]["_at"]
    span_hours = max((last - first).total_seconds() / 3600, 1e-9)
    span_days = span_hours / 24

    org_charged = sum(s["org_charged_eur"] or 0 for s in samples)
    est_total = sum(s["estimate_total_eur"] for s in samples)
    est_mine = sum(s["estimate_mine_eur"] for s in samples)

    per_machine: dict[str, dict] = defaultdict(lambda: {"cost": 0.0, "hours": defaultdict(float), "card": None, "mine": False, "owner": None, "last": None})
    per_day: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for s in samples:
        day = s["_at"].astimezone().strftime("%Y-%m-%d")
        per_day[day]["org_charged"] += s["org_charged_eur"] or 0
        per_day[day]["estimate_mine"] += s["estimate_mine_eur"]
        per_day[day]["estimate_total"] += s["estimate_total_eur"]
        for m in s["machines"]:
            entry = per_machine[m["name"]]
            entry["cost"] += m["cost_eur"]
            bucket = "running" if m["status"] in RUNNING else "standby" if m["status"] in STANDBY else "cold"
            entry["hours"][bucket] += s["hours"]
            entry["card"] = m.get("card") or entry["card"]
            entry["mine"] = m["mine"]
            entry["owner"] = m.get("owner")
            entry["last"] = m

    print(f"boxd spend {first.astimezone():%Y-%m-%d %H:%M} to {last.astimezone():%Y-%m-%d %H:%M} ({span_hours:.1f} h, {len(samples)} samples)")
    print(f"  Credits left:                  €{samples[-1]['balance_eur']:.2f} (accruing €{samples[-1]['accruing_eur']:.4f})")
    print(f"  Org charged (boxd balance):    €{org_charged:.4f}")
    print(f"  Estimate from the rate card:   €{est_total:.4f} org, €{est_mine:.4f} my machines")
    if span_hours >= 1:
        print(f"  Per day:                       €{org_charged / span_days:.2f} org, €{est_mine / span_days:.2f} my machines")
        print(f"  A month at this pace:          €{org_charged / span_days * 30:.2f} org, €{est_mine / span_days * 30:.2f} my machines")
    else:
        print("  Per day and per month:         after an hour of samples")
    print()
    print("  My machines")
    rows = sorted((n, e) for n, e in per_machine.items() if e["mine"])
    for name, e in sorted(rows, key=lambda r: -r[1]["cost"]):
        m = e["last"]
        h = e["hours"]
        size = f"{m['vcpu']} vCPU · {m['memory_used_gib']:.1f} GiB used · {m['disk_used_gib']:.0f} GB disk"
        if m.get("estimated_size"):
            size += " (assumed)"
        print(f"    {name:32} €{e['cost']:8.4f}  {m['status']:9}  run {h['running']:.1f}h  standby {h['standby']:.1f}h  cold {h['cold']:.1f}h  {size}")
        if e["card"]:
            print(f"    {'':32} card: {e['card']}")
    others = [(n, e) for n, e in per_machine.items() if not e["mine"]]
    if others:
        by_owner: dict[str, float] = defaultdict(float)
        for _, e in others:
            by_owner[e["owner"] or "?"] += e["cost"]
        print()
        print("  Other members (estimate)")
        for owner, cost in sorted(by_owner.items(), key=lambda r: -r[1]):
            print(f"    {owner:32} €{cost:8.4f}  {sum(1 for _, e in others if (e['owner'] or '?') == owner)} machines")
    print()
    print("  Per day                          org charged   estimate mine   estimate org")
    for day in sorted(per_day):
        d = per_day[day]
        print(f"    {day:28}  €{d['org_charged']:9.4f}   €{d['estimate_mine']:9.4f}     €{d['estimate_total']:9.4f}")


def install(args: argparse.Namespace) -> None:
    script = Path(__file__).resolve()
    python = sys.executable
    log = DATA_DIR / "agent.log"
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    plist = {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": [python, str(script), "sample", "--quiet"],
        "StartInterval": args.interval,
        "RunAtLoad": True,
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
        "EnvironmentVariables": {"PATH": f"{HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"},
    }
    LAUNCH_AGENT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LAUNCH_AGENT_LABEL}"], capture_output=True)
    with LAUNCH_AGENT.open("wb") as handle:
        plistlib.dump(plist, handle)
    subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(LAUNCH_AGENT)], check=True)
    print(f"Installed {LAUNCH_AGENT_LABEL}: `sample` every {args.interval}s, log at {log}")


def uninstall(args: argparse.Namespace) -> None:
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LAUNCH_AGENT_LABEL}"], capture_output=True)
    if LAUNCH_AGENT.exists():
        LAUNCH_AGENT.unlink()
    print(f"Removed {LAUNCH_AGENT_LABEL}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("sample", help="record one sample")
    s.add_argument("--quiet", action="store_true")
    s.add_argument("--no-probe", action="store_true", help="do not read memory and disk use from running machines")
    s.set_defaults(func=sample)
    r = sub.add_parser("report", help="print the spend")
    r.add_argument("--days", type=float, default=None, help="only the last N days")
    r.set_defaults(func=report)
    i = sub.add_parser("install", help="install the LaunchAgent")
    i.add_argument("--interval", type=int, default=300)
    i.set_defaults(func=install)
    u = sub.add_parser("uninstall", help="remove the LaunchAgent")
    u.set_defaults(func=uninstall)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
