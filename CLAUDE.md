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

**Tags can be applied two ways** — to a text passage or to a whole document:
- **Highlight tags**: the normal case. A `Highlight` ↔ `Tag` many-to-many (`highlight_tags` table). A highlight is a byte range in one document, tagged with one or more tags.
- **Document tags**: a `Document` ↔ `Tag` many-to-many (`document_tags` table, `database/models.py`). The *same* `Tag` rows are reused — a tag is not intrinsically "a document tag" or "a highlight tag"; the distinction is only which junction table links it. A tag may be used both ways, or only as a document tag (then `tag.highlights_count` / the `count` field is 0).
- Document tags are edited in the document edit modal (`document-change-tags` checkboxes in `taguette.js` → `tags` field of the `DocumentUpdate` PUT in `web/api.py`, which replaces `document.tags`).
- Serialization to the frontend: each document carries `tags: [tag_id, …]` (`views.py` `Project.get`, and `document_add`/`document_tags` in the event stream). Tags themselves are serialized with only `id/path/description/count` — there is **no** per-tag flag distinguishing document vs highlight tags, so frontend code must never rely on one (an old, never-populated `is_document_tag` field was removed).
- In the tag (highlights) view, each highlight entry shows its document's tags as `badge-secondary` chips alongside its own highlight-tag chips (`loadTag` in `taguette.js`).
- **Project export/import** (`database/copy.py` `copy_project`, used by both the SQLite3 export and the project import) copies the materialized association tables directly — it must copy **both** `highlight_tags` *and* `document_tags`, otherwise tags survive the round-trip but their document associations are silently lost.

**Highlight tag filter** (the "must have" / "must NOT have" dropdowns in the tag/highlights view) is done **server-side** so pagination and exports stay correct:
- A filter tag matches a highlight if the tag is on the highlight (`highlight_tags`) **OR** on its document (`document_tags`). This union is what lets a document-only tag (0 highlights of its own) still filter. Include = match ALL selected tags; exclude = match NONE.
- The SQL is built once by `database.highlight_tag_filter_clauses(include_ids, exclude_ids)` (`database/models.py`) — a list of clauses (correlated `EXISTS` sub-queries) AND-ed into a query over `Highlight`. It works in both ORM queries (`query.filter(*clauses)`) and Core selects (`select.where(clause)`); each `EXISTS` uses `.correlate(highlights)` so the enclosing query's own joins on the junction tables aren't auto-correlated away.
- Frontend (`taguette.js`): the filter is no longer a client-side CSS hide. `loadTag` sends the active filters as `&include=…&exclude=…` (`filterQueryString()`); changing a filter reloads the view from page 1 (a `suppressFilterReload` guard prevents the dropdown rebuild from re-triggering a reload). The export-dropdown hrefs carry the same query params.
- Consumers of the filter params: `Highlights.get` in `web/api.py` (paginated view) and `export.highlights_csv` / `highlights_xslx` / `highlights_doc` → `_get_highlights_for_export` in `export.py`, wired through the handlers in `web/export.py` (`parse_tag_filters`).
- The navigated tag itself (`/api/.../highlights/<tag_path>`) is still highlight-tag based, so clicking a document-only tag in the sidebar returns 0 highlights — use the "must have" filter to see highlights of documents carrying that tag.

**Two runtime modes**:
- Single-user: `MULTIUSER=False`, auto-login as `admin`, SQLite3, auto-migrate.
- Server: config file required, manual `taguette migrate` before upgrade.

## Adding a feature — quick checklist
1. DB change → edit `database/models.py` + run `scripts/new_db_revision.sh`
2. New API endpoint → handler in `web/api.py` + route in `web/__init__.py`
3. New page → handler in `web/views.py` + template in `templates/` + route
4. New export → logic in `export.py` + handler in `web/export.py` + route
5. Notify clients → new type in `Command.TYPES` + factory method + handle in `taguette.js`. **If you add a payload field to any `Command`, also add a validator for it in `database/copy.py`'s `field_validators` (and a `mapping_tags` transformer if it holds tag IDs, like `tags`/`document_tags`) — otherwise the SQLite3 project export raises `KeyError: '<field>'` while copying the `commands` table.**
6. Translatable string → `self.gettext()` (Python) or `_()` (JS); run `scripts/update_pot.sh`
7. New permission → add `can_*` to `Privileges` enum; check in handler

## See also
- `doc/structure.md` — full structure reference
- `ARCHITECTURE.md` — original architecture doc
- `CONTRIBUTING.md` — contribution guidelines
