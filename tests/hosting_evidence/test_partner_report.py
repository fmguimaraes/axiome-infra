"""Unit tests for partner_report.py, last_deployment.py and scan.py revision (AXI-2416).

IDs UT-INFRA-667..676 (see UT.md). AAA, one behaviour each. Run:
  python3 -m unittest discover -s tests/hosting_evidence -v
"""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

_DIR = Path(__file__).resolve().parents[2] / "scripts" / "hosting-evidence"
_PROVIDER = Path(__file__).resolve().parents[2] / "providers" / "aws"


def _load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, _DIR / file)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


partner = _load("hosting_partner", "partner_report.py")
deploy = _load("hosting_deploy", "last_deployment.py")
scan = _load("hosting_scan_rev", "scan.py")


def _report(passed: bool = True, revision: str = "abc123") -> dict:
    checks = [{"id": "RES-01", "passed": passed, "blocking": True, "evidence": "aws_region = eu-west-3"},
              {"id": "SEC-09", "passed": True, "blocking": False, "evidence": "0 ingress rule(s)"}]
    return {"generated_at": "2026-11-06T14:35:50Z", "region": "eu-west-3", "revision": revision,
            "residency_ok": passed, "checks": checks}


_DEP = {"run_id": 42, "head_sha": "abc123", "completed_at": "2026-11-06T14:35:22Z",
        "apply_summary": "Apply complete! Resources: 0 added, 8 changed, 1 destroyed."}

_LOG = ("2026-11-06T14:35:01.1Z \x1b[1m  # module.x.aws_vpc_security_group_ingress_rule.ssh\x1b[0m "
        "will be \x1b[31mdestroyed\x1b[0m\n"
        "2026-11-06T14:35:02.1Z module.x.ssh: Destruction complete after 1s\n"
        "2026-11-06T14:35:03.1Z \x1b[0m\x1b[1mApply complete! Resources: 0 added, 0 changed, 1 destroyed.\x1b[0m\n")


def _results_rows(md: str) -> list[str]:
    section = md.split("## Résultats")[1].split("## ")[0]
    return [line for line in section.splitlines() if line.startswith(("- **RES", "- **SEC"))]


class FakeGh:
    def __init__(self, runs: list[dict], jobs: dict[int, list[dict]], logs: dict[int, str]):
        self.runs, self.jobs, self.logs = runs, jobs, logs

    def __call__(self, args: list[str]) -> str:
        path = args[1]
        if "/workflows/" in path:
            return json.dumps({"workflow_runs": self.runs})
        if path.endswith("/jobs"):
            return json.dumps({"jobs": self.jobs[int(path.split("/")[-2])]})
        return self.logs[int(path.split("/")[-2])]


def _job(jid: int, conclusion: str = "success") -> dict:
    return {"id": jid, "name": 'Production (the only live environment — "platform")',
            "conclusion": conclusion, "completed_at": "2026-11-06T14:35:22Z"}


def _run(rid: int) -> dict:
    return {"id": rid, "html_url": f"https://example.test/runs/{rid}", "head_sha": f"sha{rid}"}


class PartnerReportTest(unittest.TestCase):
    def test_ut_infra_667_french_rows_are_plain_language_without_code_cells(self):
        # Arrange
        report = _report()
        # Act
        rows = _results_rows(partner.render_partner(report, "fr"))
        # Assert
        self.assertEqual(len(rows), 2)
        self.assertTrue(rows[0].startswith("- **RES-01 · Région d'hébergement en France — Conforme.** "))
        self.assertTrue(all("— Conforme.**" in r and "`" not in r for r in rows))

    def test_ut_infra_668_check_without_partner_text_fails_the_render(self):
        # Arrange
        report = _report()
        report["checks"].append({"id": "SEC-99", "passed": True, "blocking": False, "evidence": "x"})
        # Act / Assert
        with self.assertRaises(KeyError):
            partner.render_partner(report, "fr")

    def test_ut_infra_669_failed_residency_is_shown_as_non_conforme(self):
        # Arrange
        report = _report(passed=False)
        # Act
        md = partner.render_partner(report, "fr")
        # Assert
        self.assertIn("Résidence des données en France : **non conforme**.", md)
        self.assertIn("- **RES-01 · Région d'hébergement en France — NON CONFORME.**", md)
        self.assertIn("**1 sur 2 conformes**", md)

    def test_ut_infra_670_revision_is_printed_in_the_header_only_when_known(self):
        # Arrange
        with_rev, without_rev = _report(revision="c66e719abc"), _report(revision="")
        # Act
        md_with, md_without = partner.render_partner(with_rev, "fr"), partner.render_partner(without_rev, "fr")
        # Assert
        self.assertIn("axiome-infra, révision `c66e719abc`", md_with)
        self.assertNotIn("révision", md_without.split("## Synthèse")[0])

    def test_ut_infra_671_deployment_section_names_run_commit_date_and_result(self):
        # Arrange
        report = _report()
        # Act
        md, md_none = partner.render_partner(report, "fr", _DEP), partner.render_partner(report, "fr")
        # Assert
        self.assertIn("## Dernier déploiement en production", md)
        self.assertIn("identique à celle appliquée en production le 06/11/2026 à 14:35 UTC", md)
        self.assertIn("exécution n° 42, révision `abc123`", md)
        self.assertIn("`Apply complete! Resources: 0 added, 8 changed, 1 destroyed.`", md)
        self.assertNotIn("Dernier déploiement", md_none)

    def test_ut_infra_672_every_check_the_scanner_emits_has_french_and_english_text(self):
        # Arrange
        ids = {c.id for c in scan.build_report(_PROVIDER, "production").checks}
        # Act
        missing = [(i, lang) for i in ids for lang in ("fr", "en") if lang not in partner.CHECK_TEXT.get(i, {})]
        # Assert
        self.assertEqual(missing, [])

    def test_ut_infra_677_annex_ends_with_a_glossary_in_its_language(self):
        # Arrange
        report = _report()
        # Act
        fr, en = partner.render_partner(report, "fr"), partner.render_partner(report, "en")
        # Assert
        self.assertIn("## Glossaire", fr)
        self.assertIn("- **RES** : Contrôles de résidence des données", fr.split("## Glossaire")[1])
        self.assertIn("## Glossary", en)
        self.assertIn("- **SEC**: Hosting security checks", en.split("## Glossary")[1])

    def test_ut_infra_678_every_check_prefix_the_scanner_emits_is_in_both_glossaries(self):
        # Arrange
        prefixes = {c.id.split("-")[0] for c in scan.build_report(_PROVIDER, "production").checks}
        # Act
        missing = [(p, lang) for p in prefixes for lang in ("fr", "en")
                   if p not in {term for term, _ in partner.GLOSSARY[lang]}]
        # Assert
        self.assertEqual(missing, [])


class ScanRevisionTest(unittest.TestCase):
    def test_ut_infra_673_revision_is_recorded_and_no_absolute_path_is_reported(self):
        # Arrange / Act
        report = scan.build_report(_PROVIDER, "production", "c66e719")
        md = scan.render_markdown(report)
        # Assert
        self.assertEqual(report.revision, "c66e719")
        self.assertEqual(report.provider_root, "axiome-infra/providers/aws")
        self.assertIn("Revision / Révision : `c66e719`", md)
        self.assertNotIn(str(Path.home()), md)


class LastDeploymentTest(unittest.TestCase):
    def test_ut_infra_674_apply_summary_and_changes_are_read_from_a_raw_log(self):
        # Arrange / Act
        parsed, none = deploy.parse_apply(_LOG), deploy.parse_apply("no apply here\n")
        # Assert
        self.assertEqual(parsed["apply_summary"], "Apply complete! Resources: 0 added, 0 changed, 1 destroyed.")
        self.assertEqual(parsed["changes"], ["module.x.aws_vpc_security_group_ingress_rule.ssh: destroyed"])
        self.assertIsNone(none)

    def test_ut_infra_675_runs_without_a_successful_production_apply_are_skipped(self):
        # Arrange
        gh = FakeGh(runs=[_run(3), _run(2), _run(1)],
                    jobs={3: [_job(30, "skipped")], 2: [_job(20)], 1: [_job(10)]},
                    logs={20: "plan only, nothing applied\n", 10: _LOG})
        # Act
        found = deploy.last_apply(gh, "o/r", "terraform-cd.yml")
        # Assert
        self.assertEqual((found["run_id"], found["head_sha"]), (1, "sha1"))
        self.assertEqual(found["completed_at"], "2026-11-06T14:35:22Z")

    def test_ut_infra_676_no_production_apply_raises(self):
        # Arrange
        gh = FakeGh(runs=[_run(1)], jobs={1: [_job(10, "failure")]}, logs={})
        # Act / Assert
        with self.assertRaises(LookupError):
            deploy.last_apply(gh, "o/r", "terraform-cd.yml")


if __name__ == "__main__":
    unittest.main()
