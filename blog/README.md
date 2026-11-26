# Blog

Posts are Markdown files in `blog/posts/`, named `YYYY-MM-DD-slug.md`. The site build (`scripts/build-blog.py`, run by the Pages workflow) turns them into static pages with link previews, a "Copy as Markdown" button and an RSS feed.

Front matter, all required except `version` and `image`:

```
---
title: "LickMyPaw 0.3.0: what changed"
slug: lickmypaw-0-3-0
date: 2026-12-10
version: v0.3.0
summary: One or two sentences, also used for the link preview.
image: assets/screenshots/02-prowl.png
---
```

Write images and links to the site as `assets/screenshots/x.png` (relative to the site root). They are rebased for the page and made absolute in the copied Markdown. No em dashes: the build fails if it finds one.

Preview locally:

```
mkdir -p /tmp/lmp-site && cp -R site/. /tmp/lmp-site/ && mkdir -p /tmp/lmp-site/assets/screenshots && cp assets/screenshots/*.png /tmp/lmp-site/assets/screenshots/
uv run --with markdown python scripts/build-blog.py /tmp/lmp-site
python3 -m http.server 8000 -d /tmp/lmp-site
```
