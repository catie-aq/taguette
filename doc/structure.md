# Taguette — Project Structure

## Overview

Taguette (v1.5.2) is a **web-based qualitative research tool** written in Python. Users import documents, highlight text passages, and apply hierarchical tags ("codes") to those highlights. It supports both single-user (desktop) mode and multi-user server mode.

## Technology Stack

| Layer | Technology |
|---|---|
| Web framework | [Tornado](https://www.tornadoweb.org/) (async) |
| Templates | [Jinja2](https://jinja.palletsprojects.com/) |
| Database ORM | [SQLAlchemy](https://www.sqlalchemy.org/) 1.4 |
| DB migrations | [Alembic](https://alembic.sqlalchemy.org/) |
| Default DB | SQLite3 (single-user), PostgreSQL / MariaDB (server) |
| Real-time sync | Long-polling + optional Redis pub/sub |
| Document import | [Calibre](https://calibre-ebook.com/) `ebook-convert` subprocess |
| HTML sanitization | [bleach](https://github.com/mozilla/bleach) |
| Frontend JS | Vanilla JS + jQuery + Bootstrap (single file) |
| Packaging | [Poetry](https://python-poetry.org/) |
| Observability | Prometheus metrics + OpenTelemetry tracing + Sentry |
| i18n | GNU gettext / Babel (po/ catalogs) |

---

## Directory Layout

```
taguette/                        # Python package root
├── __init__.py                  # Version, translation bootstrap
├── main.py                      # CLI entry point, config loading, startup
├── convert.py                   # Document import/export via Calibre/wvHtml
├── export.py                    # Export logic (CSV, XLSX, HTML, QDC codebook)
├── extract.py                   # UTF-8-aware HTML highlight extraction
├── import_codebook.py           # Import QDC codebook XML
├── validate.py                  # Input validation helpers
├── utils.py                     # Misc utilities (background tasks, filenames)
│
├── database/
│   ├── __init__.py              # DB connect(), auto-migrate, re-exports
│   ├── base.py                  # Prometheus DB counters
│   ├── models.py                # SQLAlchemy ORM models (see below)
│   └── copy.py                  # copy_project() for project import
│
├── web/
│   ├── __init__.py              # make_app(): URL routing table
│   ├── base.py                  # Application class, BaseHandler, email, Redis
│   ├── views.py                 # Page handlers (HTML responses)
│   ├── api.py                   # JSON API handlers
│   └── export.py                # Export download handlers
│
├── migrations/
│   ├── env.py                   # Alembic environment
│   └── versions/                # Individual migration scripts (~15 migrations)
│
├── templates/                   # Jinja2 HTML templates
│   ├── base.html                # Shared layout (nav, footer)
│   ├── project.html             # Main project view (document + tag panels)
│   ├── index.html               # Dashboard listing user projects
│   ├── login.html / account.html / register.html / ...
│   └── export_*.html            # Export-format templates
│
├── static/
│   ├── js/
│   │   ├── taguette.js          # ALL frontend logic (~1967 lines)
│   │   ├── jquery-3.7.1.min.js
│   │   └── bootstrap.bundle.min.js
│   ├── css/                     # Bootstrap + custom styles
│   └── webfonts/                # Font Awesome
│
└── l10n/                        # Compiled .mo translation files

po/                              # Translation source files (.pot / .po)
scripts/                         # Dev/admin utilities
contrib/                         # Deployment configs (nginx, apache, k8s)
```

---

## Database Models (`taguette/database/models.py`)

```
User
  login (PK, str)
  hashed_password (scrypt | pbkdf2 | bcrypt)
  email, language, disabled, ...
  ├─< ProjectMember (many)

Project
  id (PK), name, description
  ├─< ProjectMember (many)
  ├─< Document (many)
  ├─< Tag (many)
  └─< Command (many)

ProjectMember
  project_id (FK) + user_login (FK) — composite PK
  privileges: ADMIN | MANAGE_DOCS | TAG | READ

Document
  id (PK), name, description, filename
  project_id (FK)
  text_direction (LTR | RTL)
  contents (HTML, deferred load — LONGTEXT on MariaDB)
  └─< Highlight (many)

Highlight
  id (PK), document_id (FK)
  start_offset, end_offset  (UTF-8 byte offsets into document text)
  snippet (pre-extracted text)
  ↔ Tag (many-to-many via highlight_tags)

Tag
  id (PK), project_id (FK)
  path (hierarchical, e.g. "theme/subtheme"), description
  highlights_count, documents_count (column_property subqueries)

Command  (event log for live sync)
  id (PK), date, user_login, project_id, document_id
  payload (JSON): type + type-specific fields
  Types: project_meta | document_add | document_delete |
         highlight_add | highlight_delete | tag_add | tag_delete |
         tag_merge | member_add | member_remove | project_import
```

---

## URL Routes (`taguette/web/__init__.py → make_app()`)

### Page views (`web/views.py`)
| Route | Handler | Purpose |
|---|---|---|
| `/` | `Index` | Dashboard / welcome |
| `/login`, `/logout`, `/register` | `Login`, `Logout`, `Register` | Auth |
| `/account` | `Account` | Profile, password, language |
| `/reset_password`, `/new_password` | `AskResetPassword`, `SetNewPassword` | Email-based reset |
| `/project/new` | `ProjectAdd` | Create project |
| `/project/import` | `ProjectImport` | Import SQLite3 project file |
| `/project/<id>` | `Project` | Main project view |
| `/project/<id>/delete` | `ProjectDelete` | Delete project |
| `/project/<id>/import_codebook` | `ImportCodebook` | Import QDC codebook |

### Export endpoints (`web/export.py`)
| Route | Format |
|---|---|
| `/project/<id>/export/project.sqlite3` | Full project backup |
| `/project/<id>/export/codebook.qdc` | Codebook XML (QDA standard) |
| `/project/<id>/export/codebook.csv` | Codebook CSV |
| `/project/<id>/export/codebook.xlsx` | Codebook Excel |
| `/project/<id>/export/codebook.<ext>` | Codebook via Calibre (docx, odt, …) |
| `/project/<id>/export/document/<name>.<ext>` | Single document |
| `/project/<id>/export/highlights/<tag>.<ext>` | Highlights for a tag |

### JSON API (`web/api.py`)
| Route | Handler | Purpose |
|---|---|---|
| `POST /api/check_user` | `CheckUser` | User lookup |
| `POST /api/import` | `ProjectImport` | Upload SQLite3 project |
| `POST /api/project/<id>` | `ProjectMeta` | Update project name/description |
| `POST /api/project/<id>/document/new` | `DocumentAdd` | Upload + convert document |
| `GET/DELETE /api/project/<id>/document/<id>` | `Document` | Get/delete document |
| `GET /api/project/<id>/document/<id>/contents` | `DocumentContents` | HTML content + highlights |
| `POST /api/project/<id>/document/<id>/highlight/new` | `HighlightAdd` | Create highlight |
| `GET/PATCH/DELETE /api/project/<id>/document/<id>/highlight/<id>` | `HighlightUpdate` | Manage highlight |
| `GET /api/project/<id>/highlights/<tag>` | `Highlights` | All highlights for a tag |
| `POST /api/project/<id>/tag/new` | `TagAdd` | Create tag |
| `PATCH/DELETE /api/project/<id>/tag/<id>` | `TagUpdate` | Update/delete tag |
| `POST /api/project/<id>/tag/merge` | `TagMerge` | Merge two tags |
| `POST /api/project/<id>/members` | `MembersUpdate` | Manage project members |
| `GET /api/project/<id>/events` | `ProjectEvents` | **Long-polling** for live updates |

---

## Key Subsystems

### Document Ingestion (`convert.py`)
1. Uploaded file saved to a temp dir.
2. If `.doc` → `wvHtml` subprocess; otherwise → Calibre `ebook-convert` to HTML.
3. Resulting HTML sanitized with `bleach` (strips scripts, media, etc.).
4. Stored as HTML in `documents.contents`.

### Highlight Offsets (`extract.py`)
- Offsets are **UTF-8 byte positions** in the document's *text content* (HTML tags skipped).
- `extract()` — given offsets, returns the HTML fragment for a range.
- `highlight()` — wraps a range in `<mark>` tags for display.

### Live Collaboration (`web/base.py` + `web/api.py`)
- Every mutation creates a `Command` row, then calls `notify_project(project_id, cmd)`.
- Clients hold open a `GET /api/project/<id>/events?from=<last_cmd_id>` connection.
- Server replies when a new command arrives (long-polling); client processes update then reconnects.
- Optional Redis pub/sub enables multi-server deployments.

### Frontend (`static/js/taguette.js`)
- Single ~2000-line JS file; no build step required.
- Polls `/api/project/<id>/events` continuously.
- On each event, updates the document view, tag list, or highlight list.
- Uses jQuery for DOM manipulation and AJAX.
- i18n strings loaded from `/trans.js` (server-rendered catalog).

### i18n (`po/`)
- Two gettext catalogs: `main` (server/templates) and `javascript` (frontend).
- `.po` sources managed on Transifex; compiled to `.mo` files in `taguette/l10n/`.
- Language auto-detected from browser `Accept-Language`; user can override in account settings.

### Modes
| Mode | How started | Auth | DB |
|---|---|---|---|
| Single-user | `taguette` | Token URL, auto-login as `admin` | SQLite3 (auto-migrate) |
| Server | `taguette server <config>` | Username + password | PostgreSQL / MariaDB / SQLite3 (manual migrate) |

---

## Adding a New Feature — Checklist

1. **DB change?** → Add model fields in `database/models.py`, create a migration with `scripts/new_db_revision.sh`.
2. **New API endpoint?** → Add handler class in `web/api.py`, register route in `web/__init__.py → make_app()`.
3. **New page?** → Add handler in `web/views.py`, Jinja2 template in `templates/`, register route.
4. **New export format?** → Implement in `export.py`, add export handler in `web/export.py`, register route.
5. **Notify clients?** → Create a new `Command` type in `database/models.py → Command.TYPES`, add factory method, handle it in `taguette.js`.
6. **Translatable strings?** → Wrap with `self.gettext()` (Python) or `_()` (JS); regenerate `.pot` with `scripts/update_pot.sh`.
7. **Privileges?** → Add `can_*` method to `Privileges` enum in `models.py` and check it in the handler.
