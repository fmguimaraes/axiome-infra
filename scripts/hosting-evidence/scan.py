#!/usr/bin/env python3
"""Hosting evidence generator (AXI-2416, Feature Hosting-Assurance-Pack FR1).

Reads the production Terraform of a provider (static: no cloud credentials, no
state) and emits a bilingual (FR/EN) evidence report on data residency and the
security controls the hosting assurance pack relies on.

Every check is read from code, never asserted by hand. A failing residency check
exits 2 so a pipeline can gate on it. No variable value that could be a secret is
ever printed: only booleans, region codes and resource attributes on the allowlist.

Usage:
  scripts/hosting-evidence/scan.py [--provider-root providers/aws]
      [--environment production] [--out-dir ../axiome-docs/reports/hosting]
      [--json-only]
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

EEA_AWS_REGIONS = {
    "eu-west-3": "France (Paris)",
    "eu-central-1": "Germany (Frankfurt)",
    "eu-west-1": "Ireland",
    "eu-south-1": "Italy (Milan)",
    "eu-north-1": "Sweden (Stockholm)",
    "eu-south-2": "Spain",
}
FRANCE_REGIONS = {"eu-west-3"}

_TFVAR_RE = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*("([^"]*)"|true|false|[0-9.]+)', re.M)
_SECRETISH = re.compile(r"(key|secret|password|token|credential)", re.I)


@dataclass
class Check:
    """One evidence line: what was checked, where, and the outcome."""

    id: str
    title_en: str
    title_fr: str
    passed: bool
    evidence: str
    blocking: bool = False


@dataclass
class Report:
    environment: str
    provider_root: str
    generated_at: str
    region: str
    region_label: str
    checks: list[Check] = field(default_factory=list)

    @property
    def residency_ok(self) -> bool:
        return all(c.passed for c in self.checks if c.blocking)


def parse_tfvars(text: str) -> dict[str, str]:
    """Top-level scalar assignments of a .tfvars file, secret-looking names dropped."""
    values: dict[str, str] = {}
    for name, raw, quoted in _TFVAR_RE.findall(text):
        if _SECRETISH.search(name):
            continue
        values[name] = quoted if raw.startswith('"') else raw
    return values


def variable_default(variables_tf: str, name: str) -> str | None:
    """The literal `default` of `variable "<name>"` in a variables.tf, if any."""
    block = re.search(r'variable\s+"%s"\s*\{(.*?)\n\}' % re.escape(name), variables_tf, re.S)
    if not block:
        return None
    default = re.search(r'^\s*default\s*=\s*"?([^"\n]*)"?', block.group(1), re.M)
    return default.group(1).strip() if default else None


def resolve(name: str, tfvars: dict[str, str], variables_tf: str) -> str | None:
    """tfvars value, else the variable's declared default."""
    return tfvars.get(name, variable_default(variables_tf, name))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def strip_comments(text: str) -> str:
    """Drop full-line HCL comments so a commented-out control never counts."""
    return "\n".join(l for l in text.splitlines() if not re.match(r"\s*(#|//)", l))


def _blocks(text: str, header: str) -> list[str]:
    """Bodies of every top-level block whose opening line matches `header`."""
    bodies = []
    for m in re.finditer(header + r"\s*\{", text):
        depth, i = 1, m.end()
        while depth and i < len(text):
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        bodies.append(text[m.end():i - 1])
    return bodies


def resources(text: str, rtype: str) -> list[str]:
    return _blocks(strip_comments(text), r'resource\s+"%s"\s+"[^"]+"' % re.escape(rtype))


def module_body(text: str, name: str) -> str:
    found = _blocks(strip_comments(text), r'module\s+"%s"' % re.escape(name))
    return found[0] if found else ""


def every(blocks: list[str], *patterns: str) -> bool:
    """True only if there is at least one block and every block matches every pattern."""
    return bool(blocks) and all(re.search(p, b, re.M) for b in blocks for p in patterns)


def check_region(region: str) -> Check:
    in_fr = region in FRANCE_REGIONS
    label = EEA_AWS_REGIONS.get(region, "outside EEA / hors EEE")
    return Check("RES-01", "Primary region is in France", "Région principale en France",
                 in_fr, f"aws_region = {region} ({label})", blocking=True)


def check_off_region_module(cid: str, flag: str, value: str | None, what: str) -> Check:
    """A module that would place a component outside France must be switched off."""
    off = (value or "false").lower() == "false"
    return Check(cid, f"{what} not deployed (stays in France)",
                 f"{what} non déployé (reste en France)", off,
                 f"{flag} = {value or 'false (default)'}", blocking=True)


def check_rds(mod: str, retention: str | None) -> list[Check]:
    dbs, days = resources(mod, "aws_db_instance"), int(float(retention or 0))
    return [
        Check("SEC-01", "Database encrypted at rest (KMS CMK)",
              "Base de données chiffrée au repos (clé KMS dédiée)",
              every(dbs, r"storage_encrypted\s*=\s*true", r"kms_key_id\s*="),
              f"{len(dbs)} aws_db_instance: storage_encrypted = true, kms_key_id"),
        Check("SEC-02", "Database deletion protection in production",
              "Protection contre la suppression de la base en production",
              every(dbs, r'deletion_protection\s*=\s*(true|var\.environment\s*==\s*"production")'),
              f"{len(dbs)} aws_db_instance: deletion_protection"),
        Check("SEC-03", "Automated database backups enabled",
              "Sauvegardes automatiques de la base activées",
              days > 0 and every(dbs, r"backup_retention_period\s*="),
              f"rds_backup_retention_days = {days}"),
    ]


def check_storage(mod: str, root_main: str) -> list[Check]:
    sse = resources(mod, "aws_s3_bucket_server_side_encryption_configuration")
    pab = resources(mod, "aws_s3_bucket_public_access_block")
    buckets = resources(mod, "aws_s3_bucket")
    wired = re.search(r"kms_key_arn\s*=\s*module\.kms\.key_arn", module_body(root_main, "storage"))
    return [
        Check("SEC-04", "Object storage encrypted at rest (SSE-KMS)",
              "Stockage objet chiffré au repos (SSE-KMS)",
              every(sse, r'"aws:kms"') and len(sse) == len(buckets) and wired is not None,
              f"{len(sse)}/{len(buckets)} buckets SSE aws:kms; storage.kms_key_arn = module.kms.key_arn"),
        Check("SEC-05", "Object storage public access blocked",
              "Accès public au stockage objet bloqué",
              every(pab, r"block_public_acls\s*=\s*true", r"block_public_policy\s*=\s*true")
              and len(pab) == len(buckets),
              f"{len(pab)}/{len(buckets)} buckets: block_public_acls/policy = true"),
    ]


def check_compute(mod: str, kms: str, kms_vars: str) -> list[Check]:
    vms = resources(mod, "aws_instance")
    rotation = r"enable_key_rotation\s*=\s*true"
    if variable_default(kms_vars, "enable_key_rotation") == "true":
        rotation = r"enable_key_rotation\s*=\s*(true|var\.enable_key_rotation)"
    keys = resources(mod, "aws_kms_key") + resources(kms, "aws_kms_key")
    return [
        Check("SEC-06", "Server disks encrypted", "Disques du serveur chiffrés",
              every(vms, r"root_block_device\s*\{[^}]*encrypted\s*=\s*true"),
              f"{len(vms)} aws_instance: root_block_device encrypted = true"),
        Check("SEC-07", "Encryption key rotation enabled", "Rotation des clés de chiffrement activée",
              every(keys, rotation), f"{len(keys)} aws_kms_key: enable_key_rotation"),
        Check("SEC-08", "Instance metadata v2 enforced (IMDSv2)",
              "Métadonnées d'instance v2 imposées (IMDSv2)",
              every(vms, r'http_tokens\s*=\s*"required"'), f"{len(vms)} aws_instance: http_tokens = required"),
        check_ssh_closed(mod),
    ]


def _int_attr(block: str, name: str) -> int | None:
    m = re.search(r"\b%s\s*=\s*(\d+)" % name, block)
    return int(m.group(1)) if m else None


def opens_ssh_to_internet(rule: str) -> bool:
    """Any attribute order; cidr_ipv4/ipv6 or cidr_blocks; port range or protocol -1."""
    if not re.search(r'"(0\.0\.0\.0/0|::/0)"', rule):
        return False
    if re.search(r'(ip_)?protocol\s*=\s*"-1"', rule):
        return True
    low, high = _int_attr(rule, "from_port"), _int_attr(rule, "to_port")
    return low is not None and low <= 22 <= (high if high is not None else low)


def ingress_rules(mod: str) -> list[str]:
    inline = [b for sg in resources(mod, "aws_security_group") for b in _blocks(sg, r"\bingress")]
    return resources(mod, "aws_vpc_security_group_ingress_rule") + inline


def check_ssh_closed(mod: str) -> Check:
    """SSH (22) must not be reachable from the whole Internet; admin goes through SSM."""
    public_ssh = [r for r in ingress_rules(mod) if opens_ssh_to_internet(r)]
    return Check("SEC-09", "SSH not open to the Internet (admin via SSM)",
                 "SSH non exposé sur Internet (administration via SSM)", not public_ssh,
                 f"{len(public_ssh)} ingress rule(s) open to 0.0.0.0/0 covering port 22")


def build_report(root: Path, environment: str) -> Report:
    tfvars = parse_tfvars(read(root / "environments" / environment / "terraform.tfvars"))
    variables, mods = read(root / "variables.tf"), root / "modules"
    region = resolve("aws_region", tfvars, variables) or "unknown"
    report = Report(environment, str(root), _now(), region,
                    EEA_AWS_REGIONS.get(region, "outside EEA / hors EEE"))
    report.checks.append(check_region(region))
    report.checks += residency_toggles(tfvars, variables)
    retention = resolve("rds_backup_retention_days", tfvars, variables)
    report.checks += check_rds(read(mods / "database-rds" / "main.tf"), retention)
    report.checks += check_storage(read(mods / "storage" / "main.tf"), read(root / "main.tf"))
    report.checks += check_compute(read(mods / "compute-ec2" / "main.tf"), read(mods / "kms" / "main.tf"),
                                   read(mods / "kms" / "variables.tf"))
    return report


def residency_toggles(tfvars: dict[str, str], variables: str) -> list[Check]:
    """Components that would leave France: Neon (Frankfurt), CloudFront edge (global)."""
    legacy = resolve("use_legacy_stack", tfvars, variables)
    edge = resolve("use_cloudfront_edge", tfvars, variables)
    return [
        check_off_region_module("RES-02", "use_legacy_stack", legacy, "Neon Postgres (eu-central-1)"),
        check_off_region_module("RES-03", "use_cloudfront_edge", edge, "CloudFront edge (global)"),
    ]


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def render_markdown(report: Report) -> str:
    verdict = "PASS" if report.residency_ok else "FAIL"
    lines = [
        "<!-- AUTO-GENERATED by axiome-infra/scripts/hosting-evidence/scan.py (AXI-2416). Do not hand-edit. -->",
        f"# Hosting evidence / Preuves d'hébergement — {report.environment}",
        "",
        f"- Generated / Généré : `{report.generated_at}`",
        f"- Source : `{report.provider_root}` (Terraform, static read / lecture statique)",
        f"- Region / Région : **{report.region} — {report.region_label}**",
        f"- Residency verdict / Verdict de résidence : **{verdict}**",
        "",
        "| ID | Check (EN) | Contrôle (FR) | Result | Evidence |",
        "|----|-----------|---------------|--------|----------|",
    ]
    lines += [_row(c) for c in report.checks]
    lines += ["", "Static evidence from code; the live state is evidenced per deployment by "
              "`scripts/generate-hds-report.sh`. / Preuve statique issue du code ; l'état réel "
              "est prouvé à chaque déploiement par `scripts/generate-hds-report.sh`.", ""]
    return "\n".join(lines)


def _row(c: Check) -> str:
    result = "PASS" if c.passed else "FAIL"
    return f"| {c.id} | {c.title_en} | {c.title_fr} | {result} | `{c.evidence}` |"


def write_outputs(report: Report, out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{report.generated_at.replace(':', '')}__{report.environment}__hosting-evidence"
    md_path, json_path = out_dir / f"{stem}.md", out_dir / f"{stem}.json"
    md_path.write_text(render_markdown(report), encoding="utf-8")
    payload = asdict(report) | {"residency_ok": report.residency_ok}
    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return [md_path, json_path]


def parse_args(argv: list[str]) -> argparse.Namespace:
    repo = Path(__file__).resolve().parents[2]
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--provider-root", type=Path, default=repo / "providers" / "aws")
    p.add_argument("--environment", default="production")
    p.add_argument("--out-dir", type=Path, default=repo.parent / "axiome-docs" / "reports" / "hosting")
    p.add_argument("--json-only", action="store_true", help="print JSON to stdout, write nothing")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    report = build_report(args.provider_root, args.environment)
    if args.json_only:
        print(json.dumps(asdict(report) | {"residency_ok": report.residency_ok}, indent=2))
    else:
        for path in write_outputs(report, args.out_dir):
            print(path)
    return 0 if report.residency_ok else 2


if __name__ == "__main__":
    sys.exit(main())
