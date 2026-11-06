#!/usr/bin/env python3
"""Partner-facing hosting evidence annex (AXI-2416, Feature Hosting-Assurance-Pack FR1).

Renders the JSON written by scan.py as a plain-language Markdown annex, in French or
English. Results come only from the JSON. The texts below explain each check; a check
without a text fails the render, so a new control cannot reach a partner unexplained.

Usage: partner_report.py <report.json> --lang fr|en [--deployment <deployment.json>] > annex.md
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

LABELS = {
    "fr": {
        "title": "Annexe 1 — Rapport de preuves d'hébergement",
        "subtitle": "Plateforme Axiome — environnement de production",
        "generated": "Généré le {date} à {time} UTC",
        "revision": "Version de la configuration : axiome-infra, révision `{rev}`",
        "deploy": "Dernier déploiement en production",
        "deploy_text": (
            "La configuration d'infrastructure lue pour ce rapport est identique à celle appliquée en "
            "production le {date} à {time} UTC par la chaîne de déploiement automatisée (GitHub Actions, "
            "exécution n° {run}, révision `{sha}`). "
            "Résultat consigné dans le journal : `{summary}`. Un extrait de ce journal est archivé "
            "avec ce rapport et peut être présenté lors d'un audit."
        ),
        "summary": "Synthèse",
        "host": "Hébergement : Amazon Web Services, région Europe (Paris) `{region}`, centres de données en France.",
        "residency": "Résidence des données en France : **{verdict}**.",
        "score": "Contrôles : **{ok} sur {total} conformes**.",
        "how": "Comment ce rapport est produit",
        "how_text": (
            "Ce rapport n'est pas une déclaration rédigée à la main. Il est généré automatiquement "
            "par un programme qui lit la configuration de l'infrastructure de production d'Axiome, "
            "décrite en code (Terraform). Chaque résultat ci-dessous est tiré de cette configuration. "
            "Il porte sur la configuration déclarée et ne remplace pas un audit. La certification "
            "HDS de l'hébergeur (AWS) est présentée dans la fiche hébergement."
        ),
        "results": "Résultats",
        "pass": "Conforme",
        "fail": "Non conforme",
        "detail": "Détail technique",
        "detail_text": "Élément de configuration relevé pour chaque contrôle :",
    },
    "en": {
        "title": "Annex 1 — Hosting evidence report",
        "subtitle": "Axiome platform — production environment",
        "generated": "Generated on {date} at {time} UTC",
        "revision": "Configuration version: axiome-infra, revision `{rev}`",
        "deploy": "Last production deployment",
        "deploy_text": (
            "The infrastructure configuration read for this report is identical to the one applied to "
            "production on {date} at {time} UTC by the automated deployment pipeline (GitHub Actions, "
            "run no. {run}, revision `{sha}`). "
            "Result recorded in the log: `{summary}`. An extract of this log is archived with this "
            "report and can be presented during an audit."
        ),
        "summary": "Summary",
        "host": "Hosting: Amazon Web Services, Europe (Paris) region `{region}`, data centres in France.",
        "residency": "Data residency in France: **{verdict}**.",
        "score": "Checks: **{ok} of {total} passed**.",
        "how": "How this report is produced",
        "how_text": (
            "This report is not a hand-written statement. It is generated automatically by a "
            "program that reads the configuration of Axiome's production infrastructure, which is "
            "described as code (Terraform). Every result below is taken from that configuration. "
            "It covers the declared configuration and does not replace an audit. The HDS "
            "certification of the host (AWS) is presented in the hosting fact sheet."
        ),
        "results": "Results",
        "pass": "Pass",
        "fail": "Fail",
        "detail": "Technical detail",
        "detail_text": "Configuration item read for each check:",
    },
}

CHECK_TEXT = {
    "RES-01": {
        "fr": ("Région d'hébergement en France",
               "Les serveurs, la base de données et le stockage de fichiers sont créés dans la région "
               "AWS Europe (Paris), dont les centres de données sont en France."),
        "en": ("Hosting region in France",
               "The servers, the database and file storage are created in the AWS Europe (Paris) "
               "region, whose data centres are in France."),
    },
    "RES-02": {
        "fr": ("Aucune base de données hors de France",
               "La base de données externe d'une ancienne version de la plateforme, hébergée en "
               "Allemagne, n'est pas déployée en production."),
        "en": ("No database outside France",
               "The external database of an earlier version of the platform, hosted in Germany, is "
               "not deployed in production."),
    },
    "RES-03": {
        "fr": ("Aucune diffusion mondiale du contenu",
               "Le réseau mondial de diffusion de contenu d'AWS (CloudFront), qui pourrait conserver "
               "des copies hors de France, n'est pas déployé en production."),
        "en": ("No worldwide content delivery",
               "AWS's worldwide content delivery network (CloudFront), which could keep copies "
               "outside France, is not deployed in production."),
    },
    "SEC-01": {
        "fr": ("Base de données chiffrée",
               "La base de données est chiffrée sur disque avec une clé de chiffrement dédiée (AWS KMS)."),
        "en": ("Database encrypted",
               "The database is encrypted on disk with a dedicated encryption key (AWS KMS)."),
    },
    "SEC-02": {
        "fr": ("Base de données protégée contre la suppression",
               "La suppression de la base de données de production est bloquée tant que cette "
               "protection n'est pas retirée volontairement."),
        "en": ("Database protected against deletion",
               "Deleting the production database is blocked until this protection is deliberately "
               "removed."),
    },
    "SEC-03": {
        "fr": ("Sauvegardes automatiques de la base",
               "La base de données est sauvegardée automatiquement, dans la même région."),
        "en": ("Automatic database backups",
               "The database is backed up automatically, in the same region."),
    },
    "SEC-04": {
        "fr": ("Fichiers chiffrés",
               "Tous les espaces de stockage de fichiers (fichiers déposés, résultats, sauvegardes) "
               "sont chiffrés avec la clé dédiée."),
        "en": ("Files encrypted",
               "All file storage spaces (uploaded files, results, backups) are encrypted with the "
               "dedicated key."),
    },
    "SEC-05": {
        "fr": ("Aucun accès public aux fichiers",
               "L'accès public est bloqué sur tous les espaces de stockage de fichiers."),
        "en": ("No public access to files",
               "Public access is blocked on every file storage space."),
    },
    "SEC-06": {
        "fr": ("Disque du serveur chiffré",
               "Le disque du serveur applicatif est chiffré."),
        "en": ("Server disk encrypted",
               "The application server's disk is encrypted."),
    },
    "SEC-07": {
        "fr": ("Renouvellement automatique des clés",
               "La rotation automatique des clés de chiffrement est activée."),
        "en": ("Automatic key rotation",
               "Automatic rotation of the encryption keys is enabled."),
    },
    "SEC-08": {
        "fr": ("Protection des identifiants internes du serveur",
               "Le serveur impose la version sécurisée (v2) du service de métadonnées AWS, qui "
               "protège ses identifiants internes contre une catégorie connue d'attaques."),
        "en": ("Server's internal credentials protected",
               "The server enforces the secure version (v2) of the AWS metadata service, which "
               "protects its internal credentials against a known class of attacks."),
    },
    "SEC-09": {
        "fr": ("Aucun accès d'administration ouvert sur Internet",
               "Aucune règle réseau n'ouvre le port d'administration SSH (22) sur Internet. "
               "L'administration passe par le service AWS Systems Manager, qui exige un compte AWS "
               "autorisé."),
        "en": ("No administration access open to the Internet",
               "No network rule opens the SSH administration port (22) to the Internet. "
               "Administration goes through AWS Systems Manager, which requires an authorised AWS "
               "account."),
    },
}


def check_text(cid: str, lang: str) -> tuple[str, str]:
    if cid not in CHECK_TEXT:
        raise KeyError(f"no partner text for check {cid}; add it to CHECK_TEXT")
    return CHECK_TEXT[cid][lang]


def format_date(iso: str, lang: str) -> tuple[str, str]:
    day, clock = iso.rstrip("Z").split("T")
    y, m, d = day.split("-")
    return (f"{d}/{m}/{y}" if lang == "fr" else f"{y}-{m}-{d}"), clock[:5]


def header(report: dict, lang: str) -> list[str]:
    t = LABELS[lang]
    date, time = format_date(report["generated_at"], lang)
    lines = [f"# {t['title']}", "", f"**{t['subtitle']}**\\", t["generated"].format(date=date, time=time)]
    if report.get("revision"):
        lines[-1] += "\\"
        lines.append(t["revision"].format(rev=report["revision"]))
    return lines + [""]


def summary(report: dict, lang: str) -> list[str]:
    t, checks = LABELS[lang], report["checks"]
    verdict = t["pass"] if report["residency_ok"] else t["fail"]
    ok = sum(1 for c in checks if c["passed"])
    return [f"## {t['summary']}", "",
            f"- {t['host'].format(region=report['region'])}",
            f"- {t['residency'].format(verdict=verdict.lower())}",
            f"- {t['score'].format(ok=ok, total=len(checks))}", ""]


def results(report: dict, lang: str) -> list[str]:
    t = LABELS[lang]
    lines = [f"## {t['results']}", ""]
    for c in report["checks"]:
        title, desc = check_text(c["id"], lang)
        outcome = t["pass"] if c["passed"] else t["fail"].upper()
        lines.append(f"- **{c['id']} · {title} — {outcome}.** {desc}")
    return lines + [""]


def detail(report: dict, lang: str) -> list[str]:
    t = LABELS[lang]
    lines = [f"## {t['detail']}", "", t["detail_text"], ""]
    lines += [f"- {c['id']} : `{c['evidence']}`" if lang == "fr" else f"- {c['id']}: `{c['evidence']}`"
              for c in report["checks"]]
    return lines + [""]


def deployment(dep: dict | None, lang: str) -> list[str]:
    if dep is None:
        return []
    t = LABELS[lang]
    date, time = format_date(dep["completed_at"], lang)
    text = t["deploy_text"].format(sha=dep["head_sha"], date=date, time=time,
                                   run=dep["run_id"], summary=dep["apply_summary"])
    return [f"## {t['deploy']}", "", text, ""]


def render_partner(report: dict, lang: str, dep: dict | None = None) -> str:
    t = LABELS[lang]
    how = [f"## {t['how']}", "", t["how_text"], ""]
    body = header(report, lang) + summary(report, lang) + how + deployment(dep, lang)
    return "\n".join(body + results(report, lang) + detail(report, lang))


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("report", type=Path)
    p.add_argument("--lang", choices=sorted(LABELS), required=True)
    p.add_argument("--deployment", type=Path, help="JSON from last_deployment.py")
    args = p.parse_args(sys.argv[1:] if argv is None else argv)
    report = json.loads(args.report.read_text(encoding="utf-8"))
    dep = json.loads(args.deployment.read_text(encoding="utf-8")) if args.deployment else None
    sys.stdout.write(render_partner(report, args.lang, dep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
