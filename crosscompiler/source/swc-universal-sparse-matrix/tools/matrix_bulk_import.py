"""Conservative structural validator for the SWC sparse matrix package."""
import argparse, csv, json, pathlib, sys

def rows(path):
    with path.open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args(); root = pathlib.Path(args.root)
    matrices, reports = root / "matrices", root / "reports"
    coverage = json.loads((reports / "uast-coverage-report.json").read_text(encoding="utf-8-sig"))
    kinds = coverage["kinds"]
    counts = {}
    for item in kinds: counts[item["status"]] = counts.get(item["status"], 0) + 1
    errors = []
    if coverage["catalog"]["node_kinds"] != 82 or len(kinds) != 82:
        errors.append("UAST catalog must contain exactly 82 rows")
    if coverage["catalog"]["relation_kinds"] != 23 or len(coverage["relations"]) != 23:
        errors.append("relation catalog must contain exactly 23 rows")
    required = ["uast_capabilities.csv", "capabilities_primitives.csv", "primitives_x64.csv", "native_emission_contracts.csv", "semantic_dependencies.csv", "uast_recipes.csv"]
    errors += ["missing matrix: " + name for name in required if not (matrices / name).exists()]
    dependencies = rows(matrices / "semantic_dependencies.csv")
    result = {
        "schema": "swc.universal-sparse-matrix.validation.v1",
        "catalog": {"uast_kinds": len(kinds), "relation_families": len(coverage["relations"])},
        "coverage": counts,
        "dependency_capabilities": len({r["Capability"] for r in dependencies}),
        "errors": errors,
        "native_claims_source": "reports/native_validation_report.json"
    }
    print(json.dumps(result, indent=2))
    return 1 if args.strict and errors else 0

if __name__ == "__main__": sys.exit(main())
