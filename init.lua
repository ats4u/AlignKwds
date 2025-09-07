-- lua/align_rfc/init.lua
local M = {}

-- ===================== Config & helpers =====================

local defaults = {
  -- Characters considered PBS (Potential Blank Spaces).
  -- Default: space + tab. Add more (e.g., braces) via: :AlignRFC pbs=" \t{}"
  pbs_chars = " \t",

  -- Spans (NPBS blocks): contents are NPBS as a unit, even if they contain PBS.
  -- Defaults protect quotes and parentheses (not braces).
  -- protected_pairs = { {'"', '"'}, {'(', ')'} },

  protected_pairs = {
    { "'", "'" },
    { '"', '"' },
    { '(', ')' },
    { '{', '}' },
    { '[', ']' },
  },

  -- Escape char inside spans (skips next codepoint literally)
  escape_char = "\\",

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

local function make_is_pbs(pbs_chars)
  local set = to_set(pbs_chars)
  return function(ch) return set[ch] == true end
end

local function mk_pair_maps(pairs)
  local open_to_close, close_set = {}, {}
  for _, p in ipairs(pairs or {}) do
    open_to_close[p[1]] = p[2]
    close_set[p[2]] = true
  end
  return open_to_close, close_set
end

-- Next codepoint starting at byte index idx (1-based). Returns (cp, next_idx).
local function next_cp(line, idx)
  local cp = line:match(UTF8_CHARPAT, idx)
  if not cp then return nil, idx end
  return cp, idx + #cp
end

-- ===================== Span-aware PBS/NPBS splitting =====================

-- Split into alternating PBS / NPBS fields, starting with PBS (possibly empty).
-- Spans (from protected_pairs) are treated as indivisible NPBS blocks.
local function split_pbs_npbs_spanaware(line, is_pbs, open_to_close, escape_char)
  local fields, buf = {}, {}
  local n = #line

  -- Decide initial state: if first char is PBS, start in PBS; else inject empty PBS.
  local first = line:match(UTF8_CHARPAT)
  local at_pbs
  if first == nil then
    table.insert(fields, "") -- empty line -> single empty PBS
    return fields
  end
  if is_pbs(first) then
    at_pbs = true
  else
    table.insert(fields, "") -- implicit leading PBS
    at_pbs = false
  end

  local i = 1
  local stack = {} -- stack of expected closers

  while i <= n do
    local ch, j = next_cp(line, i)
    if not ch then break end

    if #stack > 0 then
      -- Inside a span: everything belongs to NPBS until the matching closer.
      if at_pbs then
        table.insert(fields, table.concat(buf)); buf = {}; at_pbs = false
      end
      if ch == escape_char then
        local ch2, k = next_cp(line, j)
        if ch2 then
          table.insert(buf, ch .. ch2); i = k
        else
          table.insert(buf, ch); i = j
        end
      -- 2) close current span (MUST check before considering nested opens)
      elseif ch == stack[#stack] then
        table.insert(buf, ch)
        table.remove(stack)
        i = j
      -- 3) nested open (but NEVER nest same symmetric delimiter like '"')
      elseif open_to_close[ch] ~= nil then
        -- nested span
        table.insert(stack, open_to_close[ch])
        table.insert(buf, ch); i = j
      else
        table.insert(buf, ch); i = j
      end

    else
      -- Outside span
      local closer = open_to_close[ch]
      if closer ~= nil then
        -- Start a new span (NPBS). Spans take precedence over PBS.
        if at_pbs then
          table.insert(fields, table.concat(buf)); buf = {}; at_pbs = false
        end
        table.insert(stack, closer)
        table.insert(buf, ch)
        i = j
      else
        local blank = is_pbs(ch)
        if at_pbs == blank then
          table.insert(buf, ch); i = j
        else
          table.insert(fields, table.concat(buf))
          buf = { ch }
          at_pbs = blank
          i = j
        end
      end
    end
  end

  table.insert(fields, table.concat(buf))
  return fields
end

-- Convert alternating fields to column cells:
--   col 1: { indent = PBS }
--   col k>=2: { npbs = <NPBS>, pbs = <PBS> }  (either may be "")
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

local function is_pbs_only_line(line, is_pbs)
  if line == "" then return true end
  for ch in line:gmatch(UTF8_CHARPAT) do
    if not is_pbs(ch) then return false end
  end
  return true
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
  local open_to_close = mk_pair_maps(cfg.protected_pairs)
  local esc = cfg.escape_char or "\\"

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
      local fields = split_pbs_npbs_spanaware(line, is_pbs, open_to_close, esc)
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
  --   c=1: max width of indent PBS
  --   c>=2: max width of (NPBS + PBS) combined
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

  -- Rebuild lines up to max_cols (synthesizing empty trailing cells)
  local out = {}
  for i, line in ipairs(lines) do
    local row = rows[i]
    if row.untouched then
      out[i] = line -- verbatim
    else
      local parts = {}
      local cols = row.columns
      local last_col = #cols  -- emit only the columns that actually exist on this row

      -- Column 1: indent PBS only
      do
        local indent = (cols[1] and cols[1].indent) or ""
        local w = strw(indent)
        local pad = col_widths[1] - w
        if pad < 0 then pad = 0 end
        table.insert(parts, indent .. string.rep(" ", pad))
      end

      -- Sun, 07 Sep 2025 08:44:59 +0900
      -- for c = 2, max_cols do
      for c = 2, last_col do
        local np, pb = "", ""
        if cols[c] then
          np = cols[c].npbs or ""
          pb = cols[c].pbs or ""
        end
        local w = strw(np) + strw(pb)
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
    -- CLI: pbs=..., pairs="() \"\"" esc=\\, block=true|false
    for _, kv in ipairs(opts.fargs) do
      local k, v = kv:match("^([%w_]+)=(.+)$")
      if k then
        if v == "true" then v = true elseif v == "false" then v = false end
        if k == "pbs" then
          o.pbs_chars = tostring(v)
        elseif k == "pairs" then
          -- pairs example: pairs="() \"\" []"
          local P = {}
          for op, cl in v:gmatch("(%S)%s*(%S)") do table.insert(P, {op, cl}) end
          o.protected_pairs = P
        elseif k == "esc" then
          o.escape_char = tostring(v)
        elseif k == "block" then
          o.expand_block_when_no_range = v and true or false
        end
      end
    end
    M.align(o, opts)
  end, { nargs = "*", range = true, desc = "Align per PBS/NPBS (v2, span-aware NPBS)" })
end

return M

