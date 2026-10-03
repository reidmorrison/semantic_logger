---
paths:
  - "docs/**"
---

# Docs

User-facing documentation is a Jekyll site under [docs/](../../docs/) (published to logger.reidmorrison.com).

**The look and feel is not in this repo.** `docs/_config.yml` sets `remote_theme: reidmorrison/rm-docs-theme@v1`, and the layout, stylesheet, sidebar and syntax highlighting all come from there. This repo holds only its content: the markdown pages and `docs/images`. **Do not add a `docs/_layouts` or `docs/stylesheets` directory** — they were deleted deliberately, because six gem repos each carried a near-identical copy of the same theme and the copies had drifted. A styling change belongs in `rm-docs-theme`, where it reaches every doc site at once. `v1` is a moving major tag, so theme fixes arrive on the next build; breaking changes go to `v2` and are opted into by editing the pin. `jekyll-remote-theme` must stay in `plugins`: GitHub Pages enables it on its own, but a local build does not, and without it every page silently renders with no layout. Preview against a local theme checkout with `~/src/rm-docs-theme/bin/preview ~/src/semantic_logger/docs`.

**A page's title lives in its front matter**, not in a `## Heading` at the top of the markdown; the theme renders it as the page's `h1`. `index.md` sets `heading` rather than `title` so the home page keeps the tuned SEO `<title>` from `_config.yml`. Adding or renaming a page means editing the `nav` block in `docs/_config.yml`, the `pages` list in the `llms_full` rake task, and `docs/llms.txt`. When changing public behavior, update the relevant `docs/*.md` page (e.g. `appenders.md`, `metrics.md`, `api.md`, `testing.md`).

The site also serves two files for AI assistants: [docs/llms.txt](../../docs/llms.txt), a hand-maintained index of the docs pages (update it when adding or renaming a page), and `docs/llms-full.txt`, all pages concatenated, regenerated with `bundle exec rake llms_full`. **After editing any `docs/*.md` page, re-run `bundle exec rake llms_full`** and commit the result; never edit `llms-full.txt` by hand. The `docs/*.md` sources also ship inside the gem package (see `s.files` in the gemspec) so coding agents inside applications can read them locally.

Do not move this guidance into a `docs/CLAUDE.md`: the gemspec's `docs/*.md` glob would ship it in the gem, and Jekyll would publish it as a page.
