-- lua/align_rfc/init.lua
local M = {}

-- ===== Config & helpers =====

local defaults = {
  -- Characters considered PBS (Potential Blank Spaces). Newlines aren't in a single line.
  -- Default: space + tab. Add others (e.g., U+3000) via :AlignRFC pbs=" \t\u{3000}"
  pbs_chars = " \t",

  -- Advisory only (content is always preserved); kept for parity with your spec.
  ignore_chars = "{}", -- e.g. "{}" to conceptually ignore braces (no-op in RFC v1)

  -- If true and no explicit :range, expand to contiguous nonblank block around cursor.
  -- If false, operate on current line only (unless a range is given).
  expand_block_when_no_range = true,
}

-- UTF-8 single-codepoint pattern (works in LuaJIT / Lua 5.1)
local UTF8_CHARPAT = "[%z\1-\127\194-\244][\128-\191]*"

local function to_set(s)
  local t = {}
  if not s then return t end
  for ch in s:gmatch(UTF8_CHARPAT) do
    t[ch] = true
  end
  return t
end

local function strw(s) return vim.fn.strdisplaywidth(s) end

-- Predicate factory: is this single UTF-8 character a PBS?
local function make_is_pbs(pbs_chars)
  local set = to_set(pbs_chars)
  return function(ch) return set[ch] == true end
end

-- Split a line into alternating PBS / NPBS fields, guaranteed to start with PBS (possibly empty).
-- Returns { fields... } where fields[1]=PBS, fields[2]=NPBS, fields[3]=PBS, ...
local function split_pbs_npbs(line, is_pbs)
  local fields = {}
  local buf = {}
  local at_pbs

  -- Peek first char to decide if we need an initial empty PBS.
  local first = line:match(UTF8_CHARPAT)
  if first == nil then
    -- Empty line -> PBS-only empty field (column 1 indent)
    table.insert(fields, "")
    return fields
  end
  if is_pbs(first) then
    at_pbs = true
  else
    -- Start with implicit empty PBS
    table.insert(fields, "")
    at_pbs = false
  end

  for ch in line:gmatch(UTF8_CHARPAT) do
    local blank = is_pbs(ch)
    if at_pbs == blank then
      table.insert(buf, ch)
    else
      -- boundary: flush previous field, switch mode
      table.insert(fields, table.concat(buf))
      buf = { ch }
      at_pbs = blank
    end
  end
  -- flush last field
  table.insert(fields, table.concat(buf))

  return fields
end

-- Convert alternating fields into "columns":
-- col 1: { indent = PBS }
-- col k>=2: { npbs = <NPBS>, pbs = <PBS> } (either may be "")
local function fields_to_columns(fields)
  local cols = {}
  local indent = fields[1] or ""
  cols[1] = { indent = indent }

  local idx = 2
  local colno = 2
  while idx <= #fields do
    local np = fields[idx] or ""
    local pb = fields[idx + 1] or ""
    cols[colno] = { npbs = np, pbs = pb }
    colno = colno + 1
    idx = idx + 2
  end
  return cols
end

-- Is a line PBS-only? (All characters are PBS, or empty)
local function is_pbs_only_line(line, is_pbs)
  if line == "" then return true end
  for ch in line:gmatch(UTF8_CHARPAT) do
    if not is_pbs(ch) then return false end
  end
  return true
end

-- ===== Range collection =====

local function get_target_range(opts, cfg)
  local bufnr = 0
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- 1) explicit :range (preferred)
  if opts and opts.line1 and opts.line2 and opts.line1 ~= 0 and opts.line2 ~= 0 then
    return opts.line1, opts.line2
  end

  -- 2) visual selection (if any)
  local mode = vim.fn.mode()
  if mode:match("[vV\22]") then
    local srow = vim.fn.getpos("v")[2]
    local erow = vim.fn.getpos(".")[2]
    if srow > erow then srow, erow = erow, srow end
    return srow, erow
  end

  -- 3) contiguous nonblank block around cursor (if enabled)
  if cfg.expand_block_when_no_range then
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local srow = cur
    while srow > 1 do
      local prev = vim.fn.getline(srow - 1)
      if prev:match("^%s*$") then break end
      srow = srow - 1
    end
    local erow = cur
    while erow < line_count do
      local nextl = vim.fn.getline(erow + 1)
      if nextl:match("^%s*$") then break end
      erow = erow + 1
    end
    return srow, erow
  end

  -- 4) fallback: current line only
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  return cur, cur
end

-- ===== Core align =====

function M.align(user_cfg, cmd_opts)
  local cfg = vim.tbl_deep_extend("force", {}, defaults, user_cfg or {})
  local bufnr = 0
  local is_pbs = make_is_pbs(cfg.pbs_chars)

  local srow, erow = get_target_range(cmd_opts, cfg)
  if not srow or not erow or srow > erow then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, srow - 1, erow, false)
  if #lines == 0 then return end

  -- Row storage
  -- rows[i] = { untouched=bool, columns=table|nil }
  local rows = {}
  local max_cols = 1 -- at least indentation column exists
  local any_for_widths = false

  -- Collect rows & determine max_cols
  -- IMPORTANT per your tweak:
  --  - Empty lines contribute column-1 width as 0 (columns={ [1]={indent=""} })
  --  - PBS-only lines contribute their PBS width to column 1 (columns={ [1]={indent=line} })
  for i, line in ipairs(lines) do
    if line == "" then
      rows[i] = { untouched = true, columns = { [1] = { indent = "" } } }
    elseif is_pbs_only_line(line, is_pbs) then
      rows[i] = { untouched = true, columns = { [1] = { indent = line } } }
    else
      local fields = split_pbs_npbs(line, is_pbs)
      local cols = fields_to_columns(fields)
      rows[i] = { untouched = false, columns = cols }
      local count = #cols
      if count > max_cols then max_cols = count end
      any_for_widths = true
    end
  end

  if not any_for_widths then
    -- Region contains only empty/PBS-only lines; nothing to align.
    return
  end

  -- Compute max cell width per column:
  --   c=1: max display width of indent PBS
  --   c>=2: max display width of (NPBS + PBS)
  local col_widths = {}
  for c = 1, max_cols do
    local mw = 0
    for _, row in ipairs(rows) do
      local cols = row.columns
      if cols then
        local cellw
        if c == 1 then
          local indent = (cols[1] and cols[1].indent) or ""
          cellw = strw(indent)
        else
          local cell = cols[c]
          if cell then
            cellw = strw(cell.npbs or "") + strw(cell.pbs or "")
          else
            cellw = 0
          end
        end
        if cellw > mw then mw = cellw end
      end
    end
    col_widths[c] = mw
  end

  -- Rebuild lines
  local out = {}
  for i, line in ipairs(lines) do
    local row = rows[i]
    if row.untouched then
      -- Empty / PBS-only lines print exactly as-is
      out[i] = line
    else
      local parts = {}
      local cols = row.columns

      -- Column 1: indent PBS only, pad to col_widths[1]
      do
        local indent = (cols[1] and cols[1].indent) or ""
        local w = strw(indent)
        local pad = col_widths[1] - w
        if pad < 0 then pad = 0 end
        table.insert(parts, indent .. string.rep(" ", pad))
      end

      -- Columns 2..max_cols: emit NPBS + PBS + spaces to reach col width
      for c = 2, max_cols do
        local np, pb = "", ""
        if cols[c] then
          np = cols[c].npbs or ""
          pb = cols[c].pbs or ""
        end
        local cellw = strw(np) + strw(pb)
        local pad = col_widths[c] - cellw
        if pad < 0 then pad = 0 end
        table.insert(parts, np .. pb .. string.rep(" ", pad))
      end

      out[i] = table.concat(parts)
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, srow - 1, erow, false, out)
end

-- ===== Command setup =====

function M.setup(user_cfg)
  local base_cfg = vim.tbl_deep_extend("force", {}, defaults, user_cfg or {})
  vim.api.nvim_create_user_command("AlignRFC", function(opts)
    local o = vim.tbl_deep_extend("force", {}, base_cfg)
    -- Parse k=v args: pbs=..., ignore=..., block=false|true
    for _, kv in ipairs(opts.fargs) do
      local k, v = kv:match("^([%w_]+)=(.+)$")
      if k then
        if v == "true" then v = true elseif v == "false" then v = false end
        if k == "pbs" then
          o.pbs_chars = tostring(v)
        elseif k == "ignore" then
          o.ignore_chars = tostring(v)
        elseif k == "block" then
          o.expand_block_when_no_range = v and true or false
        end
      end
    end
    M.align(o, opts)
  end, { nargs = "*", range = true, desc = "Align columns per PBS/NPBS RFC" })
end

return M

