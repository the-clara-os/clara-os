#!/usr/bin/env python3
"""Commit the working tree to its branch on GitHub, signed by GitHub.

Commits in this repository must be signed, and the local key needs Julio at
the keyboard. GitHub signs the commits made through its API, so this sends
every change `git status` lists to the GraphQL createCommitOnBranch
mutation, after creating the branch on GitHub if it is not there, and then
moves the local branch onto the new commit.

usage: python3 tools/api-commit.py <message-file> [--dry-run]

Run it on the branch to commit to, never on main. The first line of the
message file is the headline. Needs `gh`, logged in. The mutation cannot set
the executable bit, so a new script arrives as 100644.
"""
import base64
import json
import os
import subprocess
import sys


def run(*cmd, stdin=None):
    res = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"{' '.join(cmd[:4])}: {(res.stderr or res.stdout).strip()}")
    return res.stdout


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    headline, _, body = open(sys.argv[1]).read().strip().partition("\n")
    os.chdir(run("git", "rev-parse", "--show-toplevel").strip())
    branch = run("git", "rev-parse", "--abbrev-ref", "HEAD").strip()
    if branch in ("main", "HEAD"):
        sys.exit("switch to a julio/<topic> branch first")
    head = run("git", "rev-parse", "HEAD").strip()
    repo = run("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()

    # With -z an entry is "XY path", and a rename is followed by the old path.
    additions, deletions = [], []
    entries = run("git", "status", "--porcelain", "--untracked-files=all", "-z").split("\0")
    while entries:
        entry = entries.pop(0)
        if not entry:
            continue
        code, path = entry[:2], entry[3:]
        if code[0] in "RC":
            old = entries.pop(0)
            if code[0] == "R":
                deletions.append({"path": old})
        if os.path.exists(path):
            with open(path, "rb") as f:
                additions.append({"path": path, "contents": base64.b64encode(f.read()).decode()})
        else:
            deletions.append({"path": path})
    for sign, changes in (("+", additions), ("-", deletions)):
        for change in changes:
            print(sign, change["path"])
    if not additions and not deletions:
        sys.exit("nothing to commit")
    if "--dry-run" in sys.argv:
        return

    exists = subprocess.run(["gh", "api", f"repos/{repo}/git/ref/heads/{branch}"], capture_output=True)
    if exists.returncode != 0:
        run("gh", "api", f"repos/{repo}/git/refs", "-f", f"ref=refs/heads/{branch}", "-f", f"sha={head}")
    query = "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }"
    variables = {"input": {
        "branch": {"repositoryNameWithOwner": repo, "branchName": branch},
        "expectedHeadOid": head,
        "message": {"headline": headline.strip(), "body": body.strip() + "\n"},
        "fileChanges": {"additions": additions, "deletions": deletions},
    }}
    out = json.loads(run("gh", "api", "graphql", "--input", "-", stdin=json.dumps({"query": query, "variables": variables})))
    if out.get("errors"):
        sys.exit(json.dumps(out["errors"], indent=1))
    commit = out["data"]["createCommitOnBranch"]["commit"]

    # The new commit holds exactly the working tree, so moving the branch
    # and the index onto it leaves nothing modified.
    run("git", "fetch", "--quiet", "origin", branch)
    run("git", "reset", "--quiet", commit["oid"])
    run("git", "branch", "--quiet", f"--set-upstream-to=origin/{branch}")
    print(commit["oid"], commit["url"])
    print(run("git", "status", "--short", "--branch").strip())


if __name__ == "__main__":
    main()
