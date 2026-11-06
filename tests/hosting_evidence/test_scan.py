"""Unit tests for scripts/hosting-evidence/scan.py (AXI-2416).

IDs UT-INFRA-650.. (see UT.md). AAA, one behaviour each. Run:
  python3 -m unittest discover -s tests/hosting_evidence -v
"""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

_SCAN = Path(__file__).resolve().parents[2] / "scripts" / "hosting-evidence" / "scan.py"
_spec = importlib.util.spec_from_file_location("hosting_scan", _SCAN)
scan = importlib.util.module_from_spec(_spec)
sys.modules["hosting_scan"] = scan
_spec.loader.exec_module(scan)

GOOD_MODULES = {
    "database-rds/main.tf": 'resource "aws_db_instance" "this" {\n  storage_encrypted = true\n'
                            '  kms_key_id = var.kms_key_arn\n  backup_retention_period = var.days\n'
                            '  deletion_protection = var.environment == "production"\n}\n',
    "storage/main.tf": 'resource "aws_s3_bucket" "a" {\n  bucket = "a"\n}\n'
                       'resource "aws_s3_bucket_public_access_block" "a" {\n  block_public_acls = true\n'
                       '  block_public_policy = true\n}\n'
                       'resource "aws_s3_bucket_server_side_encryption_configuration" "a" {\n  rule {\n'
                       '    sse_algorithm = var.kms_key_arn == "" ? "AES256" : "aws:kms"\n  }\n}\n',
    "compute-ec2/main.tf": 'resource "aws_instance" "main" {\n  metadata_options {\n'
                           '    http_tokens = "required"\n  }\n  root_block_device {\n'
                           '    encrypted = true\n  }\n}\n',
    "kms/main.tf": 'resource "aws_kms_key" "data" {\n  enable_key_rotation = var.enable_key_rotation\n}\n',
    "kms/variables.tf": 'variable "enable_key_rotation" {\n  type = bool\n  default = true\n}\n',
}
ROOT_MAIN = 'module "storage" {\n  source = "./modules/storage"\n  kms_key_arn = module.kms.key_arn\n}\n'
VARIABLES = (
    'variable "use_cloudfront_edge" {\n  type = bool\n  default = false\n}\n'
    'variable "rds_backup_retention_days" {\n  type = number\n  default = 7\n}\n'
)


def make_root(tmp: str, tfvars: str, modules: dict[str, str] | None = None,
              root_main: str = ROOT_MAIN) -> Path:
    root = Path(tmp)
    (root / "environments" / "production").mkdir(parents=True)
    (root / "environments" / "production" / "terraform.tfvars").write_text(tfvars)
    (root / "variables.tf").write_text(VARIABLES)
    (root / "main.tf").write_text(root_main)
    for rel, body in (modules or GOOD_MODULES).items():
        (root / "modules" / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / "modules" / rel).write_text(body)
    return root


def by_id(report, cid):
    return next(c for c in report.checks if c.id == cid)


class HostingEvidenceScanTest(unittest.TestCase):
    def test_ut_infra_650_paris_region_passes_residency(self):
        # Arrange
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, 'aws_region = "eu-west-3"\nuse_legacy_stack = false\n')
            # Act
            report = scan.build_report(root, "production")
        # Assert
        self.assertTrue(report.residency_ok)
        self.assertEqual(report.region_label, "France (Paris)")

    def test_ut_infra_651_non_french_region_fails_residency(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, 'aws_region = "eu-central-1"\n')
            report = scan.build_report(root, "production")
        self.assertFalse(by_id(report, "RES-01").passed)
        self.assertFalse(report.residency_ok)

    def test_ut_infra_652_neon_legacy_stack_on_fails_residency(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, 'aws_region = "eu-west-3"\nuse_legacy_stack = true\n')
            report = scan.build_report(root, "production")
        self.assertFalse(by_id(report, "RES-02").passed)
        self.assertFalse(report.residency_ok)

    def test_ut_infra_653_cloudfront_default_false_is_read_from_variables(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, 'aws_region = "eu-west-3"\n')
            report = scan.build_report(root, "production")
        self.assertTrue(by_id(report, "RES-03").passed)
        self.assertIn("false", by_id(report, "RES-03").evidence)

    def test_ut_infra_654_missing_encryption_fails_check_but_not_residency(self):
        modules = dict(GOOD_MODULES, **{"database-rds/main.tf": 'resource "aws_db_instance" "x" {\n  storage_encrypted = false\n}\n'})
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, 'aws_region = "eu-west-3"\n', modules)
            report = scan.build_report(root, "production")
        self.assertFalse(by_id(report, "SEC-01").passed)
        self.assertTrue(report.residency_ok)

    def test_ut_infra_655_secret_like_tfvars_are_never_parsed(self):
        text = 'aws_region = "eu-west-3"\nmailjet_api_key = "abc123"\ndb_password = "p"\n'
        values = scan.parse_tfvars(text)
        self.assertEqual(values, {"aws_region": "eu-west-3"})

    def test_ut_infra_656_outputs_are_bilingual_markdown_and_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, 'aws_region = "eu-west-3"\n')
            report = scan.build_report(root, "production")
            md, js = scan.write_outputs(report, Path(tmp) / "out")
            md_text, payload = md.read_text(), json.loads(js.read_text())
        self.assertIn("Région principale en France", md_text)
        self.assertIn("Primary region is in France", md_text)
        self.assertTrue(payload["residency_ok"])

    def test_ut_infra_657_main_exits_2_when_residency_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, 'aws_region = "us-east-1"\n')
            code = scan.main(["--provider-root", str(root), "--out-dir", str(Path(tmp) / "o")])
        self.assertEqual(code, 2)

    def test_ut_infra_658_real_production_terraform_is_in_france(self):
        root = Path(__file__).resolve().parents[2] / "providers" / "aws"
        report = scan.build_report(root, "production")
        self.assertEqual(report.region, "eu-west-3")
        self.assertTrue(report.residency_ok, [c.id for c in report.checks if not c.passed])

    def test_ut_infra_659_ssh_open_to_internet_fails_sec09(self):
        mod = 'resource "aws_vpc_security_group_ingress_rule" "ssh" {\n  cidr_ipv4         = "0.0.0.0/0"\n  from_port         = 22\n}\n'
        modules = dict(GOOD_MODULES, **{"compute-ec2/main.tf": GOOD_MODULES["compute-ec2/main.tf"] + mod})
        with tempfile.TemporaryDirectory() as tmp:
            report = scan.build_report(make_root(tmp, 'aws_region = "eu-west-3"\n', modules), "production")
        self.assertFalse(by_id(report, "SEC-09").passed)

    def test_ut_infra_660_no_public_ssh_rule_passes_sec09(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = scan.build_report(make_root(tmp, 'aws_region = "eu-west-3"\n'), "production")
        self.assertTrue(by_id(report, "SEC-09").passed)

    def test_ut_infra_661_commented_out_control_does_not_count(self):
        vm = 'resource "aws_instance" "main" {\n  # http_tokens = "required"\n  root_block_device {\n    encrypted = true\n  }\n}\n'
        modules = dict(GOOD_MODULES, **{"compute-ec2/main.tf": vm})
        with tempfile.TemporaryDirectory() as tmp:
            report = scan.build_report(make_root(tmp, 'aws_region = "eu-west-3"\n', modules), "production")
        self.assertFalse(by_id(report, "SEC-08").passed)

    def test_ut_infra_662_one_bucket_without_public_block_fails_sec05(self):
        storage = GOOD_MODULES["storage/main.tf"] + 'resource "aws_s3_bucket" "b" {\n  bucket = "b"\n}\n'
        modules = dict(GOOD_MODULES, **{"storage/main.tf": storage})
        with tempfile.TemporaryDirectory() as tmp:
            report = scan.build_report(make_root(tmp, 'aws_region = "eu-west-3"\n', modules), "production")
        self.assertFalse(by_id(report, "SEC-05").passed)

    def test_ut_infra_663_sse_kms_conditional_without_wired_key_fails_sec04(self):
        unwired = 'module "storage" {\n  source = "./modules/storage"\n}\n'
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, 'aws_region = "eu-west-3"\n', root_main=unwired)
            report = scan.build_report(root, "production")
        self.assertFalse(by_id(report, "SEC-04").passed)

    def test_ut_infra_664_ssh_detected_in_any_order_range_or_all_protocols(self):
        rules = [
            '  from_port = 22\n  to_port = 22\n  description = "x"\n  cidr_ipv4 = "0.0.0.0/0"\n',
            '  from_port = 0\n  to_port = 65535\n  cidr_ipv4 = "0.0.0.0/0"\n',
            '  ip_protocol = "-1"\n  cidr_ipv4 = "0.0.0.0/0"\n',
        ]
        flagged = [scan.opens_ssh_to_internet(r) for r in rules]
        self.assertEqual(flagged, [True, True, True])

    def test_ut_infra_665_inline_ingress_cidr_blocks_form_is_detected(self):
        sg = ('resource "aws_security_group" "web" {\n  ingress {\n    from_port = 22\n'
              '    to_port = 22\n    cidr_blocks = ["0.0.0.0/0"]\n  }\n}\n')
        check = scan.check_ssh_closed(sg)
        self.assertFalse(check.passed)

    def test_ut_infra_666_https_only_public_rule_is_not_ssh(self):
        rule = '  from_port = 443\n  to_port = 443\n  ip_protocol = "tcp"\n  cidr_ipv4 = "0.0.0.0/0"\n'
        self.assertFalse(scan.opens_ssh_to_internet(rule))


if __name__ == "__main__":
    unittest.main()
