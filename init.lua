-- lua/align_rfc/init.lua
local M = {}

-- ===================== Config & helpers =====================

local defaults = {
  -- Characters considered PBS (Potential Blank Spaces).
  -- Example to include braces as PBS: pbs_chars = " \t{}"
  pbs_chars = " \t",

  -- Subset of PBS that are "ignored PBS" (preserved exactly, zero-width for alignment).
  -- MUST be a subset of pbs_chars for intended behavior.
  ignored_pbs_chars = "",

  -- If no explicit :range is given, expand to contiguous nonblank block around cursor.
  expand_block_when_no_range = true,
}

-- UTF-8 single-codepoint pattern (LuaJIT / Lua 5.1 safe)
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

-- Predicates for PBS / ignored-PBS (single codepoint)
local function make_is_pbs(pbs_chars)
  local set = to_set(pbs_chars)
  return function(ch) return set[ch] == true end
end
local function make_is_ignored(ignored_chars)
  local set = to_set(ignored_chars)
  return function(ch) return set[ch] == true end
end

-- ===================== Parsing (PBS / NPBS) =====================

-- Split a line into alternating PBS / NPBS fields, guaranteed to start with PBS (possibly empty).
-- Returns { fields... } where fields[1]=PBS, fields[2]=NPBS, fields[3]=PBS, ...
local function split_pbs_npbs(line, is_pbs)
  local fields = {}
  local buf = {}
  local at_pbs

  local first = line:match(UTF8_CHARPAT)
  if first == nil then
    table.insert(fields, "") -- empty line -> PBS-only empty field
    return fields
  end

  if is_pbs(first) then
    at_pbs = true
  else
    table.insert(fields, "") -- begin with implicit empty PBS
    at_pbs = false
  end

  for ch in line:gmatch(UTF8_CHARPAT) do
    local blank = is_pbs(ch)
    if at_pbs == blank then
      table.insert(buf, ch)
    else
      table.insert(fields, table.concat(buf))
      buf = { ch }
      at_pbs = blank
    end
  end
  table.insert(fields, table.concat(buf))
  return fields
end

-- Convert alternating fields into "columns":
-- col 1: { indent = <PBS> }
-- col k>=2: { npbs = <NPBS>, pbs = <PBS> } (either may be "")
local function fields_to_columns(fields)
  local cols = {}
  cols[1] = { indent = fields[1] or "" }
  local idx, colno = 2, 2
  while idx <= #fields do
    local np = fields[idx] or ""
    local pb = fields[idx + 1] or ""
    cols[colno] = { npbs = np, pbs = pb }
    colno = colno + 1
    idx = idx + 2
  end
  return cols
end

-- Is a line PBS-only? (All characters are PBS, or line is empty)
local function is_pbs_only_line(line, is_pbs)
  if line == "" then return true end
  for ch in line:gmatch(UTF8_CHARPAT) do
    if not is_pbs(ch) then return false end
  end
  return true
end

-- Visible width of a PBS block, excluding ignored PBS characters
local function visible_pbs_width(pbs, is_ignored_pbs)
  if pbs == "" then return 0 end
  local w = 0
  for ch in pbs:gmatch(UTF8_CHARPAT) do
    if not is_ignored_pbs(ch) then
      w = w + strw(ch)
    end
  end
  return w
end

-- Compute cell visible width for c>=2 as NPBS + PBS(excluding ignored)
local function visible_cell_width(npbs, pbs, is_ignored_pbs)
  return strw(npbs or "") + visible_pbs_width(pbs or "", is_ignored_pbs)
end

-- ===================== Range collection =====================

local function get_target_range(opts, cfg)
  local bufnr = 0
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- 1) explicit :range
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

  -- 3) contiguous nonblank block around cursor
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

-- ===================== Core align =====================

function M.align(user_cfg, cmd_opts)
  local cfg = vim.tbl_deep_extend("force", {}, defaults, user_cfg or {})
  local bufnr = 0

  local is_pbs = make_is_pbs(cfg.pbs_chars)
  local is_ignored_pbs = make_is_ignored(cfg.ignored_pbs_chars)

  local srow, erow = get_target_range(cmd_opts, cfg)
  if not srow or not erow or srow > erow then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, srow - 1, erow, false)
  if #lines == 0 then return end

  -- rows[i] = { untouched=bool, columns=table }
  local rows = {}
  local max_cols = 1
  local any_for_widths = false

  -- Collect rows & determine max_cols
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
    return -- only empty/PBS-only lines
  end

  -- Compute max cell width per column:
  --   c=1: max visible width of indent PBS (excluding ignored PBS)
  --   c>=2: max visible width of NPBS + PBS(excluding ignored PBS)
  local col_widths = {}
  for c = 1, max_cols do
    local mw = 0
    for _, row in ipairs(rows) do
      local cols = row.columns
      if cols then
        local cellw
        if c == 1 then
          local indent = (cols[1] and cols[1].indent) or ""
          cellw = visible_pbs_width(indent, is_ignored_pbs)
        else
          local cell = cols[c]
          if cell then
            cellw = visible_cell_width(cell.npbs, cell.pbs, is_ignored_pbs)
          else
            cellw = 0
          end
        end
        if cellw > mw then mw = cellw end
      end
    end
    col_widths[c] = mw
  end

  -- Rebuild lines.
  -- We never modify the original PBS content (including ignored PBS).
  -- We only append standard spaces AFTER each column's cell to reach col_widths[c].
  local out = {}
  for i, line in ipairs(lines) do
    local row = rows[i]
    if row.untouched then
      out[i] = line -- print verbatim
    else
      local parts = {}
      local cols = row.columns

      -- Column 1: indent PBS only; pad after it to reach col_widths[1] (visible width basis)
      do
        local indent = (cols[1] and cols[1].indent) or ""
        local w = visible_pbs_width(indent, is_ignored_pbs)
        local pad = col_widths[1] - w
        if pad < 0 then pad = 0 end
        table.insert(parts, indent .. string.rep(" ", pad))
      end

      -- Columns 2..max_cols: NPBS + PBS + pad (pad based on visible width)
      for c = 2, max_cols do
        local np, pb = "", ""
        if cols[c] then
          np = cols[c].npbs or ""
          pb = cols[c].pbs or ""
        end

        local w = visible_cell_width(np, pb, is_ignored_pbs)
        local pad = col_widths[c] - w
        if pad < 0 then pad = 0 end

        table.insert(parts, np .. pb .. string.rep(" ", pad))
      end

      out[i] = table.concat(parts)
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, srow - 1, erow, false, out)
end

-- ===================== Command setup =====================

function M.setup(user_cfg)
  local base_cfg = vim.tbl_deep_extend("force", {}, defaults, user_cfg or {})
  vim.api.nvim_create_user_command("AlignRFC", function(opts)
    local o = vim.tbl_deep_extend("force", {}, base_cfg)
    -- CLI: pbs=..., ignoredpbs=..., block=true|false
    for _, kv in ipairs(opts.fargs) do
      local k, v = kv:match("^([%w_]+)=(.+)$")
      if k then
        if v == "true" then v = true elseif v == "false" then v = false end
        if k == "pbs" then
          o.pbs_chars = tostring(v)
        elseif k == "ignoredpbs" then
          o.ignored_pbs_chars = tostring(v)
        elseif k == "block" then
          o.expand_block_when_no_range = v and true or false
        end
      end
    end
    M.align(o, opts)
  end, { nargs = "*", range = true, desc = "Align per PBS/NPBS RFC v2 (ignored PBS supported)" })
end

return M

