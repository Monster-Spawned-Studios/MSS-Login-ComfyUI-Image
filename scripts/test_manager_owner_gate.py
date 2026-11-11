#!/usr/bin/env python3
"""Owner-only ComfyUI-Manager guard tests. Box or CI only, never on a deploy host.

Needs: git, uv, and a Python with aiohttp, pydantic, pyyaml, requests, tqdm,
packaging, huggingface_hub plus config/comfyui-manager-requirements.lock.

  MSS_MANAGER_SRC=<git clone of Comfy-Org/ComfyUI-Manager>
  MSS_LOGIN_SRC=<git clone of ComfyUI-MSS-Login>
  python scripts/test_manager_owner_gate.py

What it does:
1. Exports the pinned Manager commit and MSS-Login commit (git archive), checks
   the Manager tree hash against the Dockerfile, and applies the image patches
   with git apply --check then git apply, the same order as the Dockerfile.
2. Enumerates every Manager route from the patched source and checks the
   gate covers each one and that both OWNER_READ_ROUTES lists match.
3. Builds the patched wheel, installs it into a temp target, runs the real
   comfyui_manager.prestartup() and start() against stub ComfyUI modules, and
   checks every registered Manager route is wrapped and that prestartup ran
   no subprocess.
4. Serves those real routes behind the MSS-Login gate (ComfyUI's /api mirror
   included) and sends raw HTTP requests: every route and path variant as
   guest, admin, user, unauthenticated, a raising owner check, and the owner;
   owner install, git-url, pip, update, restore, switch-version and reboot;
   and the same routes with the MSS-Login gate missing.
5. Checks forced config: apply_forced_config on a tampered dict, the
   entrypoint's forced list matches FORCED_CONFIG, and patched read_config()
   ignores a tampered config.ini.
"""

from __future__ import annotations

import ast
import asyncio
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILURES: list[str] = []
CHECKS = 0


def check(cond: bool, label: str) -> None:
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILURES.append(label)
        print(f"FAIL: {label}", file=sys.stderr)


def dockerfile_arg(name: str) -> str:
    text = open(os.path.join(ROOT, "Dockerfile"), encoding="utf-8").read()
    m = re.search(rf"^ARG {name}=(\S+)$", text, re.M)
    if not m:
        raise SystemExit(f"Dockerfile ARG {name} not found")
    return m.group(1)


def export_tree(src: str, ref: str, dest: str) -> None:
    os.makedirs(dest)
    archive = subprocess.run(["git", "-C", src, "archive", ref], check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", dest], input=archive, check=True)


def apply_patch(tree: str, patch: str) -> None:
    subprocess.run(["git", "apply", "--check", patch], cwd=tree, check=True)
    subprocess.run(["git", "apply", patch], cwd=tree, check=True)


def load_module(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ROUTE_RE = re.compile(r"routes\.(get|post|put|delete|patch|route|view)\(\s*['\"]([^'\"]+)['\"]")


def enumerate_routes(pkg: str) -> dict[str, set[tuple[str, str]]]:
    out = {}
    for rel in ("glob/manager_server.py", "glob/share_3rdparty.py", "legacy/manager_server.py", "legacy/share_3rdparty.py"):
        text = open(os.path.join(pkg, rel), encoding="utf-8").read()
        out[rel] = {(m.group(1).upper(), m.group(2)) for m in ROUTE_RE.finditer(text)}
    return out


def variants(path: str) -> list[str]:
    segs = path.split("/")
    first = segs[1] if len(segs) > 1 else ""
    out = [
        path,
        path + "/",
        "/api" + path,
        "/api" + path + "/",
        "/api/api" + path,
        path.upper(),
        "/API" + path,
        "/Api" + path.replace("manager", "Manager"),
        "//" + path.lstrip("/"),
        "/api//" + path.lstrip("/"),
        path.replace("/", "%2F", 2).replace("%2F", "/", 1),
        path.replace("/", "%2f", 2).replace("%2f", "/", 1),
        "/" + path.lstrip("/").replace("/", "%252F", 1),
        "/x/.." + path,
        "/." + path,
        "/api/x/.." + path,
        path + "?a=1",
        path + "/.",
        "/%61pi" + path,
        path.replace(first, "".join(f"%{ord(c):02x}" for c in first), 1) if first else path,
    ]
    seen, uniq = set(), []
    for v in out:
        if v not in seen:
            seen.add(v)
            uniq.append(v)
    return uniq


async def raw_request(port: int, method: str, target: str, headers: dict[str, str], body: bytes = b"") -> tuple[int, str]:
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    lines = [f"{method} {target} HTTP/1.1", "Host: 127.0.0.1", "Connection: close", f"Content-Length: {len(body)}"]
    lines += [f"{k}: {v}" for k, v in headers.items()]
    writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body)
    await writer.drain()
    data = await reader.read()
    writer.close()
    head, _, rest = data.partition(b"\r\n\r\n")
    try:
        status = int(head.split(b" ", 2)[1])
    except Exception:
        status = -1
    return status, rest.decode("utf-8", "replace")


def main() -> int:
    mgr_src = os.environ.get("MSS_MANAGER_SRC")
    ml_src = os.environ.get("MSS_LOGIN_SRC")
    if not mgr_src or not ml_src:
        print("Set MSS_MANAGER_SRC and MSS_LOGIN_SRC to git clones.", file=sys.stderr)
        return 2
    ref = dockerfile_arg("COMFYUI_MANAGER_REF")
    tree = dockerfile_arg("COMFYUI_MANAGER_TREE")
    version = dockerfile_arg("COMFYUI_MANAGER_VERSION")
    ml_ref = dockerfile_arg("MSS_LOGIN_REF")
    work = tempfile.mkdtemp(prefix="mss-mgr-test-")

    # 1. trees and patches
    got_tree = subprocess.run(["git", "-C", mgr_src, "rev-parse", f"{ref}^{{tree}}"], capture_output=True, text=True).stdout.strip()
    check(got_tree == tree, f"Manager tree {got_tree} == Dockerfile {tree}")
    tag_commit = subprocess.run(["git", "-C", mgr_src, "rev-parse", f"refs/tags/{version}^{{commit}}"], capture_output=True, text=True).stdout.strip()
    check(tag_commit == ref, f"Manager tag {version} -> {tag_commit} == {ref}")
    mgr = os.path.join(work, "manager")
    export_tree(mgr_src, ref, mgr)
    apply_patch(mgr, os.path.join(ROOT, "patches/comfyui-manager-mss-lockdown.patch"))
    ml = os.path.join(work, "mss-login")
    export_tree(ml_src, ml_ref, ml)
    apply_patch(ml, os.path.join(ROOT, "patches/mss-login-no-inplace-update.patch"))
    apply_patch(ml, os.path.join(ROOT, "patches/mss-login-manager-owner-gate.patch"))
    pkg = os.path.join(mgr, "comfyui_manager")
    for rel in ("__init__.py", "mss_lockdown.py", "prestartup_script.py", "glob/manager_core.py", "legacy/manager_core.py"):
        compile(open(os.path.join(pkg, rel), encoding="utf-8").read(), rel, "exec")
    compile(open(os.path.join(ml, "__init__.py"), encoding="utf-8").read(), "mss __init__", "exec")

    lock = load_module("mss_lockdown_standalone", os.path.join(pkg, "mss_lockdown.py"))
    gate = load_module("manager_owner_gate_standalone", os.path.join(ml, "utils/manager_owner_gate.py"))

    # 2. route enumeration and policy parity
    routes = enumerate_routes(pkg)
    all_routes = set().union(*routes.values())
    glob_routes = routes["glob/manager_server.py"] | routes["glob/share_3rdparty.py"]
    print(f"enumerated {len(all_routes)} distinct Manager routes ({len(glob_routes)} in glob/)")
    check(len(glob_routes) >= 41, "glob route count")
    for method, path in sorted(all_routes):
        check(any(gate.is_manager_path(p) for p in gate.canonical_paths(path)), f"gate covers {method} {path}")
        check(any(lock.is_manager_path(p) for p in lock.canonical_paths(path)), f"lockdown covers {method} {path}")
    check(lock.OWNER_READ_ROUTES == gate.OWNER_READ_ROUTES, "OWNER_READ_ROUTES match in both patches")
    check(lock.MANAGER_SEGMENTS == gate.MANAGER_SEGMENTS, "MANAGER_SEGMENTS match in both patches")
    check(lock.OWNER_READ_ROUTES <= glob_routes, "every owner route exists in glob/")
    owner_posts = {p for m, p in lock.OWNER_READ_ROUTES if m == "POST"}
    check(owner_posts == {"/v2/customnode/import_fail_info", "/v2/customnode/import_fail_info_bulk", "/v2/manager/queue/reset"}, "owner POST list")
    mutating = [
        "/v2/manager/queue/task", "/v2/manager/queue/batch", "/v2/manager/queue/install_model",
        "/v2/manager/queue/update_all", "/v2/manager/queue/update_comfyui", "/v2/manager/queue/start",
        "/v2/customnode/install/git_url", "/v2/customnode/install/pip", "/v2/snapshot/restore",
        "/v2/snapshot/save", "/v2/snapshot/remove", "/v2/comfyui_manager/comfyui_switch_version",
        "/v2/manager/reboot", "/v2/manager/db_mode", "/v2/manager/policy/update", "/v2/manager/channel_url_list",
    ]
    for path in mutating:
        check(not lock.owner_route_allowed("POST", path), f"owner POST {path} refused by policy")
    for core_path in ("/prompt", "/api/prompt", "/login", "/mss-login/api/me", "/view", "/api/userdata/x", "/ws",
                      "/extensions/core/x.js", "/models", "/api/v2/userdata"):
        check(not any(gate.is_manager_path(p) for p in gate.canonical_paths(core_path)), f"core path {core_path} not gated")

    # AST checks on the patched trees
    init_tree = ast.parse(open(os.path.join(pkg, "__init__.py"), encoding="utf-8").read())
    pre = next(n for n in init_tree.body if isinstance(n, ast.FunctionDef) and n.name == "prestartup")
    check("prestartup_script" not in ast.dump(pre), "prestartup() does not import prestartup_script")
    ps_tree = ast.parse(open(os.path.join(pkg, "prestartup_script.py"), encoding="utf-8").read())
    check(isinstance(ps_tree.body[0], ast.Raise), "prestartup_script.py raises on import")
    for rel in ("glob/manager_core.py", "legacy/manager_core.py"):
        t = ast.parse(open(os.path.join(pkg, rel), encoding="utf-8").read())
        rc = next(n for n in t.body if isinstance(n, ast.FunctionDef) and n.name == "read_config")
        dump = ast.dump(rc)
        check("apply_forced_config" in dump and "_upstream_read_config" in dump, f"{rel} read_config forces config")
    ml_init = open(os.path.join(ml, "__init__.py"), encoding="utf-8").read()
    i_gate = ml_init.find("app.middlewares.append(create_manager_owner_gate_middleware(")
    i_guard = ml_init.find("create_remote_api_guard_middleware(\n")
    i_jwt = ml_init.find("jwt_auth.create_jwt_middleware(")
    check(0 < i_gate < i_guard and i_gate < i_jwt, "MSS-Login gate registered before remote guard and JWT middleware")
    check("from .routes.admin import is_owner" in ml_init[max(0, i_gate - 400): i_gate], "gate uses MSS-Login routes.admin.is_owner")

    # 5a. forced config parity and tamper
    tampered = {"security_level": "weak", "network_mode": "public", "allow_pip_install": True, "allow_git_url_install": True,
                "use_uv": True, "file_logging": True, "bypass_ssl": True, "channel_url": "http://evil.example", "extra": 1}
    forced = lock.apply_forced_config(tampered)
    for k, v in lock.FORCED_CONFIG.items():
        check(forced[k] == v, f"apply_forced_config {k}")
    entry = open(os.path.join(ROOT, "entrypoint.sh"), encoding="utf-8").read()
    block = entry[entry.index("force_comfyui_manager_config() {"):]
    block = block[: block.index("\nPY\n")]
    ent_pairs = dict(re.findall(r'\("([a-z_]+)", "([^"]*)"\)', block))
    want = {k: (str(v).lower() if isinstance(v, bool) else v) for k, v in lock.FORCED_CONFIG.items()}
    check(ent_pairs == want, f"entrypoint forced config == FORCED_CONFIG ({sorted(set(ent_pairs) ^ set(want))})")

    # 3. wheel, real prestartup/start with stubs
    whl_dir = os.path.join(work, "whl")
    subprocess.run(["uv", "build", "-q", "--wheel", "--out-dir", whl_dir, mgr], check=True)
    whl = [f for f in os.listdir(whl_dir) if f.endswith(".whl")]
    check(len(whl) == 1, "one wheel built")
    site = os.path.join(work, "site")
    subprocess.run(["uv", "pip", "install", "-q", "--python", sys.executable, "--target", site, "--no-deps",
                    os.path.join(whl_dir, whl[0])], check=True)
    check(os.path.isfile(os.path.join(site, "comfyui_manager", "mss_lockdown.py")), "wheel carries mss_lockdown.py")

    comfy_root = os.path.join(work, "comfy")
    for d in ("user", "custom_nodes", "models"):
        os.makedirs(os.path.join(comfy_root, d))
    mgr_user = os.path.join(comfy_root, "user", "__manager")
    os.makedirs(os.path.join(mgr_user, "startup-scripts"))
    with open(os.path.join(mgr_user, "config.ini"), "w") as fh:
        fh.write("[default]\nsecurity_level = weak\nnetwork_mode = public\nallow_pip_install = true\n"
                 "allow_git_url_install = true\nuse_uv = true\nfile_logging = true\nbypass_ssl = true\n"
                 "channel_url = http://evil.example\ndb_mode = remote\n")
    marker = os.path.join(work, "PWNED")
    with open(os.path.join(mgr_user, "startup-scripts", "install-scripts.txt"), "w") as fh:
        fh.write(f"['{comfy_root}', '#LAZY-INSTALL-SCRIPT', '{sys.executable}', '-c', 'open(\"{marker}\",\"w\")']\n")
    with open(os.path.join(mgr_user, "startup-scripts", "restore-snapshot.json"), "w") as fh:
        fh.write("{}")

    sys.path.insert(0, site)
    from aiohttp import web

    comfy = types.ModuleType("comfy")
    cli = types.ModuleType("comfy.cli_args")
    cli.args = types.SimpleNamespace(enable_manager=True, enable_manager_legacy_ui=False, listen="0.0.0.0", port=9008,
                                     disable_manager_ui=False)
    comfy.cli_args = cli
    sys.modules["comfy"] = comfy
    sys.modules["comfy.cli_args"] = cli
    fp = types.ModuleType("folder_paths")
    fp.user_directory = os.path.join(comfy_root, "user")
    fp.base_path = comfy_root
    fp.models_dir = os.path.join(comfy_root, "models")
    fp.folder_names_and_paths = {}
    fp.get_system_user_directory = lambda name="system": os.path.join(fp.user_directory, "__" + name)
    fp.get_folder_paths = lambda k: [os.path.join(comfy_root, k)]
    sys.modules["folder_paths"] = fp

    class PromptServer:
        instance = None

        def __init__(self):
            self.routes = web.RouteTableDef()
            self.client_id = None
            self.loop = None

        def send_sync(self, *a, **k):
            pass

    PromptServer.instance = PromptServer()
    srv = types.ModuleType("server")
    srv.PromptServer = PromptServer
    sys.modules["server"] = srv
    nodes = types.ModuleType("nodes")
    nodes.EXTENSION_WEB_DIRS = {}
    nodes.NODE_CLASS_MAPPINGS = {}
    sys.modules["nodes"] = nodes
    import __main__

    __main__.__file__ = os.path.join(comfy_root, "main.py")
    os.environ["COMFYUI_PATH"] = comfy_root

    spawned: list[str] = []
    real_popen, real_system = subprocess.Popen, os.system

    class SpyPopen(real_popen):
        def __init__(self, *a, **k):
            spawned.append(repr(a[0] if a else k.get("args")))
            super().__init__(*a, **k)

    def spy_system(cmd):
        spawned.append(repr(cmd))
        return real_system(cmd)

    subprocess.Popen = SpyPopen
    os.system = spy_system
    import comfyui_manager

    check(comfyui_manager.__file__.startswith(site), "comfyui_manager imported from the target site")
    comfyui_manager.prestartup()
    check(spawned == [], f"prestartup spawned nothing ({spawned})")
    check(not os.path.exists(marker), "install-scripts.txt was not executed")
    try:
        import comfyui_manager.prestartup_script  # noqa: F401

        check(False, "prestartup_script import raises")
    except ImportError:
        check(True, "prestartup_script import raises")
    cli.args.enable_manager_legacy_ui = True
    try:
        comfyui_manager.start()
        check(False, "legacy UI start refused")
    except RuntimeError:
        check(True, "legacy UI start refused")
    cli.args.enable_manager_legacy_ui = False
    comfyui_manager.start()
    from comfyui_manager import mss_lockdown as live_lock
    from comfyui_manager.glob import manager_core as core

    cfg = core.read_config()
    for k, v in live_lock.FORCED_CONFIG.items():
        check(cfg.get(k) == v, f"patched read_config ignores tampered config.ini: {k}={cfg.get(k)!r}")
    from comfyui_manager.common import manager_util

    check(manager_util.use_uv is False and manager_util.bypass_ssl is False, "manager_util flags forced off")
    registered = [r for r in PromptServer.instance.routes if isinstance(r, web.RouteDef)]
    reg_set = {(r.method, r.path) for r in registered}
    check(reg_set == glob_routes, f"registered routes == enumerated glob routes ({len(reg_set)} vs {len(glob_routes)})")
    for r in registered:
        check(getattr(r.handler, live_lock.LOCK_MARK, False), f"{r.method} {r.path} is wrapped")
    print(f"real start(): {len(registered)} Manager routes registered, all wrapped")

    # 4. HTTP
    base_routes = list(PromptServer.instance.routes)

    async def ok(request):
        return web.Response(text="core-ok")

    async def legacy_js(request):
        return web.Response(text="legacy-js")

    def build_app(with_gate: bool, owner_fn):
        table = web.RouteTableDef()
        for r in base_routes:
            table.route(r.method, r.path)(r.handler, **r.kwargs)
        table.get("/prompt")(ok)
        table.get("/login")(ok)
        table.get("/extensions/comfyui-manager-legacy/comfyui-manager.js")(legacy_js)
        table.get("/extensions/ComfyUI-Manager/js/comfyui-manager.js")(legacy_js)
        mws = [gate.create_manager_owner_gate_middleware(owner_fn)] if with_gate else []
        app = web.Application(middlewares=mws)
        api = web.RouteTableDef()
        for r in table:
            api.route(r.method, "/api" + r.path)(r.handler, **r.kwargs)
        app.add_routes(api)
        app.add_routes(table)
        return app

    def owner_fn(request):
        who = request.headers.get("X-Test-User", "")
        if who == "boom":
            raise RuntimeError("owner lookup failed")
        if who == "truthy":
            return 1
        return who == "owner"

    deny_texts = ("ComfyUI-Manager is available to the MSS-Login owner only.",
                  "This ComfyUI-Manager action is disabled in this image.")
    nonowners = ["", "guest", "admin", "user", "boom", "truthy"]
    results = {"nonowner": 0, "owner_blocked": 0, "owner_allowed": 0, "nogate": 0, "status": {}}

    async def run_http():
        runners = []
        ports = {}
        for name, with_gate in (("gate", True), ("nogate", False)):
            runner = web.AppRunner(build_app(with_gate, owner_fn))
            await runner.setup()
            site_ = web.TCPSite(runner, "127.0.0.1", 0)
            await site_.start()
            ports[name] = site_._server.sockets[0].getsockname()[1]
            runners.append(runner)
        gp, np_ = ports["gate"], ports["nogate"]
        targets = sorted(all_routes | {("GET", "/extensions/comfyui-manager-legacy/comfyui-manager.js"),
                                       ("GET", "/extensions/ComfyUI-Manager/js/comfyui-manager.js")})
        for method, template in targets:
            path = template.replace("{node_name}", "comfyui-impact-pack")
            body = b'{"url": "https://github.com/evil/node", "id": "x"}' if method == "POST" else b""
            hdr = {"Content-Type": "application/json"} if method == "POST" else {}
            for v in variants(path):
                for who in nonowners:
                    h = dict(hdr)
                    if who:
                        h["X-Test-User"] = who
                    h["mss_login_manager_owner"] = "true"
                    st, txt = await raw_request(gp, method, v, h, body)
                    results["status"][st] = results["status"].get(st, 0) + 1
                    good = (st == 403 and txt.startswith(deny_texts)) or st == 400
                    check(good, f"non-owner [{who or 'unauth'}] {method} {v} -> {st} {txt[:60]!r}")
                    results["nonowner"] += 1
                h = dict(hdr)
                h["X-Test-User"] = "owner"
                st, txt = await raw_request(gp, method, v, h, body)
                allowed_route = lock.owner_route_allowed(method, template)
                if not allowed_route:
                    good = (st == 403 and txt.startswith(deny_texts)) or st == 400
                    check(good, f"owner blocked {method} {v} -> {st} {txt[:60]!r}")
                    results["owner_blocked"] += 1
                elif v in (path, "/api" + path):
                    check(st != 403, f"owner allowed {method} {v} -> {st} {txt[:80]!r}")
                    results["owner_allowed"] += 1
                st, txt = await raw_request(np_, method, v, h, body)
                if (method, template) in reg_set and v in (path, "/api" + path):
                    check(st == 403 and txt.startswith(deny_texts), f"no MSS-Login gate, owner {method} {v} -> {st}")
                    results["nogate"] += 1
            if method == "GET":
                st, _ = await raw_request(gp, "HEAD", path, {"X-Test-User": "guest"})
                check(st == 403, f"guest HEAD {path} -> {st}")
        for p in ("/prompt", "/api/prompt", "/login"):
            st, txt = await raw_request(gp, "GET", p, {})
            check(st == 200 and txt == "core-ok", f"core route {p} unaffected -> {st}")
        for r in runners:
            await r.cleanup()

    spawned.clear()
    asyncio.run(run_http())
    # Owner reads such as snapshot/get_current run "pip --version" and
    # "uv pip freeze". Nothing may install, uninstall, or touch git remotes.
    bad_spawn = [s for s in spawned if re.search(r"\b(install|uninstall|clone|pull|fetch|checkout|reset|download|restore-snapshot)\b", s)]
    check(bad_spawn == [], f"no install or git write spawned during HTTP tests ({bad_spawn[:3]})")
    for s in sorted(set(spawned)):
        print(f"  subprocess during owner reads: {s}")
    check(not os.path.exists(marker), "install-scripts marker still absent")
    subprocess.Popen, os.system = real_popen, real_system
    print(f"HTTP: {results['nonowner']} non-owner, {results['owner_blocked']} owner-blocked, "
          f"{results['owner_allowed']} owner-allowed, {results['nogate']} no-gate requests; "
          f"non-owner statuses {results['status']}; subprocesses during HTTP: {len(spawned)}")

    shutil.rmtree(work, ignore_errors=True)
    print(f"{CHECKS} checks, {len(FAILURES)} failures")
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(1 if FAILURES else 0)


if __name__ == "__main__":
    sys.exit(main())
