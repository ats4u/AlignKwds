-- lua/align_kwds/init.lua
local M = {}

-- ===================== Config & helpers =====================

local defaults = {
  -- Characters considered PBS (Potential Blank Spaces).
  -- Default: space + tab. Add more via :AlignKwds pbs=" \t{}"
  pbs_chars = " \t",

  -- NEW: sequences that behave like PBS (matched longest-first), e.g. {"\\sp","\\sw"}
  pbs_keywords = {},

  -- Recognize PBS keywords inside spans? (default false: spans stay indivisible NPBS)
  pbs_keywords_in_spans = false,

  -- Spans (NPBS blocks): contents are NPBS as a unit, even if they contain PBS.
  -- Defaults protect quotes and parentheses (not braces).
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

-- Encode Unicode codepoint to UTF-8 (Lua 5.1)
local function cp_to_utf8(n)
  if n < 0x80 then
    return string.char(n)
  elseif n < 0x800 then
    return string.char(0xC0 + math.floor(n/0x40),
                       0x80 + (n % 0x40))
  elseif n < 0x10000 then
    return string.char(0xE0 + math.floor(n/0x1000),
                       0x80 + (math.floor(n/0x40) % 0x40),
                       0x80 + (n % 0x40))
  else
    return string.char(0xF0 + math.floor(n/0x40000),
                       0x80 + (math.floor(n/0x1000) % 0x40),
                       0x80 + (math.floor(n/0x40) % 0x40),
                       0x80 + (n % 0x40))
  end
end

-- Unquote "..." or '...' and handle escapes like \t, \n, \u{XXXX}
local function unquote_and_unescape(s)
  if not s then return "" end
  -- strip one layer of matching quotes if present
  if (#s >= 2) and
     ((s:sub(1,1) == '"' and s:sub(-1) == '"') or
      (s:sub(1,1) == "'" and s:sub(-1) == "'")) then
    s = s:sub(2, -2)
  end
  -- \u{XXXX} → UTF-8
  s = s:gsub("\\u{%x+}", function(m)
    local hex = m:match("%x+")
    local cp = tonumber(hex, 16)
    if not cp then return "" end
    return cp_to_utf8(cp)
  end)
  -- \xNN → byte
  s = s:gsub("\\x(%x%x)", function(h)
    return string.char(tonumber(h,16))
  end)
  -- simple escapes
  s = s
    :gsub("\\t", "\t")
    :gsub("\\n", "\n")
    :gsub("\\r", "\r")
    :gsub("\\\\", "\\")
    :gsub('\\"', '"')
    :gsub("\\'", "'")
  return s
end

-- Parse opts.args into { [k]=v, ... } with quoted values and spaces supported
local function parse_kv_args(raw)
  local args = {}
  if not raw or raw == "" then return args end
  local i, n = 1, #raw

  local function skip_ws()
    while i <= n and raw:sub(i,i):match("%s") do i = i + 1 end
  end

  local function read_key()
    local s = i
    while i <= n and raw:sub(i,i):match("[%w_]") do i = i + 1 end
    if i > n or raw:sub(i,i) ~= "=" then return nil end
    local key = raw:sub(s, i-1)
    i = i + 1 -- skip '='
    return key
  end

  local function read_val()
    if i > n then return "" end
    local ch = raw:sub(i,i)
    if ch == '"' or ch == "'" then
      local quote = ch
      i = i + 1
      local buf = {}
      while i <= n do
        local c = raw:sub(i,i)
        if c == "\\" then
          if i < n then
            table.insert(buf, raw:sub(i, i+1))
            i = i + 2
          else
            table.insert(buf, "\\")
            i = i + 1
          end
        elseif c == quote then
          i = i + 1
          break
        else
          table.insert(buf, c)
          i = i + 1
        end
      end
      return unquote_and_unescape(quote .. table.concat(buf) .. quote)
    else
      local s = i
      while i <= n and not raw:sub(i,i):match("%s") do i = i + 1 end
      return unquote_and_unescape(raw:sub(s, i-1))
    end
  end

  while i <= n do
    skip_ws()
    if i > n then break end
    local key = read_key()
    if not key then break end
    local val = read_val()
    args[key] = val
    skip_ws()
  end
  return args
end

-- Next codepoint starting at byte index idx (1-based). Returns (cp, next_idx).
local function next_cp(line, idx)
  local cp = line:match(UTF8_CHARPAT, idx)
  if not cp then return nil, idx end
  return cp, idx + #cp
end

-- Build keyword matcher (longest-first)
local function make_keyword_matcher(list)
  if not list or #list == 0 then
    return function(_, _) return nil, nil end
  end
  -- copy & sort by length desc
  local kws = {}
  for _, s in ipairs(list) do
    if s and s ~= "" then table.insert(kws, s) end
  end
  table.sort(kws, function(a,b) return #a > #b end)
  return function(line, i)
    for _, kw in ipairs(kws) do
      if line:sub(i, i + #kw - 1) == kw then
        return kw, i + #kw
      end
    end
    return nil, nil
  end
end

-- ===================== Span-aware PBS/NPBS splitting =====================

-- Split into alternating PBS / NPBS fields, starting with PBS (possibly empty).
-- Spans (from protected_pairs) are treated as indivisible NPBS blocks.
local function split_pbs_npbs_spanaware(line, is_pbs, open_to_close, escape_char, kw_match, kw_in_spans)
  local fields, buf = {}, {}
  local n = #line

  -- initial state
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
      -- Inside a span: everything is NPBS until we close the current span.
      if at_pbs then
        table.insert(fields, table.concat(buf)); buf = {}; at_pbs = false
      end
      -- If we choose to honor keywords inside spans (usually false)
      if kw_in_spans then
        local kw, k = kw_match(line, i)
        if kw then
          -- still NPBS (since we're inside a span) -> just append keyword literally
          table.insert(buf, kw)
          i = k
          goto continue
        end
      end
      -- 1) escape?
      if ch == escape_char then
        local ch2, k = next_cp(line, j)
        if ch2 then
          table.insert(buf, ch .. ch2); i = k
        else
          table.insert(buf, ch); i = j
        end
      -- 2) close current span FIRST (important for symmetric delimiters like ")
      elseif ch == stack[#stack] then
        table.insert(buf, ch)
        table.remove(stack)
        i = j
      -- 3) nested open (but NEVER nest same symmetric delimiter)
      elseif open_to_close[ch] and open_to_close[ch] ~= ch then
        table.insert(stack, open_to_close[ch])
        table.insert(buf, ch)
        i = j
      else
        table.insert(buf, ch); i = j
      end

    else
      -- Outside any span: keywords act like PBS (matched longest-first)
      local kw, k = kw_match(line, i)
      if kw then
        if at_pbs then
          table.insert(buf, kw)
        else
          table.insert(fields, table.concat(buf))
          buf = { kw }
          at_pbs = true
        end
        i = k
        goto continue
      end

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
    ::continue::
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

-- PBS-only line detection now respects keywords (outside spans)
local function is_pbs_only_line(line, is_pbs, kw_match, open_to_close)
  if line == "" then return true end
  local i, n = 1, #line
  local stack = {}
  while i <= n do
    -- inside span => not PBS-only
    if #stack > 0 then return false end
    local kw, k = kw_match(line, i)
    if kw then
      i = k
    else
      local ch, j = next_cp(line, i)
      if not ch then break end
      local closer = open_to_close[ch]
      if closer then
        return false
      end
      if not is_pbs(ch) then
        return false
      end
      i = j
    end
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
  local kw_match = make_keyword_matcher(cfg.pbs_keywords or {})
  local kw_in_spans = cfg.pbs_keywords_in_spans and true or false

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
    elseif is_pbs_only_line(line, is_pbs, kw_match, open_to_close) then
      rows[i] = { untouched = true, columns = { [1] = { indent = line } } }
    else
      local fields = split_pbs_npbs_spanaware(line, is_pbs, open_to_close, esc, kw_match, kw_in_spans)
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

  -- Rebuild lines using only the columns that actually exist on that row (idempotent)
  local out = {}
  for i, line in ipairs(lines) do
    local row = rows[i]
    if row.untouched then
      out[i] = line -- verbatim
    else
      local parts = {}
      local cols = row.columns
      local last_col = #cols

      -- Column 1: indent PBS only
      do
        local indent = (cols[1] and cols[1].indent) or ""
        local w = strw(indent)
        local pad = col_widths[1] - w
        if pad < 0 then pad = 0 end
        table.insert(parts, indent .. string.rep(" ", pad))
      end

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

local function split_keywords_list(s)
  -- split on commas and/or whitespace; ignore empties
  local out = {}
  for token in s:gmatch("[^,%s]+") do
    table.insert(out, token)
  end
  return out
end

function M.setup(user_cfg)
  local base_cfg = vim.tbl_deep_extend("force", {}, defaults, user_cfg or {})
  vim.api.nvim_create_user_command("AlignKwds", function(opts)
    local o = vim.tbl_deep_extend("force", {}, base_cfg)

    -- Robust arg parsing from raw string (supports quoted values & escapes)
    local kv = (function(raw)
      local t = parse_kv_args(raw)
      -- unescape already applied inside parse_kv_args
      return t
    end)(opts.args)

    if kv.pbs ~= nil then
      o.pbs_chars = kv.pbs
    end
    if kv.pbskw ~= nil then
      -- Example: pbskw="\\sp \\sw"  or pbskw="\\sp,\\sw"
      o.pbs_keywords = split_keywords_list(kv.pbskw)
    end
    if kv.pbskw_in_spans ~= nil then
      o.pbs_keywords_in_spans = (kv.pbskw_in_spans == "true" or kv.pbskw_in_spans == true)
    end
    if kv.pairs ~= nil then
      -- pairs example: pairs="() \"\" []"
      local P = {}
      local s = kv.pairs
      local i, n = 1, #s
      while i <= n do
        while i <= n and s:sub(i,i):match("%s") do i = i + 1 end
        if i > n then break end
        local op = s:sub(i,i); i = i + 1
        while i <= n and s:sub(i,i):match("%s") do i = i + 1 end
        if i > n then break end
        local cl = s:sub(i,i); i = i + 1
        table.insert(P, {op, cl})
      end
      if #P > 0 then o.protected_pairs = P end
    end
    if kv.esc ~= nil then
      o.escape_char = kv.esc
    end
    if kv.block ~= nil then
      o.expand_block_when_no_range = (kv.block == "true" or kv.block == true)
    end

    M.align(o, opts)
  end, { nargs = "*", range = true, desc = "Align per PBS/NPBS (v2.3, keywords as PBS)" })
end

return M

