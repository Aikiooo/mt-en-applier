# iOS patch (maintainers)

Players: [`docs/INSTALL-iOS.md`](../../docs/INSTALL-iOS.md).

## How it works

An iOS app can't write into the game's files, and changing the app itself means
re-signing it (computer + cable). So the patch goes in over the network, the way the
game's own data does:

- The game downloads its Addressables bundles from
  `https://mushokutensei-coe-jp.akamaized.net/production/client/<build>/<unity>/AssetBundle/iOS/<name>_<hash>.bundle`.
  No certificate pinning.
- The players' tool (`pc/`, shipped as `MT-EN-iOS.zip` on the release) runs mitmproxy on
  their Windows PC in **WireGuard mode**; the iPhone joins with the free WireGuard app (QR
  code on the PC page at `http://127.0.0.1:8765`) and trusts mitmproxy's CA from
  `http://10.0.0.53` (served by the addon through the tunnel). Free on both sides, no cable.
- `allow_hosts` limits interception to the CDN host (and 10.0.0.53); everything else is
  passed through untouched. The addon answers each patched file with its copy from the
  `ios-latest` release (fetched on demand, MD5-checked against `ios-manifest.json`, cached in
  `%LOCALAPPDATA%\MT-EN-iOS\cache`).
- Unity checks the download CRC from the catalog and caches the file under the stock hash.
  The patch then stays with the tunnel off, until a game update names new hashes.
- Every bundle in the iOS catalog has a download CRC, so each patched file keeps the stock
  CRC (`unityfs.forge`); the language bundle also keeps the stock size
  (`build_locale_bundle.build`).

mitmproxy settings that matter (`pc/Installer-iOS.ps1`, found testing on an iPhone):

| Setting | Why |
|---------|-----|
| `connection_strategy=lazy` | otherwise mitmproxy connects upstream first and `http://10.0.0.53` never answers |
| `http2=false` | iOS cancels HTTP/2 streams in bulk on the large Movie downloads: endless "download failed" |
| UDP 443 refused (`server_connect` in the addon) | iOS fetches the boot bundles (language pack included) over **HTTP/3**, past the proxy: visuals English, text Japanese. Refused, it falls back to TCP. `udp_start` doesn't fire for allow_hosts pass-through flows, `server_connect` does |

Debugging: add `--set mt_trace=true` to the mitmdump line; every game request and DNS query
goes to `%LOCALAPPDATA%\MT-EN-iOS\requests.log`.

The release also carries `mt-en-ios.yaml` (Egern) and `mt-en-ios.sgmodule` (Shadowrocket,
Surge, Loon): the same files as 302 rewrites, for players who own one of those apps
(Egern's rewrites need Pro). Not the default path: they cost money.

Patched: the language pack (all text tables), and the 353 bundles of the PC prefab patch and
redrawn images (7268 prefab text fields, 137 textures re-encoded to ASTC 6x6). Not patchable:
`inapp_assets_all`, which ships inside the signed app (title-screen menu, first-load loading
tips, title logo): the "load twice" note applies on iOS.

## After a game update

1. Find the new base URL. The build path changes with each client update; the iOS catalog is
   `<base>/catalog_ja.hash` / `catalog_ja.json`. Read it from a capture of the game's traffic
   (`mt_trace=true` above, then any game download: the first request to the akamaized host
   shows it).
2. Once `patch-latest` is rebuilt for the new game version:

   ```
   gh release download patch-latest --repo Aikiooo/mt-en-applier -D build/ios-release `
       -p language-ja_en.bundle -p translation_cache.json -p prefab-patch.zip -p prefab-images.zip
   python -I -X utf8 tools/ios/build_ios_patch.py --base-url <base> --release-dir build/ios-release `
       --metadata <PC game>/mushoku_coe_cl_Data/il2cpp_data/Metadata/global-metadata.dat
   powershell -File tools\ios\Publish-IosPatch.ps1
   ```

   Needs `pip install UnityPy pycryptodome astc-encoder-py pillow`. The builder refuses
   (exit 1) if the English tables don't have the iOS row ids (patch for another game
   version) or a stock bundle doesn't match the catalog CRC. Re-running reuses the stock
   download cache (`build/ios-stock/<catalog hash>/`).
3. Players run `Installer-iOS.bat` again (it reads the new manifest at start), switch the
   tunnel on and open the game.

The same build was checked against the files tested in game on an iPhone (2026-10, client
build `202610081009578fd70`): byte-identical output.
