"""English textures: re-encode game Texture2D objects from translations/en/textures/<name>.png.

Each PNG is named after the Texture2D it replaces. Every texture of that name in
a bundle is re-encoded in its own format (DXT1/DXT5/RGBA32), size and mip count
with Texture2D.set_image, so the bundle layout and data size stay the same
(a PNG exported larger than the game's copy is scaled down to fit).
"""
import os

DEFAULT_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                            "..", "..", "translations", "en", "textures"))


def texture_files(folder=DEFAULT_DIR):
    """{texture name: png path}; empty when the folder is missing or not given."""
    if not folder or not os.path.isdir(folder):
        return {}
    return {f[:-4]: os.path.join(folder, f) for f in os.listdir(folder) if f.lower().endswith(".png")}


def set_textures(env, files):
    """Re-encode the Texture2D objects of a loaded UnityPy env that have an English PNG.
    Returns the names written (one per object)."""
    if not files:
        return []
    from PIL import Image
    written = []
    for obj in env.objects:
        if obj.type.name != "Texture2D":
            continue
        try:
            name = obj.peek_name()
        except Exception:
            continue
        if name not in files:
            continue
        tex = obj.read()
        img = Image.open(files[name]).convert("RGBA")
        if img.size != (tex.m_Width, tex.m_Height):
            img = img.resize((tex.m_Width, tex.m_Height), Image.LANCZOS)
        tex.set_image(img, target_format=tex.m_TextureFormat, mipmap_count=max(1, tex.m_MipCount))
        tex.save()
        written.append(name)
    return written
