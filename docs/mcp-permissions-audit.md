# MCP Permissions Audit — Security Reference

**Purpose**: Document the tools exposed by each MCP server, classify their risk level,
and establish which operations require guardian rules or user confirmation.

---

## Risk Classification

| Level | Meaning | Guardian Rule? | Examples |
|-------|---------|----------------|----------|
| **R** (Read) | Read-only, no side effects | No | search, list, get, read |
| **W** (Write) | Creates or modifies resources | No (usually) | create file, add comment |
| **D** (Destructive) | Deletes or overwrites irreversibly | **Yes** | delete repo, drop table |
| **F** (Financial) | Involves money or billing | **Yes** | create charge, purchase |
| **P** (Public) | Changes public visibility | **Yes** | publish, make public |
| **A** (Auth) | Modifies access/permissions | **Yes** | share doc, grant access |

---

## Installed MCP Servers

### GitHub MCP (`mcp__github__*`)

| Tool | Risk | Notes |
|------|------|-------|
| `get_file_contents`, `search_code`, `list_*`, `get_*` | R | Safe |
| `create_branch`, `create_pull_request`, `add_issue_comment` | W | Level 2 |
| `push_files`, `create_or_update_file` | W | Level 2 — creates commits |
| `merge_pull_request` | W | Level 3 — merges code |
| `delete_file` | D | Guardian: blocks `gh repo delete` equivalent |
| `create_repository` | W | Level 3 — creates public resource |
| `fork_repository` | W | Level 2 |

**Guardian rules needed**: None additional (already covered by Category 7).

### Playwright MCP (`mcp__playwright__*`)

| Tool | Risk | Notes |
|------|------|-------|
| `browser_snapshot`, `browser_tabs`, `browser_console_messages` | R | Safe |
| `browser_navigate`, `browser_click`, `browser_type`, `browser_fill_form` | W | Level 2 — side effects depend on target |
| `browser_evaluate`, `browser_run_code` | **D** | Can execute arbitrary JS in page context |
| `browser_file_upload` | W | Level 3 — uploads files |

**Guardian rules needed**:
- `browser_evaluate` and `browser_run_code` should NOT be used to exfiltrate credentials from pages
- Already covered by: guardian blocks credential piping to network tools

### Filesystem MCP (`mcp__filesystem__*`)

| Tool | Risk | Notes |
|------|------|-------|
| `read_file`, `read_text_file`, `read_multiple_files`, `list_directory`, `directory_tree`, `search_files`, `get_file_info` | R | Safe |
| `write_file`, `edit_file`, `create_directory` | W | Level 1-2 |
| `move_file` | W | Level 2 — can overwrite |

**Guardian rules needed**: None — filesystem MCP is restricted to allowed directories.

### Gmail MCP (`mcp__claude_ai_Gmail__*`)

| Tool | Risk | Notes |
|------|------|-------|
| `gmail_search_messages`, `gmail_read_message`, `gmail_read_thread`, `gmail_get_profile`, `gmail_list_labels`, `gmail_list_drafts` | R | Safe |
| `gmail_create_draft` | W | Level 3 — creates email draft |

**Guardian rules needed**: No send capability exposed (only draft creation).

### Google Calendar MCP (`mcp__claude_ai_Google_Calendar__*`)

| Tool | Risk | Notes |
|------|------|-------|
| `gcal_list_calendars`, `gcal_list_events`, `gcal_get_event`, `gcal_find_meeting_times`, `gcal_find_my_free_time` | R | Safe |
| `gcal_create_event` | W | Level 3 — creates calendar events |
| `gcal_update_event`, `gcal_respond_to_event` | W | Level 2 |
| `gcal_delete_event` | D | Level 3 — deletes events |

**Guardian rules needed**: Calendar deletion should prompt user.

### Computer Use MCP (`mcp__computer-use__*`)

| Tool | Risk | Notes |
|------|------|-------|
| `screenshot`, `cursor_position`, `list_granted_applications`, `read_clipboard` | R | Safe |
| `left_click`, `right_click`, `double_click`, `type`, `key`, `scroll`, `mouse_move` | W | Level 2 — UI automation |
| `open_application` | W | Level 2 |
| `write_clipboard` | W | Level 1 |

**Usage policy**: Computer Use is ONLY for native desktop apps with no browser version (e.g., Xcode, iOS Simulator). Never use for websites or services with web interfaces — use Playwright for those. Requires `request_access` per application — built-in safety.

### Memory MCP (`mcp__memory__*`)

| Tool | Risk | Notes |
|------|------|-------|
| `read_graph`, `search_nodes`, `open_nodes` | R | Safe |
| `create_entities`, `create_relations`, `add_observations` | W | Level 1 |
| `delete_entities`, `delete_relations`, `delete_observations` | D | Level 2 — deletes memory |

**Guardian rules needed**: None — memory is internal to autopilot.

### Backend Max MCP (`mcp__backend-max__*`)

| Tool | Risk | Notes |
|------|------|-------|
| `get_context`, `get_api_docs`, `get_patterns`, `get_ledger`, `scan_routes`, `trace_types` | R | Safe |
| `init_context`, `update_context`, `run_diagnosis`, `audit_*`, `check_*`, `scan_dependencies` | R | Analysis only |
| `fix_issue`, `fix_all_issues` | **W** | Level 3 — modifies code |
| `live_test` | W | Level 2 — runs tests |

**Guardian rules needed**: `fix_all_issues` should be used with caution — review changes after.

---

## Custom Guardian Rules for MCP Operations

The following rules are appended to `guardian-custom-rules.txt`:

```
# MCP-specific guardian rules (Phase 6, Tier 4)
# These protect against dangerous MCP tool misuse
```

**Note**: MCP tools bypass Bash guardian since they're not Bash commands.
The Write/Edit tool protection in guardian.sh handles file-level protection.
For MCP-specific safety, the agent's decision framework (Levels 1-5) is the primary control.

---

## Recommendations

1. **Never use `browser_evaluate` to extract credentials from web pages** — use browser_snapshot + parsing instead
2. **Never use `fix_all_issues` without reviewing the diff afterward**
3. **Calendar and email operations always need Level 3+ confirmation**
4. **MCP kill protection is critical** — guardian custom rules already block `kill.*mcp` and `pkill.*mcp`
5. **Filesystem MCP respects directory boundaries** — no additional guardian rules needed
