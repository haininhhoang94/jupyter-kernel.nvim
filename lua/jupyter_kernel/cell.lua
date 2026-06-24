---`# %%`-cell detection + byte-offset translation for the virtual LSP.
---
---Self-contained (no dependency on other plugins). Positions are byte-based to
---match the LSP server's advertised ``positionEncoding = "utf-8"`` and Jupyter's
---byte cursor_pos, so translation is pure arithmetic.

local M = {}

-- Cell delimiter: a `# %%` line (optionally indented), matching the percent
-- format used by jupytext / pyrepl.
local CELL_PATTERN = "^%s*# %%%%"

---@class jupyter_kernel.Cell
---@field start_row integer  0-indexed buffer row of the cell's first line
---@field source string[]    the cell's lines (marker line included)

---Return the cell containing 0-indexed buffer ``line`` (clamped to range).
---@param bufnr integer
---@param line integer  0-indexed
---@return jupyter_kernel.Cell|nil
function M.get_cell_at(bufnr, line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n = #lines
  if n == 0 then
    return nil
  end
  if line < 0 then
    line = 0
  elseif line > n - 1 then
    line = n - 1
  end

  -- start: nearest marker at or above `line`, else top of buffer
  local start = 0
  for i = line, 0, -1 do
    if lines[i + 1] and lines[i + 1]:match(CELL_PATTERN) then
      start = i
      break
    end
  end

  -- stop: line before the next marker below `line`, else end of buffer
  local stop = n - 1
  for i = line + 1, n - 1 do
    if lines[i + 1]:match(CELL_PATTERN) then
      stop = i - 1
      break
    end
  end

  local source = {}
  for i = start, stop do
    source[#source + 1] = lines[i + 1]
  end
  return { start_row = start, source = source }
end

---Convert an LSP position (0-indexed line/character, byte units) into the byte
---offset within ``table.concat(cell.source, "\n")``.
---@param cell jupyter_kernel.Cell
---@param position {line: integer, character: integer}
---@return integer
function M.position_to_offset(cell, position)
  local rel = position.line - cell.start_row
  if rel < 0 then
    rel = 0
  end
  local offset = 0
  for i = 1, rel do
    offset = offset + #(cell.source[i] or "") + 1
  end
  local cur_line = cell.source[rel + 1] or ""
  local col = position.character
  if col > #cur_line then
    col = #cur_line
  end
  return offset + col
end

---Inverse of position_to_offset.
---@param cell jupyter_kernel.Cell
---@param byte_offset integer
---@return {line: integer, character: integer}
function M.offset_to_position(cell, byte_offset)
  local pos = 0
  for i, line in ipairs(cell.source) do
    local line_len = #line
    if pos + line_len >= byte_offset then
      return { line = cell.start_row + i - 1, character = byte_offset - pos }
    end
    pos = pos + line_len + 1
  end
  local last_idx = #cell.source
  local last = cell.source[last_idx] or ""
  return {
    line = cell.start_row + math.max(last_idx - 1, 0),
    character = #last,
  }
end

return M
