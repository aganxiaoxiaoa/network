# -*- coding: utf-8 -*-
"""Compose Clash Verge's profile-enhancement chain into one config and validate it
with mihomo's own -t. Mirrors Verge's merge semantics closely enough to catch the
class of bug that only mihomo can find (groups referencing nonexistent nodes).

Usage: python _compose_validate.py <remote-uid>
"""
import io, os, sys, shutil, subprocess
import yaml

DATA = r"C:\Users\Administrator\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev"
PROF = os.path.join(DATA, "profiles")
MIHOMO = r"D:\软件\VPN\代理\verge-mihomo.exe"
TESTDIR = r"D:\OpenClaw-AgentOS\workspace\_mihomo_validate"


def load(path):
    with io.open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def deep_merge(base, patch):
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def apply_seq(cfg, key, override):
    """prepend/append/delete against cfg[key]."""
    cur = list(cfg.get(key) or [])
    for item in (override.get("delete") or []):
        cur = [x for x in cur
               if not ((isinstance(x, dict) and x.get("name") == item) or x == item)]
    cur = list(override.get("prepend") or []) + cur + list(override.get("append") or [])
    cfg[key] = cur


def apply_merge(cfg, mrg):
    """Verge merge file: plain keys deep-merge; prepend-/append-/delete- are directives."""
    SEQ = {"proxies": "proxies", "proxy-groups": "proxy-groups", "rules": "rules"}
    plain = {}
    for k, v in mrg.items():
        hit = False
        for pfx in ("prepend-", "append-", "delete-"):
            if k.startswith(pfx):
                target = SEQ.get(k[len(pfx):])
                if target:
                    apply_seq(cfg, target, {pfx[:-1]: v})
                hit = True
                break
        if not hit:
            plain[k] = v
    deep_merge(cfg, plain)


def main():
    uid = sys.argv[1]
    pf = load(os.path.join(DATA, "profiles.yaml"))
    item = next(i for i in pf["items"] if i.get("uid") == uid)
    opt = item.get("option") or {}
    print("profile: %s (uid=%s)" % (item.get("name"), uid))

    cfg = load(os.path.join(PROF, uid + ".yaml"))
    print("base:      proxies=%d groups=%d rules=%d" % (
        len(cfg.get("proxies") or []), len(cfg.get("proxy-groups") or []),
        len(cfg.get("rules") or [])))

    # global merge first, then the per-profile chain
    gm = os.path.join(PROF, "Merge.yaml")
    if os.path.exists(gm):
        apply_merge(cfg, load(gm))
    if opt.get("merge"):
        apply_merge(cfg, load(os.path.join(PROF, opt["merge"] + ".yaml")))
    if opt.get("proxies"):
        apply_seq(cfg, "proxies", load(os.path.join(PROF, opt["proxies"] + ".yaml")))
    if opt.get("groups"):
        apply_seq(cfg, "proxy-groups", load(os.path.join(PROF, opt["groups"] + ".yaml")))
    if opt.get("rules"):
        # STAGE_RULES lets us validate an edited rules override *before* dropping it
        # in place, so an invalid file never reaches the live profile.
        staged = os.environ.get("STAGE_RULES")
        rules_path = staged or os.path.join(PROF, opt["rules"] + ".yaml")
        if staged:
            print("using staged rules: %s" % staged)
        apply_seq(cfg, "rules", load(rules_path))

    print("composed:  proxies=%d groups=%d rules=%d" % (
        len(cfg.get("proxies") or []), len(cfg.get("proxy-groups") or []),
        len(cfg.get("rules") or [])))

    # --- isolate from the production instance ---
    cfg.pop("listeners", None)          # the 7898 bridge would collide
    cfg["mixed-port"] = 27897
    cfg.pop("socks-port", None)
    cfg.pop("port", None)
    cfg["external-controller"] = "127.0.0.1:29097"
    cfg["log-level"] = "warning"

    if os.path.isdir(TESTDIR):
        shutil.rmtree(TESTDIR, ignore_errors=True)
    os.makedirs(TESTDIR, exist_ok=True)
    for asset in ("Country.mmdb", "geoip.dat", "geosite.dat", "geoip.metadb"):
        src = os.path.join(DATA, asset)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(TESTDIR, asset))

    out = os.path.join(TESTDIR, "config.yaml")
    with io.open(out, "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=False)

    # --- referential check first, so failures read clearly ---
    names = set(p["name"] for p in (cfg.get("proxies") or []) if isinstance(p, dict))
    names |= set(g["name"] for g in (cfg.get("proxy-groups") or []) if isinstance(g, dict))
    names |= {"DIRECT", "REJECT", "PASS", "REJECT-DROP", "COMPATIBLE", "GLOBAL"}
    for pv in (cfg.get("proxy-providers") or {}):
        names.add(pv)
    dangling = []
    for g in (cfg.get("proxy-groups") or []):
        for m in (g.get("proxies") or []):
            if m not in names:
                dangling.append("%s -> %s" % (g["name"], m))
    bad_rules = []
    for r in (cfg.get("rules") or []):
        parts = str(r).split(",")
        tgt = parts[-1].strip() if len(parts) >= 2 else None
        if tgt in ("no-resolve", "src", None):
            tgt = parts[-2].strip() if len(parts) >= 3 else None
        if tgt and tgt not in names:
            bad_rules.append(str(r))
    print("dangling group members: %d" % len(dangling))
    for d in dangling:
        print("   " + d)
    print("rules with unknown target: %d" % len(bad_rules))
    for b in bad_rules[:10]:
        print("   " + b)

    print("--- verge-mihomo -t ---")
    r = subprocess.run([MIHOMO, "-d", TESTDIR, "-t"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    print((r.stdout or "") + (r.stderr or ""))
    print("exit=%d" % r.returncode)
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
