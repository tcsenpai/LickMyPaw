#!/usr/bin/env python3
"""Builds the static blog into an output folder (default: _site).

Posts live in blog/posts/*.md with a small front matter block (title, slug, date, version, summary, image).
Output: <out>/blog/index.html, <out>/blog/<slug>/index.html and <out>/blog/feed.xml.
Pages are plain HTML on purpose: link previews (Reddit, Discord, X) and feed readers do not run JavaScript.

Run: uv run --with markdown python scripts/build-blog.py _site
Image and link paths in a post are written relative to the site root (assets/screenshots/x.png).
"""
import html, re, sys
from datetime import datetime, timezone
from pathlib import Path
import markdown

SITE = "https://tcsenpai.github.io/LickMyPaw"
ROOT = Path(__file__).resolve().parent.parent
DS = "_ds/nocturne-1cd76810-4672-49a4-a748-310c574c7b5d/styles.css"


def parse(path: Path) -> dict:
    t = path.read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", t, re.S)
    if not m:
        raise SystemExit(f"{path.name}: missing front matter")
    meta = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        meta[k.strip()] = v.strip().strip('"')
    for k in ("title", "slug", "date", "summary"):
        if not meta.get(k):
            raise SystemExit(f"{path.name}: front matter needs '{k}'")
    if not re.fullmatch(r"[a-z0-9-]+", meta["slug"]):
        raise SystemExit(f"{path.name}: bad slug")
    meta["body"] = m.group(2).strip()
    meta["file"] = path.name
    return meta


def md_to_html(body: str) -> str:
    return markdown.markdown(body, extensions=["fenced_code", "tables", "sane_lists"])


def absolute(body: str) -> str:
    """Markdown for copy and paste elsewhere: site-relative paths become absolute URLs."""
    return re.sub(r"\]\((assets/[^)]+)\)", lambda m: f"]({SITE}/{m.group(1)})", body)


def rebase(h: str, prefix: str) -> str:
    return re.sub(r'(src|href)="(assets/)', lambda m: f'{m.group(1)}="{prefix}{m.group(2)}', h)


def date_label(d: str) -> str:
    return datetime.strptime(d, "%Y-%m-%d").strftime("%-d %B %Y")


CSS = """
body { margin: 0; text-wrap: pretty; background: radial-gradient(1200px 720px at 82% -160px, color-mix(in srgb, var(--color-accent-900) 75%, transparent), transparent 60%), radial-gradient(1100px 800px at -10% 100%, color-mix(in srgb, black 30%, transparent), transparent 55%), var(--color-bg); color: var(--color-text); font-family: var(--font-body, Inter, system-ui, sans-serif); }
a { color: var(--color-accent-300); } a:hover { color: var(--color-accent-200); }
main { max-width: 1200px; margin: 0 auto; padding: 0 clamp(20px, 5vw, 72px); }
.wrap { max-width: 740px; }
h1, h2 { font-family: var(--font-heading); font-weight: var(--font-heading-weight); letter-spacing: -0.01em; color: var(--color-text); }
h1 { font-size: clamp(34px, 4.6vw, 56px); line-height: 1.1; margin: 0; }
.meta { display: flex; gap: 14px; align-items: center; flex-wrap: wrap; margin: 0 0 18px; font-size: 14px; color: color-mix(in srgb, var(--color-text) 72%, transparent); }
.lede { font-size: 18px; line-height: 29px; margin: 22px 0 0; color: color-mix(in srgb, var(--color-text) 80%, transparent); }
.prose { font-size: 16.5px; line-height: 28px; color: color-mix(in srgb, var(--color-text) 86%, transparent); }
.prose h2 { font-size: 26px; line-height: 1.2; margin: 52px 0 12px; }
.prose p { margin: 0 0 16px; } .prose ul, .prose ol { margin: 0 0 18px; padding-left: 22px; } .prose li { margin: 6px 0; padding-left: 4px; }
.prose img { display: block; max-width: 100%; height: auto; margin: 22px auto; border-radius: 14px; border: 1px solid var(--color-neutral-700); }
.prose code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; padding: 2px 6px; border-radius: 6px; background: color-mix(in srgb, var(--color-text) 10%, transparent); }
.prose pre { overflow-x: auto; padding: 14px 16px; border-radius: 12px; background: color-mix(in srgb, black 35%, transparent); border: 1px solid var(--color-neutral-700); } .prose pre code { padding: 0; background: none; }
.prose table { border-collapse: collapse; margin: 0 0 18px; } .prose th, .prose td { border: 1px solid var(--color-neutral-700); padding: 8px 12px; text-align: left; }
.bar { display: flex; gap: 12px; flex-wrap: wrap; align-items: center; margin-top: 32px; }
.btn-soft { cursor: pointer; font: inherit; font-size: 14px; padding: 8px 16px; border-radius: 999px; border: 1px solid var(--color-neutral-700); background: transparent; color: var(--color-text); }
.btn-soft:hover { background: color-mix(in srgb, var(--color-accent) 18%, transparent); }
.card { display: block; padding: 28px 0; text-decoration: none; color: inherit; background: linear-gradient(to right, transparent, var(--color-neutral-700) 48px calc(100% - 48px), transparent) top / 100% 1px no-repeat; }
.card h2 { font-size: 26px; margin: 6px 0 10px; } .card:hover h2 { color: var(--color-accent-200); }
.card p { margin: 0; font-size: 16px; line-height: 26px; max-width: 64ch; color: color-mix(in srgb, var(--color-text) 78%, transparent); }
footer { padding: 40px 0 56px; display: flex; flex-wrap: wrap; gap: 12px 32px; justify-content: space-between; font-size: 13px; line-height: 20px; color: color-mix(in srgb, var(--color-text) 64%, transparent); background: linear-gradient(to right, transparent, var(--color-divider) 48px calc(100% - 48px), transparent) top / 100% 1px no-repeat; }
"""


def page(title, desc, url, up, body, image=None, extra_head="", kind="website"):
    img = f'{SITE}/{image}' if image else f"{SITE}/assets/AppIcon-1024.png"
    t = html.escape(title)
    d = html.escape(desc)
    nav = f"""<nav class="nav" style="position: sticky; top: 0; z-index: 20; flex-wrap: wrap; padding-inline: max(clamp(20px, 5vw, 72px), calc((100% - 1200px) / 2 + clamp(20px, 5vw, 72px))); background: color-mix(in srgb, var(--color-bg) 72%, transparent); backdrop-filter: blur(14px) saturate(1.2); -webkit-backdrop-filter: blur(14px) saturate(1.2);">
  <a href="{up}Home.dc.html" class="nav-brand" style="display: flex; align-items: center; gap: var(--space-3); text-decoration: none; color: var(--color-text);"><img src="{up}assets/AppIcon-1024.png" alt="" style="width: 26px; height: 26px;">LickMyPaw</a>
  <a href="{up}Home.dc.html#features">Features</a>
  <a href="{up}Home.dc.html#compare">Compare</a>
  <a href="{up}Home.dc.html#cli">CLI</a>
  <a href="{up}News.dc.html">News</a>
  <a href="{up}blog/" aria-current="page" style="color: var(--color-accent);">Blog</a>
  <a class="btn btn-primary" href="{up}Home.dc.html#download" style="text-decoration: none;">Download</a>
</nav>"""
    foot = f"""<footer><span>LickMyPaw · MIT licensed · by <a href="https://github.com/tcsenpai">tcsenpai</a></span><span><a href="{up}blog/feed.xml">RSS</a> · <a href="{up}Home.dc.html">Back to home</a></span></footer>"""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t}</title>
<meta name="description" content="{d}">
<link rel="icon" href="{up}assets/AppIcon-1024.png">
<link rel="canonical" href="{url}">
<link rel="alternate" type="application/atom+xml" title="LickMyPaw blog" href="{SITE}/blog/feed.xml">
<meta property="og:type" content="{kind}">
<meta property="og:site_name" content="LickMyPaw">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{img}">
<meta name="twitter:card" content="summary_large_image">
<link rel="stylesheet" href="{up}{DS}">
<style>{CSS}</style>
{extra_head}
</head>
<body>
{nav}
<main>
{body}
{foot}
</main>
</body>
</html>
"""


def build(out: Path):
    posts = sorted((parse(p) for p in (ROOT / "blog" / "posts").glob("*.md")), key=lambda p: (p["date"], p["file"]), reverse=True)
    slugs = [p["slug"] for p in posts]
    if len(set(slugs)) != len(slugs):
        raise SystemExit("duplicate slug")
    blog = out / "blog"
    blog.mkdir(parents=True, exist_ok=True)

    # index
    cards = ""
    for p in posts:
        v = f'<span class="tag tag-neutral">{html.escape(p["version"])}</span>' if p.get("version") else ""
        cards += f'<a class="card" href="{p["slug"]}/"><div class="meta"><time datetime="{p["date"]}">{date_label(p["date"])}</time>{v}</div><h2>{html.escape(p["title"])}</h2><p>{html.escape(p["summary"])}</p></a>\n'
    idx = f"""<header class="wrap" style="padding: clamp(56px, 8vw, 96px) 0 24px;"><h1>Blog</h1><p class="lede">Release notes written for humans: what changed, why, and what still needs work. Every post can be copied as Markdown, so it is easy to share. Prefer a feed? <a href="feed.xml">Subscribe via RSS</a>.</p></header>
<section class="wrap" aria-label="Posts" style="padding-bottom: 72px;">{cards}</section>"""
    (blog / "index.html").write_text(page("Blog | LickMyPaw", "Release notes for LickMyPaw, the free, open source Mac cleaner, written for humans.", f"{SITE}/blog/", "../", idx), encoding="utf-8")

    # posts
    for p in posts:
        d = blog / p["slug"]
        d.mkdir(exist_ok=True)
        body_html = rebase(md_to_html(p["body"]), "../../")
        if "</script" in p["body"].lower():
            raise SystemExit(f"{p['file']}: '</script' is not allowed in a post")
        raw = absolute(p["body"])
        v = f'<span class="tag tag-neutral">{html.escape(p["version"])}</span>' if p.get("version") else ""
        article = f"""<article class="wrap" style="padding: clamp(48px, 7vw, 88px) 0 48px;">
<p class="meta"><a href="../">Blog</a><span>/</span><time datetime="{p["date"]}">{date_label(p["date"])}</time>{v}</p>
<h1>{html.escape(p["title"])}</h1>
<p class="lede">{html.escape(p["summary"])}</p>
<div class="bar"><button type="button" class="btn-soft" id="copy">Copy as Markdown</button><a class="btn-soft" style="text-decoration: none;" href="https://github.com/tcsenpai/LickMyPaw/releases/tag/{html.escape(p.get("version", ""))}">Release page</a></div>
<div class="prose" style="margin-top: 40px;">
{body_html}
</div>
</article>
<script type="text/markdown" id="md"># {p["title"]}

{raw}</script>
<script>
(function () {{
  var b = document.getElementById('copy'), t = document.getElementById('md').textContent;
  b.addEventListener('click', function () {{
    var done = function () {{ b.textContent = 'Copied'; setTimeout(function () {{ b.textContent = 'Copy as Markdown'; }}, 2000); }};
    if (navigator.clipboard) navigator.clipboard.writeText(t).then(done, fallback); else fallback();
    function fallback() {{ var a = document.createElement('textarea'); a.value = t; document.body.appendChild(a); a.select(); try {{ document.execCommand('copy'); done(); }} catch (e) {{}} a.remove(); }}
  }});
}})();
</script>"""
        url = f"{SITE}/blog/{p['slug']}/"
        (d / "index.html").write_text(page(f"{p['title']} | LickMyPaw", p["summary"], url, "../../", article, p.get("image"), kind="article"), encoding="utf-8")

    # atom feed
    ents = ""
    for p in posts:
        url = f"{SITE}/blog/{p['slug']}/"
        content = re.sub(r'(src|href)="(assets/)', lambda m: f'{m.group(1)}="{SITE}/{m.group(2)}', md_to_html(p["body"]))
        ents += f"""<entry><title>{html.escape(p["title"])}</title><link href="{url}"/><id>{url}</id><updated>{p["date"]}T00:00:00Z</updated><summary>{html.escape(p["summary"])}</summary><content type="html">{html.escape(content)}</content></entry>\n"""
    updated = (posts[0]["date"] if posts else datetime.now(timezone.utc).strftime("%Y-%m-%d")) + "T00:00:00Z"
    (blog / "feed.xml").write_text(f"""<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>LickMyPaw blog</title><link href="{SITE}/blog/"/><link rel="self" href="{SITE}/blog/feed.xml"/><id>{SITE}/blog/</id><updated>{updated}</updated><author><name>tcsenpai</name></author>
{ents}</feed>
""", encoding="utf-8")

    # checks: no em dashes, no unresolved site-relative asset paths in the generated pages
    for f in blog.rglob("*.*"):
        s = f.read_text(encoding="utf-8")
        if "—" in s:
            raise SystemExit(f"{f}: em dash found")
        if f.suffix == ".html" and re.search(r'(src|href)="assets/', s):
            raise SystemExit(f"{f}: asset path not rebased")
    print(f"built {len(posts)} post(s) into {blog}")


if __name__ == "__main__":
    build(Path(sys.argv[1] if len(sys.argv) > 1 else "_site"))
