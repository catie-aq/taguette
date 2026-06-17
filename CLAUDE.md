# Taguette — Claude Code Guide

## What is Taguette?
A web-based qualitative research tool (Python 3.10+). Users import documents, select text passages (highlights), and tag them with hierarchical codes. Supports single-user desktop mode and multi-user server mode.

## Running locally
```bash
poetry install
scripts/update_translations.sh   # build .mo files
taguette --debug                  # starts at http://localhost:7465
```

## Key files

| File | Purpose |
|---|---|
| `taguette/main.py` | CLI entry point, config, startup |
| `taguette/web/__init__.py` | URL routing (`make_app()`) |
| `taguette/web/api.py` | JSON API handlers (~1000 lines) |
| `taguette/web/views.py` | Page handlers |
| `taguette/web/base.py` | `Application` class, `BaseHandler`, email, Redis |
| `taguette/web/export.py` | Export download handlers |
| `taguette/database/models.py` | SQLAlchemy ORM models |
| `taguette/database/__init__.py` | `connect()`, auto-migrate |
| `taguette/convert.py` | Document import/export via Calibre/wvHtml |
| `taguette/export.py` | Export logic (CSV, XLSX, HTML, QDC) |
| `taguette/extract.py` | UTF-8 byte-offset HTML highlight extraction |
| `taguette/static/js/taguette.js` | All frontend JS (~2000 lines, no build step) |
| `taguette/templates/` | Jinja2 templates |
| `po/` | Translation sources (.pot/.po) |

## Database models (summary)
- `User` → `ProjectMember` (many) → `Project`
- `Project` → `Document` (many) → `Highlight` (many) ↔ `Tag` (many-to-many)
- `Command` — append-only event log used for live sync (long-polling)
- `Privileges` enum: `ADMIN > MANAGE_DOCS > TAG > READ`

## Architecture patterns

**Mutations**: handler → update DB → create `Command` row → `app.notify_project()` → long-polling clients receive update via `GET /api/project/<id>/events`.

**Highlight offsets**: stored as UTF-8 byte positions in the document's text (HTML tags excluded). See `extract.py`.

**Editing a document remaps its highlights**: When a document's content is edited (`DocumentContents` PUT in `web/api.py`), highlights are byte ranges into the text and would otherwise drift. Instead of forbidding edits that touch highlighted passages, the handler remaps every highlight onto the new text via `extract.remap_highlights(old_text, new_text, ranges)`:
- `remap_highlights` diffs the old vs. new document text (`difflib.SequenceMatcher`) and shifts each `(start, end)` range. A highlight whose text was removed entirely maps to `None` and is **deleted** (emitting a `highlight_delete` command with `tag_count_changes`).
- Performance: edits are localized, so `remap_highlights` first trims the shared common prefix/suffix (binary-searched via `_common_prefix_len`/`_common_suffix_len`) and only diffs the changed middle region — avoiding a full-document diff on large texts.
- The handler only recomputes a highlight's `snippet` (`extract.extract`) when the highlighted bytes actually changed; a pure positional shift leaves the extracted text identical.
- Each remap/delete produces its own `Command`, all committed together and broadcast via `notify_project`. On the frontend (`taguette.js`), `highlight_add`/`highlight_delete` events update positions live; in the tag (highlights) view the active tag filters are preserved across the reload.

**Two runtime modes**:
- Single-user: `MULTIUSER=False`, auto-login as `admin`, SQLite3, auto-migrate.
- Server: config file required, manual `taguette migrate` before upgrade.

## Adding a feature — quick checklist
1. DB change → edit `database/models.py` + run `scripts/new_db_revision.sh`
2. New API endpoint → handler in `web/api.py` + route in `web/__init__.py`
3. New page → handler in `web/views.py` + template in `templates/` + route
4. New export → logic in `export.py` + handler in `web/export.py` + route
5. Notify clients → new type in `Command.TYPES` + factory method + handle in `taguette.js`
6. Translatable string → `self.gettext()` (Python) or `_()` (JS); run `scripts/update_pot.sh`
7. New permission → add `can_*` to `Privileges` enum; check in handler

## See also
- `doc/structure.md` — full structure reference
- `ARCHITECTURE.md` — original architecture doc
- `CONTRIBUTING.md` — contribution guidelines
