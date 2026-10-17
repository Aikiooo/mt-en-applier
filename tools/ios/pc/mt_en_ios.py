"""mitmproxy addon: the iOS English patch, served from a PC on the same network.

The iPhone connects to this PC with the free WireGuard app (mitmproxy's WireGuard mode).
Only the game's download host is intercepted (allow_hosts in Installer-iOS.ps1); every
other connection passes through untouched. When the game asks the CDN for a bundle the
patch covers, the English copy from the ios-latest release is served instead (downloaded
once, MD5-checked against ios-manifest.json, kept in <home>/cache). Unity checks the
catalog CRC, which the patched files keep, and caches them under the stock hash: the
English files stay after the tunnel is switched off, until a game update.

Pages:
  http://127.0.0.1:<status_port>/   on the PC: the WireGuard QR code and live progress
  http://10.0.0.53/                 on the iPhone, through the tunnel: the certificate and a
                                    check that it is trusted
"""
import asyncio
import hashlib
import http.server as httpserver
import json
import logging
import os
import re
import threading
import time
import urllib.request
import webbrowser

from mitmproxy import ctx, http

CDN_HOST = "mushokutensei-coe-jp.akamaized.net"
PHONE_HOST = "10.0.0.53"
CHECK_PATH = "/__mt_en_check.gif"
GIF = bytes.fromhex("47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b")
BUNDLE = re.compile(r"/AssetBundle/iOS/([^/?]+\.bundle)$")
log = logging.getLogger("mt_en_ios")


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.manifest = {}          # CDN file name -> out_md5
        self.client_build = ""
        self.wg_conf = ""
        self.release_error = ""
        self.tunnel_seen = 0.0      # last traffic through the tunnel
        self.cert_ok = 0.0          # last successful TLS check from the phone
        self.game_seen = 0.0        # last request to the game's CDN
        self.served = set()
        self.failed = {}
        self.new_version = ""       # a language bundle the patch doesn't cover

    def json(self):
        now = time.time()
        with self.lock:
            return {
                "wg_conf": self.wg_conf, "client_build": self.client_build,
                "release_error": self.release_error, "total": len(self.manifest),
                "tunnel": now - self.tunnel_seen < 15,
                "language": any(n.startswith("language-ja_") for n in self.served), "cert": bool(self.cert_ok),
                "game": bool(self.game_seen), "served": len(self.served),
                "failed": sorted(self.failed.items())[:5], "new_version": self.new_version,
            }


S = State()


class MtEnIos:
    def load(self, loader):
        loader.add_option("mt_release", str, "https://github.com/Aikiooo/mt-en-applier/releases/download/ios-latest",
                          "Release with ios-manifest.json and the patched iOS bundles")
        loader.add_option("mt_home", str, os.path.join(os.environ.get("LOCALAPPDATA", "."), "MT-EN-iOS"),
                          "Cache folder")
        loader.add_option("mt_status_port", int, 8765, "Local port of the PC status page")
        loader.add_option("mt_open_browser", bool, True, "Open the status page on start")
        loader.add_option("mt_trace", bool, False, "Log every game download and DNS query to <home>/requests.log")

    def running(self):
        threading.Thread(target=self._load_manifest, daemon=True).start()
        for server in ctx.master.addons.get("proxyserver").servers:
            conf = getattr(server, "client_conf", None)
            if conf and conf():
                S.wg_conf = conf()
        _serve_status(ctx.options.mt_status_port, os.path.join(ctx.options.confdir, "mitmproxy-ca-cert.pem"))
        url = f"http://127.0.0.1:{ctx.options.mt_status_port}/"
        log.warning("Status page: " + url)
        if ctx.options.mt_open_browser:
            webbrowser.open(url)

    def _load_manifest(self):
        path = os.path.join(ctx.options.mt_home, "ios-manifest.json")
        try:
            with urllib.request.urlopen(ctx.options.mt_release.rstrip("/") + "/ios-manifest.json", timeout=60) as r:
                data = r.read()
            os.makedirs(ctx.options.mt_home, exist_ok=True)
            open(path, "wb").write(data)
        except Exception as e:
            if not os.path.exists(path):
                S.release_error = f"Can't download the patch list ({e}). Check the PC's internet connection."
                return
            data = open(path, "rb").read()
        m = json.loads(data.decode("utf-8-sig"))
        with S.lock:
            S.manifest = {f["file"]: f["out_md5"] for f in m["files"]}
            S.client_build = m.get("client_build", "")
            S.release_error = ""

    # ---------------------------------------------------------------- traffic

    def client_connected(self, client):
        S.tunnel_seen = time.time()

    def dns_request(self, flow):
        S.tunnel_seen = time.time()
        q = flow.request.questions
        if q:
            _trace(f"dns {q[0].name} type {q[0].type}")

    def error(self, flow: http.HTTPFlow):
        if flow.request and flow.request.pretty_host in (PHONE_HOST, CDN_HOST):
            log.warning(f"{flow.request.pretty_url}: {flow.error}")

    def server_connect(self, data):
        # No QUIC (HTTP/3) at all: iOS would fetch the game's files over it, past the patch.
        # Refused here, every app falls back to TCP. This hook also runs for the connections
        # allow_hosts passes through untouched, where udp_start doesn't.
        s = data.server
        if s.transport_protocol == "udp" and s.address and s.address[1] == 443:
            s.error = "QUIC blocked by the English patch"

    async def request(self, flow: http.HTTPFlow):
        S.tunnel_seen = time.time()
        host, path = flow.request.pretty_host, flow.request.path.split("?")[0]
        if host == PHONE_HOST:
            flow.response = _phone_page(path, os.path.join(ctx.options.confdir, "mitmproxy-ca-cert.pem"))
            return
        if host != CDN_HOST:
            return
        if path == CHECK_PATH:
            S.cert_ok = time.time()
            flow.response = http.Response.make(200, GIF, {"Content-Type": "image/gif", "Cache-Control": "no-store",
                                                          "Access-Control-Allow-Origin": "*"})
            return
        S.game_seen = time.time()
        _trace(path)
        m = BUNDLE.search(path)
        if not m:
            return
        name = m.group(1)
        md5 = S.manifest.get(name)
        if not md5:
            if name.startswith("language-ja_assets_all_") and S.manifest:
                S.new_version = name
            return
        try:
            body = await asyncio.to_thread(_cached, name, md5)
        except Exception as e:
            S.failed[name] = str(e)
            log.warning(f"{name}: {e} (the game gets the Japanese file)")
            return
        flow.response = http.Response.make(200, body, {"Content-Type": "application/octet-stream"})
        with S.lock:
            S.served.add(name)
            S.failed.pop(name, None)
        log.warning(f"English: {name} ({len(S.served)}/{len(S.manifest)})")


def _trace(path):
    # debugging (--set mt_trace=true): what went through the PC, one line per request
    if not ctx.options.mt_trace:
        return
    try:
        with open(os.path.join(ctx.options.mt_home, "requests.log"), "a", encoding="utf-8") as f:
            f.write(time.strftime("%H:%M:%S ") + path + "\n")
    except OSError:
        pass


def _cached(name, md5):
    path = os.path.join(ctx.options.mt_home, "cache", name)
    if os.path.exists(path):
        data = open(path, "rb").read()
        if hashlib.md5(data).hexdigest() == md5:
            return data
    with urllib.request.urlopen(ctx.options.mt_release.rstrip("/") + "/" + name, timeout=120) as r:
        data = r.read()
    if hashlib.md5(data).hexdigest() != md5:
        raise ValueError("downloaded file doesn't match the patch list")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path + ".part", "wb").write(data)
    os.replace(path + ".part", path)
    return data


# ---------------------------------------------------------------- pages

STYLE = """<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#f6f4ef;--fg:#1d1b18;--muted:#6b665d;--card:#fff;--line:#e3ded3;--ok:#1f8a4c;--bad:#b3261e;--acc:#b8860b}
@media (prefers-color-scheme:dark){:root{--bg:#141311;--fg:#ece8df;--muted:#a39d91;--card:#1e1c19;--line:#34302a;--ok:#4cc27e;--bad:#f2766b;--acc:#e0b44c}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,Segoe UI,sans-serif}
main{max-width:760px;margin:0 auto;padding:20px 16px 40px}h1{font-size:1.5em;margin:.2em 0 .6em}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin:12px 0}
.step{display:flex;gap:12px}.n{flex:none;width:28px;height:28px;border-radius:50%;background:var(--acc);color:#000;
font-weight:700;display:grid;place-items:center}.ok{color:var(--ok);font-weight:600}.bad{color:var(--bad);font-weight:600}
.muted{color:var(--muted);font-size:.92em}a.btn{display:inline-block;background:var(--acc);color:#000;padding:10px 18px;
border-radius:10px;text-decoration:none;font-weight:700;margin:6px 0}code{background:var(--line);padding:1px 5px;border-radius:5px}
.qr{background:#fff;padding:12px;border-radius:10px;display:inline-block}.row{display:flex;gap:20px;flex-wrap:wrap;align-items:center}
progress{width:100%;height:14px}
</style>"""

PC_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>MT English Patch for iPhone</title>""" + STYLE + """
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script></head><body><main>
<h1>English patch for iPhone / iPad</h1>
<p class="muted">Keep this window open while the game downloads. Everything happens on the iPhone; this page follows along.</p>
<div class="card step"><div class="n">1</div><div><b>Connect the iPhone</b>
<p>Install <b>WireGuard</b> from the App Store (free). Tap <b>+</b> &rsaquo; <b>Create from QR code</b>, scan this code,
name it <code>MT EN</code>, allow the VPN, then switch the tunnel <b>on</b>. Turn off any other VPN.</p>
<div class="row"><div class="qr" id="wg"></div><div id="s1" class="muted">Waiting for the iPhone...</div></div></div></div>
<div class="card step"><div class="n">2</div><div><b>Trust the patch certificate</b> (first time only)
<p>On the iPhone, scan this code with the Camera (or type <code>http://10.0.0.53</code> in Safari) and follow the page.</p>
<div class="row"><div class="qr" id="ph"></div><div id="s2" class="muted">Waiting...</div></div></div></div>
<div class="card step"><div class="n">3</div><div><b>Download the game data in English</b>
<p><b>New player:</b> just open the game. <b>Already playing:</b> on the title screen open the menu
(<b>メニュー</b>) and choose <b>Delete local data</b> (ローカルデータ削除: your account and progress stay),
then tap the screen. <b>Never</b> the option that deletes player data (データ削除).</p>
<progress id="pg" value="0" max="1"></progress><div id="s3" class="muted">Waiting for the game...</div></div></div>
<div class="card" id="done" hidden><span class="ok">Done.</span> Switch the WireGuard tunnel off and close this window:
the English files stay in the game. After a game update, run the installer again and switch the tunnel on.</div>
<p class="muted" id="foot"></p>
<script>
let shown=false;
function qr(id,text){const e=document.getElementById(id);e.innerHTML="";
 if(window.QRCode){new QRCode(e,{text:text,width:220,height:220,correctLevel:QRCode.CorrectLevel.L})}
 else{e.innerHTML="<pre style='color:#000;font-size:11px'>"+text+"</pre>"}}
async function tick(){
 let s;try{s=await (await fetch("/status.json")).json()}catch(e){document.getElementById("foot").textContent="The installer window was closed.";return}
 if(!shown&&s.wg_conf){qr("wg",s.wg_conf);qr("ph","http://10.0.0.53/");shown=true}
 const f=(id,ok,t)=>{const e=document.getElementById(id);e.className=ok===true?"ok":ok===false?"bad":"muted";e.textContent=t};
 f("s1",s.tunnel?true:null,s.tunnel?"iPhone connected":"Waiting for the iPhone...");
 f("s2",s.cert?true:null,s.cert?"Certificate trusted":"Waiting...");
 const pg=document.getElementById("pg");pg.max=s.total||1;pg.value=s.served;
 let t=s.release_error||(s.new_version?"The game has a new version that the iOS patch doesn't cover yet. Wait for the new patch on mtcoe.com, then run the installer again.":
  s.served?s.served+" / "+s.total+" English files sent"+(s.served<s.total?" (screens you haven't opened yet are sent when the game needs them)":""):s.game?"The game is connected...":"Waiting for the game...");
 f("s3",s.release_error||s.new_version?false:s.served?true:null,t);
 if(s.served&&!s.language)document.getElementById("s3").textContent+=" | The text pack hasn't come through this PC yet: if the game is already fully downloaded, do Delete local data again with the tunnel on.";
 if(s.failed.length)document.getElementById("s3").textContent+=" | failed: "+s.failed.map(x=>x[0]).join(", ");
 document.getElementById("done").hidden=!(s.language&&s.served>=s.total&&s.total);
 document.getElementById("foot").textContent="Patch for game build "+(s.client_build||"?")+".";
 setTimeout(tick,1000)}
tick();
</script></main></body></html>"""

PHONE_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>MT English Patch</title>""" + STYLE + """</head><body><main>
<h1>English patch: certificate</h1>
<p id="state" class="muted">Checking...</p>
<div id="steps"><div class="card step"><div class="n">1</div><div>
<a class="btn" href="/cert">Download the certificate</a><p>Tap <b>Allow</b>, then <b>Close</b>.</p></div></div>
<div class="card step"><div class="n">2</div><div>Open <b>Settings</b> &rsaquo; <b>Profile Downloaded</b> (near the top)
&rsaquo; <b>Install</b>, enter your passcode, <b>Install</b> again, <b>Done</b>.</div></div>
<div class="card step"><div class="n">3</div><div><b>Settings</b> &rsaquo; <b>General</b> &rsaquo; <b>About</b> &rsaquo;
<b>Certificate Trust Settings</b> (at the very bottom) &rsaquo; switch on <b>mitmproxy</b> &rsaquo; <b>Continue</b>.</div></div>
<p class="muted">Come back to this page: it turns green by itself. The certificate was made on your PC and never leaves it.
The patch only uses it for the game's download server.</p></div>
<script>
function check(){const i=new Image();
 i.onload=()=>{const s=document.getElementById("state");s.className="ok";
  s.textContent="All set. Open the game (step 3 on the PC).";document.getElementById("steps").hidden=true};
 i.onerror=()=>setTimeout(check,2000);
 i.src="https://""" + CDN_HOST + CHECK_PATH + """?t="+Date.now()}
check();
</script></main></body></html>"""


def _phone_page(path, cert):
    if path == "/cert":
        return http.Response.make(200, open(cert, "rb").read(), {
            "Content-Type": "application/x-x509-ca-cert",
            "Content-Disposition": 'attachment; filename="mt-en-patch.pem"'})
    return http.Response.make(200, PHONE_PAGE.encode(), {"Content-Type": "text/html; charset=utf-8",
                                                         "Cache-Control": "no-store"})


def _serve_status(port, cert):
    class H(httpserver.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/status.json":
                body, ctype = json.dumps(S.json()).encode(), "application/json"
            else:
                body, ctype = PC_PAGE.encode(), "text/html; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = httpserver.ThreadingHTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


addons = [MtEnIos()]
