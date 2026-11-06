#!/usr/bin/env python3
"""Last production Terraform apply, as audit evidence (AXI-2416, Hosting-Assurance-Pack FR1).

Reads the GitHub Actions log of the latest successful terraform-cd run whose production
job applied, and prints a JSON extract: run id and URL, commit, completion time, the
"Apply complete!" summary and the resource changes. Never the raw log.

Usage: last_deployment.py [--repo owner/name] [--workflow terraform-cd.yml] > deployment.json
Needs: an authenticated `gh` CLI.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Callable

Gh = Callable[[list[str]], str]
_TS = re.compile(r"^\S+Z ")
_ANSI = re.compile(r"\x1b\[[0-9;]*m")
_CHANGE = re.compile(r"^\s*# (\S+) (will be|must be) (.+)$")
_SUMMARY = re.compile(r"Apply complete! Resources: .*\.")


def gh_cli(args: list[str]) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def clean(log: str) -> list[str]:
    return [_ANSI.sub("", _TS.sub("", line)) for line in log.splitlines()]


def parse_apply(log: str) -> dict | None:
    lines = clean(log)
    summary = next((m.group(0) for line in lines if (m := _SUMMARY.search(line))), None)
    if summary is None:
        return None
    changes = [f"{m.group(1)}: {m.group(3)}" for line in lines if (m := _CHANGE.match(line))]
    return {"apply_summary": summary, "changes": list(dict.fromkeys(changes))}


def production_job(gh: Gh, repo: str, run_id: int) -> dict | None:
    jobs = json.loads(gh(["api", f"repos/{repo}/actions/runs/{run_id}/jobs"]))["jobs"]
    return next((j for j in jobs if j["name"].startswith("Production")
                 and j["conclusion"] == "success"), None)


def evidence(gh: Gh, repo: str, run: dict, job: dict) -> dict | None:
    applied = parse_apply(gh(["api", f"repos/{repo}/actions/jobs/{job['id']}/logs"]))
    if applied is None:
        return None
    return {"repo": repo, "run_id": run["id"], "run_url": run["html_url"],
            "head_sha": run["head_sha"], "completed_at": job["completed_at"], **applied}


def last_apply(gh: Gh, repo: str, workflow: str) -> dict:
    path = f"repos/{repo}/actions/workflows/{workflow}/runs?branch=main&status=success&per_page=20"
    for run in json.loads(gh(["api", path]))["workflow_runs"]:
        job = production_job(gh, repo, run["id"])
        found = evidence(gh, repo, run, job) if job else None
        if found:
            return found
    raise LookupError(f"no successful production apply in the last 20 {workflow} runs")


def main(argv: list[str] | None = None, gh: Gh = gh_cli) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--repo", default="fmguimaraes/axiome-infra")
    p.add_argument("--workflow", default="terraform-cd.yml")
    args = p.parse_args(sys.argv[1:] if argv is None else argv)
    print(json.dumps(last_apply(gh, args.repo, args.workflow), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
