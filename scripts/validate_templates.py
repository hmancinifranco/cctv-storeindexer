#!/usr/bin/env python3
"""Lightweight local validation for CloudFormation/SAM templates.

Parses YAML while tolerating CloudFormation intrinsic tags (!Ref, !Sub, !If,
!GetAtt, ...) and asserts a few structural invariants. This is a fast local
gate; CI runs `cfn-lint` for full validation.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml


class CfnLoader(yaml.SafeLoader):
    """SafeLoader that accepts CloudFormation `!Tag` shorthand."""


def _construct_cfn_tag(loader: CfnLoader, tag_suffix: str, node: yaml.Node) -> object:
    if isinstance(node, yaml.ScalarNode):
        return {tag_suffix: loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {tag_suffix: loader.construct_sequence(node)}
    return {tag_suffix: loader.construct_mapping(node)}


CfnLoader.add_multi_constructor("!", _construct_cfn_tag)


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    doc = yaml.load(path.read_text(), Loader=CfnLoader)  # noqa: S506 (custom safe loader)
    if not isinstance(doc, dict):
        return [f"{path}: not a mapping at top level"]
    if "Resources" not in doc or not doc["Resources"]:
        errors.append(f"{path}: no Resources section")
    for name, res in (doc.get("Resources") or {}).items():
        if "Type" not in res:
            errors.append(f"{path}: resource {name} missing Type")
    return errors


def main() -> int:
    templates = sorted(Path("infra").rglob("*.yaml"))
    if not templates:
        print("no templates found — skipping")
        return 0
    all_errors: list[str] = []
    for tpl in templates:
        errs = validate(tpl)
        if errs:
            all_errors.extend(errs)
        else:
            print(f"OK  {tpl}")
    if all_errors:
        print("\n".join(all_errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
