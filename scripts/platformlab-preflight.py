#!/usr/bin/env python3
"""Local, read-only-by-default dependency and security preflight for PlatformLab.

No release, git writes, secret disclosures, or automatic dependency upgrades.
--build updates local Docker image cache and creates :preflight images only.
Reports live OUTSIDE the repository at ../_local-reports/k8s-platform-lab.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TOOLS = {
    "python": [sys.executable, "--version"],
    "git": ["git", "--version"],
    "docker": ["docker", "--version"],
    "node": ["node", "--version"],
    "npm": ["npm", "--version"],
    "helm": ["helm", "version", "--short"],
    "trivy": ["trivy", "--version"],
    "hadolint": ["hadolint", "--version"],
    "actionlint": ["actionlint", "-version"],
    "shellcheck": ["shellcheck", "--version"],
    "gitleaks": ["gitleaks", "version"],
    "semgrep": ["semgrep", "--version"],
    "gh": ["gh", "--version"],
}
RELEASE_REPOS = {
    "trivy": "aquasecurity/trivy",
    "hadolint": "hadolint/hadolint",
    "actionlint": "rhysd/actionlint",
    "shellcheck": "koalaman/shellcheck",
    "gitleaks": "gitleaks/gitleaks",
    "helm": "helm/helm",
    "semgrep": "semgrep/semgrep",
}
SCANNER_KEYS = ("vuln", "misconfig", "secret")
results: list[dict] = []
report: dict = {}


def emit(status: str, name: str, detail: str = "", **fields: object) -> None:
    entry = {"status": status, "check": name, "detail": detail, **fields}
    results.append(entry)
    print(f"[{status:5}] {name}: {detail}", flush=True)


def run(args: list[str], *, cwd: Path = ROOT, timeout: int = 180, data: str | None = None) -> tuple[int, str, str]:
    # Windows Python may resolve the extensionless Git Bash npm shim.
    # The native npm.cmd wrapper is executable without shell=True.
    if os.name == "nt" and args and Path(args[0]).name.lower() == "npm":
        npm_cmd = shutil.which("npm.cmd") or shutil.which("npm.exe")
        if npm_cmd:
            args = [npm_cmd, *args[1:]]
    try:
        p = subprocess.run(args, cwd=cwd, input=data, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, encoding="utf-8",
                           errors="replace", timeout=timeout, check=False)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 125, "", str(exc)


def short_error(s: str) -> str:
    # Don't expose raw scanner findings or environment values in reports.
    lines = [line for line in s.splitlines() if line.strip()]
    return f"tool reported an error ({len(lines)} diagnostic lines); run locally to investigate"


def github_latest(slug: str) -> str | None:
    uri = f"https://api.github.com/repos/{slug}/releases/latest"
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "platformlab-preflight/1.0"}
    # Use GitHub API auth if supplied but never store or echo it.
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        req = urllib.request.Request(uri, headers=headers)
        with urllib.request.urlopen(req, timeout=12) as r:
            return json.load(r).get("tag_name")
    except (OSError, ValueError, urllib.error.HTTPError):
        return None


def versions() -> None:
    local: dict[str, str | None] = {}
    for key, cmd in TOOLS.items():
        if key != "python" and not shutil.which(cmd[0]):
            local[key] = None
            emit("SKIP", f"tool/{key}", "not installed")
            continue
        code, out, err = run(cmd, timeout=15)
        if code:
            local[key] = "version unavailable"
            emit("WARN", f"tool/{key}", "version command failed")
        else:
            local[key] = (out or err).strip().splitlines()[0][:150]
            emit("PASS", f"tool/{key}", local[key])
    report["tools"] = local
    remote = {}
    for key, slug in RELEASE_REPOS.items():
        tag = github_latest(slug)
        remote[key] = tag
        emit("INFO" if tag else "WARN", f"latest/{key}",
             f"upstream release: {tag}; compare with local tool" if tag else "upstream release unavailable (network/API)")
    report["upstream_releases"] = remote


def inventory_sources() -> None:
    bases = []
    for dockerfile in sorted(ROOT.glob("app/**/Dockerfile*")):
        if not dockerfile.is_file():
            continue
        for number, line in enumerate(dockerfile.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            match = re.match(r"\s*FROM\s+(?:--\S+\s+)?(\S+)", line, re.I)
            if match:
                image = match.group(1)
                bases.append({"file": str(dockerfile.relative_to(ROOT)), "line": number, "image": image})
                emit("INFO", "docker/base", f"{dockerfile.relative_to(ROOT)}:{number} {image}")
                if image.endswith(":latest") or (":" not in image and "@" not in image):
                    emit("WARN", "docker/base-rolling", f"floating tag: {image}")
    report["docker_base_images"] = bases
    chart_pins = []
    other_revisions = []
    for yml in sorted(list((ROOT / "gitops").rglob("*.yaml")) + list((ROOT / "gitops").rglob("*.yml"))):
        current = {}
        def consume_chart() -> None:
            if all(k in current for k in ("repoURL", "chart", "targetRevision")):
                chart_pins.append({"file": str(yml.relative_to(ROOT)), **current})
        for number, line in enumerate(yml.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            m = re.match(r"\s*-?\s*(repoURL|chart|targetRevision):\s*['\"]?([^'\"#\s]+)", line)
            if not m:
                continue
            key, value = m.groups()
            if key == "repoURL":
                consume_chart()
                current = {"repoURL": value}
            else:
                current[key] = value
                if key == "targetRevision" and "chart" not in current:
                    other_revisions.append(f"{yml.relative_to(ROOT)}:{number} {line.strip()}")
        consume_chart()
    report["gitops_chart_references"] = chart_pins
    report["gitops_other_revisions"] = other_revisions
    emit("INFO", "helm/chart-inventory", f"{len(chart_pins)} chart pins and {len(other_revisions)} other revisions")
    for pin in chart_pins:
        if not shutil.which("helm") or not pin["repoURL"].startswith("https://"):
            emit("WARN", "helm/latest", f"{pin['chart']}@{pin['targetRevision']}: OCI/private repo requires manual verification")
            continue
        rc, out, err = run(["helm", "show", "chart", pin["chart"], "--repo", pin["repoURL"]], timeout=100)
        version = re.search(r"^version:\s*['\"]?([^\s'\"]+)", out, re.M) if rc == 0 else None
        latest = version.group(1) if version else None
        pin["latest_stable_chart"] = latest
        emit("INFO" if latest else "WARN", "helm/latest", f"{pin['chart']}: pinned={pin['targetRevision']}, upstream={latest or 'unavailable'}")
    actions: dict[str, str] = {}
    for wf in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        for line in wf.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"\s*-\s*uses:\s*([\w.-]+/[\w.-]+)@([\w./-]+)", line)
            if m:
                actions[m.group(1)] = m.group(2)
    for action, version in sorted(actions.items()):
        latest = github_latest(action)
        emit("INFO" if latest else "WARN", "github/action", f"{action}@{version} -> latest release {latest or 'unavailable'}")
    report["github_actions"] = [{"action": x, "current": y} for x, y in sorted(actions.items())]


def parse_json_result(out: str) -> dict | None:
    try:
        item = json.loads(out)
        return item if isinstance(item, dict) else None
    except json.JSONDecodeError:
        return None


def npm_checks() -> None:
    for package in sorted(ROOT.glob("app/**/package.json")):
        project = package.parent
        label = str(project.relative_to(ROOT))
        if not shutil.which("npm"):
            emit("SKIP", f"npm/{label}", "npm not installed")
            continue
        code, out, err = run(["npm", "outdated", "--json"], cwd=project, timeout=90)
        payload = parse_json_result(out) if out.strip() else ({} if code == 0 else None)
        if payload is not None and code in (0, 1):
            packages = [{"name": k, "current": v.get("current"), "wanted": v.get("wanted"),
                         "latest": v.get("latest")} for k, v in payload.items() if isinstance(v, dict)]
            emit("WARN" if packages else "PASS", f"npm/outdated/{label}",
                 f"{len(packages)} outdated direct dependencies")
            report.setdefault("npm_outdated", {})[label] = packages
        else:
            emit("ERROR", f"npm/outdated/{label}", short_error(err))
        if not (project / "package-lock.json").exists():
            emit("WARN", f"npm/audit/{label}", "missing package-lock.json")
            continue
        code, out, err = run(["npm", "audit", "--json", "--package-lock-only"], cwd=project, timeout=120)
        payload = parse_json_result(out)
        if payload and isinstance(payload.get("metadata", {}).get("vulnerabilities"), dict):
            counts = payload["metadata"]["vulnerabilities"]
            high = counts.get("high", 0) + counts.get("critical", 0)
            emit("FAIL" if high else "WARN" if counts.get("moderate", 0) else "PASS",
                 f"npm/audit/{label}", f"high+critical={high}, moderate={counts.get('moderate', 0)}")
            report.setdefault("npm_audit", {})[label] = counts
        else:
            emit("ERROR", f"npm/audit/{label}", short_error(err))


def findings(doc: dict) -> dict:
    counts = {"HIGH": 0, "CRITICAL": 0, "MEDIUM": 0, "LOW": 0,
              "fixable_high_critical": 0, "secrets": 0, "misconfigs_high_critical": 0}
    actionables = []
    misconfig_evidence = []
    for result in doc.get("Results") or []:
        for v in result.get("Vulnerabilities") or []:
            severity = v.get("Severity", "UNKNOWN").upper()
            if severity in counts:
                counts[severity] += 1
            if severity in ("HIGH", "CRITICAL") and v.get("FixedVersion"):
                counts["fixable_high_critical"] += 1
                if len(actionables) < 12:
                    actionables.append({"id": v.get("VulnerabilityID"), "package": v.get("PkgName"),
                                        "installed": v.get("InstalledVersion"), "fixed": v.get("FixedVersion")})
        counts["secrets"] += len(result.get("Secrets") or [])
        for item in result.get("Misconfigurations") or []:
            if str(item.get("Severity", "")).upper() in ("HIGH", "CRITICAL"):
                counts["misconfigs_high_critical"] += 1
                # Do not include CauseMetadata.Code, raw YAML, secret names/values,
                # rendered snippets, or remediation examples in shared reports.
                if len(misconfig_evidence) < 80:
                    cause = item.get("CauseMetadata") or {}
                    misconfig_evidence.append({
                        "file": str(result.get("Target", "unknown"))[:200],
                        "line": cause.get("StartLine"),
                        "severity": str(item.get("Severity", "UNKNOWN")),
                        "rule": str(item.get("AVDID") or item.get("ID") or "unknown")[:90],
                    })
    return {"counts": counts,
            "actionable_vulnerabilities": actionables,
            "misconfiguration_evidence": misconfig_evidence}


def scan_trivy(label: str, args: list[str]) -> None:
    code, out, err = run(args, timeout=600)
    parsed = parse_json_result(out)
    if not parsed:
        emit("ERROR", label, short_error(err))
        return
    data = findings(parsed)
    c = data["counts"]
    gate = c["fixable_high_critical"] or c["secrets"] or c["misconfigs_high_critical"]
    status = "FAIL" if gate else "WARN" if c["HIGH"] + c["CRITICAL"] else "PASS"
    emit(status, label, f"H={c['HIGH']} C={c['CRITICAL']} fixable-HC={c['fixable_high_critical']} secrets={c['secrets']} critical-misconfig={c['misconfigs_high_critical']}")
    report.setdefault("trivy_scans", {})[label] = data
    for item in data["misconfiguration_evidence"]:
        emit("INFO", label + "/finding",
             f"{item['severity']} {item['rule']} {item['file']}:L{item['line'] or '?'}")
    if code != 0:
        emit("ERROR", label + "/execution", f"Trivy returned exit={code}")


def hadolint_summary(out: str, err: str) -> str:
    try:
        payload = json.loads(out)
        if isinstance(payload, list):
            pieces = []
            for issue in payload[:30]:
                if not isinstance(issue, dict):
                    continue
                rule = str(issue.get("code", "unknown"))[:32]
                line = issue.get("line", "?")
                level = str(issue.get("level", "?"))[:16]
                pieces.append(f"{rule}@L{line}({level})")
            return ", ".join(pieces) or "no structured findings"
    except (ValueError, TypeError):
        pass
    codes = sorted(set(re.findall(r"\b(?:DL|SC)[0-9]{4}\b", out + err)))
    return "rules=" + (", ".join(codes) if codes else "unavailable; check local tool diagnostics")


def actionlint_summary(out: str, err: str) -> str:
    try:
        payload = json.loads(out)
        if isinstance(payload, list):
            pieces = []
            for issue in payload[:30]:
                if not isinstance(issue, dict):
                    continue
                kind = str(issue.get("kind", "unknown"))[:40]
                line = issue.get("line", "?")
                col = issue.get("column", "?")
                pieces.append(f"{kind}@L{line}:C{col}")
            return ", ".join(pieces) or "no structured findings"
    except (ValueError, TypeError):
        pass
    return f"diagnostic lines={len((out + err).splitlines())}; run actionlint locally for exact details"


def scanner_checks(build: bool, container_linters: bool, scout: bool) -> None:
    dockerfiles = [p for p in sorted(ROOT.glob("app/**/Dockerfile*")) if p.is_file()]
    if shutil.which("trivy"):
        scan_trivy("trivy/repository", ["trivy", "fs", "--scanners", "vuln,misconfig,secret",
                                           "--skip-dirs", ".local-secrets",
                                           "--skip-dirs", "app/frontend/node_modules",
                                           "--format", "json", "--exit-code", "0", "."])
    else:
        emit("FAIL", "trivy/repository", "Trivy missing: mandatory scan not performed")

    if shutil.which("hadolint"):
        for dockerfile in dockerfiles:
            rc, out, err = run(["hadolint", str(dockerfile)], timeout=45)
            emit("PASS" if rc == 0 else "FAIL", f"hadolint/{dockerfile.relative_to(ROOT)}",
                 "clean" if rc == 0 else f"exit={rc}; {hadolint_summary(out, err)}")
    elif container_linters and shutil.which("docker"):
        # Deliberately pin known release tags, rather than relying on mutable :latest.
        for dockerfile in dockerfiles:
            rc, out, err = run(["docker", "run", "--rm", "-i", "ghcr.io/hadolint/hadolint:v2.15.1"],
                               data=dockerfile.read_text(encoding="utf-8"), timeout=180)
            emit("PASS" if rc == 0 else "FAIL", f"hadolint/{dockerfile.relative_to(ROOT)}",
                 "clean (container)" if rc == 0 else f"exit={rc}; {hadolint_summary(out, err)}")
    else:
        emit("SKIP", "hadolint", "not installed; use --container-linters or install CLI")

    if shutil.which("actionlint"):
        code, out, err = run(["actionlint", "-format", "{{json .}}"], timeout=60)
        emit("PASS" if code == 0 else "FAIL", "actionlint",
             "clean" if code == 0 else actionlint_summary(out, err))
    elif container_linters and shutil.which("docker"):
        # Send workflow files via stdin, no volume mounts or Git Bash path conversion issues.
        for wf in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            code, out, err = run(["docker", "run", "--rm", "-i", "rhysd/actionlint:1.7.12",
                                  "-format", "{{json .}}", "-"],
                                 data=wf.read_text(encoding="utf-8"), timeout=180)
            emit("PASS" if code == 0 else "FAIL", f"actionlint/{wf.name}",
                 "clean (container)" if code == 0 else actionlint_summary(out, err))
    else:
        emit("SKIP", "actionlint", "not installed; use --container-linters or install CLI")

    scripts = [p for p in sorted(ROOT.rglob("*.sh")) if ".git" not in p.parts and "node_modules" not in p.parts]
    if shutil.which("shellcheck"):
        if scripts:
            code, out, err = run(["shellcheck", "-S", "warning", *map(str, scripts)], timeout=90)
            emit("PASS" if code == 0 else "FAIL", "shellcheck", "clean" if code == 0 else f"{len((out + err).splitlines())} diagnostic lines")
    else:
        emit("SKIP", "shellcheck", "not installed")

    if shutil.which("gitleaks"):
        # Do not save raw findings to disk or display potential secrets.
        code, out, err = run(["gitleaks", "dir", "--redact", "--no-banner", "--quiet", "."], timeout=240)
        emit("PASS" if code == 0 else "FAIL" if code == 1 else "ERROR", "gitleaks/worktree",
             "no leaks detected" if code == 0 else "findings or scan error; inspect locally, output deliberately withheld")
    else:
        emit("SKIP", "gitleaks", "not installed")

    if shutil.which("semgrep"):
        # Avoid network-dependent rule auto-download and external code upload in preflight.
        emit("INFO", "semgrep", "installed; run separately with reviewed local rules")
    else:
        emit("SKIP", "semgrep", "not installed")

    if not build:
        emit("INFO", "docker/build", "skipped; supply --build for fresh --pull images and Trivy image scans")
        return
    if not shutil.which("docker"):
        emit("FAIL", "docker/build", "Docker unavailable")
        return
    for component in ("backend", "frontend"):
        context = ROOT / "app" / component
        if not (context / "Dockerfile").exists():
            emit("SKIP", f"docker/build/{component}", "no Dockerfile")
            continue
        image_ref = f"platformlab-{component}:preflight"
        code, out, err = run(["docker", "build", "--pull", "-t", image_ref, str(context)], timeout=900)
        if code:
            emit("FAIL", f"docker/build/{component}", f"build returned {code}; inspect local Docker output")
            continue
        emit("PASS", f"docker/build/{component}", f"built {image_ref} (local only)")
        if shutil.which("trivy"):
            scan_trivy(f"trivy/image/{component}", ["trivy", "image", "--scanners", "vuln,secret",
                                                       "--format", "json", "--exit-code", "0", image_ref])
        else:
            emit("FAIL", f"trivy/image/{component}", "Trivy missing")
        if scout:
            code, out, err = run(["docker", "scout", "recommendations", image_ref], timeout=180)
            if code == 0:
                # Store non-secret update guidance locally, never publish it from the script.
                excerpt = re.sub(r"\x1b\[[0-9;]*m", "", out)[:6000]
                report.setdefault("docker_scout_recommendations", {})[component] = excerpt
                emit("INFO", f"scout/{component}", "base image update recommendations collected in local JSON report")
            else:
                emit("WARN", f"scout/{component}", "Docker Scout unavailable or not authenticated")


def save_reports() -> None:
    dest = ROOT.parent / "_local-reports" / "k8s-platform-lab"
    dest.mkdir(parents=True, exist_ok=True)
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    json_out = dest / f"preflight-{now}.json"
    md_out = dest / f"preflight-{now}.md"
    report.update({"created_utc": now, "repo": str(ROOT), "checks": results})
    json_out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    lines = ["# PlatformLab dependency and security preflight", "", f"Date UTC: {now}",
             "", "Reports contain only summaries; never commit raw scanner output or tokens.", "",
             "| Result | Check | Summary |", "|---|---|---|"]
    for item in results:
        detail = str(item["detail"]).replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {item['status']} | `{item['check']}` | {detail} |")
    lines += ["", "## Next steps", "", "Review FAIL/ERROR entries first; for outdated dependencies create a separate PR, test and rescan.",
              "Never change versions in production solely because the number is newer."]
    md_out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nReports (outside Git repo):\n  {md_out}\n  {json_out}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="build both local images with --pull and scan")
    parser.add_argument("--container-linters", action="store_true", help="use pinned Docker images if hadolint/actionlint absent")
    parser.add_argument("--scout", action="store_true", help="optional Docker Scout base refresh recommendations")
    parser.add_argument("--triage", action="store_true", help="fast npm, Trivy filesystem and lint checks; skip network version inventory and Docker builds")
    args = parser.parse_args()
    if not (ROOT / "helm/platformlab/Chart.yaml").is_file():
        print("ERROR: Expected PlatformLab repository layout not found", file=sys.stderr)
        return 2
    print("=== PlatformLab release preflight: no push, no deploy, no automatic upgrades ===")
    try:
        if not args.triage:
            versions()
            inventory_sources()
        npm_checks()
        scanner_checks(args.build and not args.triage, args.container_linters, args.scout and not args.triage)
    finally:
        save_reports()
    failed = [v for v in results if v["status"] in ("FAIL", "ERROR")]
    if failed:
        print(f"\nPREFLIGHT BLOCKED: {len(failed)} failing checks. Release not advised.")
        return 1
    print("\nPREFLIGHT COMPLETE: no blocking findings in executed checks. Review WARN/SKIP coverage.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
