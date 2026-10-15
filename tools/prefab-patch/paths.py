"""Locate the PC game, its Unity cache and its newest Addressables catalog."""
import glob
import json
import os

LOCALLOW = os.path.join(os.environ.get("USERPROFILE", ""), "AppData", "LocalLow")


def game_dir():
    """Install folder from DMM GAME PLAYER's own config (same source as MT.EnPatch.psm1)."""
    cnf = os.path.join(os.environ.get("APPDATA", ""), "dmmgameplayer5", "dmmgame.cnf")
    try:
        for c in json.load(open(cnf, encoding="utf-8")).get("contents", []):
            if c.get("productId") == "mushoku_coe_cl":
                return c["detail"]["path"]
    except (OSError, ValueError, KeyError):
        pass
    raise SystemExit("game folder not found; pass --game-dir")


def cache_dir():
    hits = glob.glob(os.path.join(LOCALLOW, "Unity", "GREE Entertainment*"))
    if not hits:
        raise SystemExit("Unity cache not found (launch the game once); pass --cache")
    return hits[0]


def newest_catalog():
    cats = glob.glob(os.path.join(LOCALLOW, "GREE Entertainment", "*", "com.unity.addressables", "*.json"))
    if not cats:
        raise SystemExit("Addressables catalog not found; pass --catalog")
    return max(cats, key=os.path.getmtime)


def inapp_path(gdir):
    return os.path.join(gdir, "mushoku_coe_cl_Data", "StreamingAssets", "aa", "StandaloneWindows64",
                        "inapp_assets_all.bundle")


def metadata_path(gdir):
    return os.path.join(gdir, "mushoku_coe_cl_Data", "il2cpp_data", "Metadata", "global-metadata.dat")
