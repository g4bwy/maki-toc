-- Wiki-style Contents pane for the chat transcript.
--
-- A left split lists every user turn; folding one open shows its thinking
-- and reply blocks. Clicking or pressing M-CR scrolls the chat to the
-- picked block; clicking the marker folds. The pane pins the session it was
-- opened in, so a refresh that lands while another tab is focused still
-- lists its own transcript. Needs a maki build with
-- maki.ui.transcript_outline, maki.ui.scroll_to_block and window click
-- events (win:recv type "click").

local PANE_WIDTH = 34
local TITLE = " Contents "
local NUM_W = 3
local COL_PREFIX_W = NUM_W + 3
local SUB_PREFIX = string.rep(" ", COL_PREFIX_W) .. ". "
local MARKER_COLLAPSED = "▸"
local MARKER_EXPANDED = "▾"
local MARKER_NONE = " "
local EMPTY_LABEL = "no turns yet"
local NO_JUMP_API = "maki-toc needs maki PR 1155 (transcript outline api)"
local NAV_KEYS = { "<M-j>", "<M-k>", "<M-CR>", "<M-Up>", "<M-Down>", "<M-o>" }

-- Kinds this pane knows how to place in the tree. The host may publish more
-- later, and an entry of an unknown kind is skipped rather than listed as a
-- row that jumps somewhere unexplained.
local TURN_KIND = "turn"
local SUB_KINDS = { thinking = true, reply = true }

local pane = nil
local rebuild

-- The outline call already filtered to jumpable blocks and ranked them in
-- display order; grouping is all that is left. A turn opens a group, the
-- thinking and reply entries that follow join it. Each row keeps the id of
-- its entry, the one address maki.ui.scroll_to_block takes, so a jump lands
-- on the block the row was listed for even after the transcript moved on.
local function build_turns(session)
  local items, err = maki.ui.transcript_outline({ session = session })
  if not items then
    return nil, err
  end
  local turns = {}
  for _, item in ipairs(items) do
    if item.kind == TURN_KIND then
      turns[#turns + 1] = { text = item.text, id = item.id, blocks = {}, kind_seen = {} }
    elseif SUB_KINDS[item.kind] and #turns > 0 then
      local turn = turns[#turns]
      turn.kind_seen[item.kind] = (turn.kind_seen[item.kind] or 0) + 1
      turn.blocks[#turn.blocks + 1] = {
        id = item.id,
        label = item.kind .. " " .. turn.kind_seen[item.kind],
      }
    end
  end
  return turns
end

local ELLIPSIS = "..."
local function clip(text, width)
  if width <= 0 then
    return ""
  end
  if maki.ui.display_width(text) <= width then
    return text
  end
  if width <= #ELLIPSIS then
    return maki.ui.truncate_text(text, width).head
  end
  return maki.ui.truncate_text(text, width - #ELLIPSIS).head .. ELLIPSIS
end

local function render(p)
  if #p.turns == 0 then
    p.buf:set_lines({ { { EMPTY_LABEL, "dim" } } })
    p.row_map = {}
    p.row_headers = {}
    return
  end
  local lines, row_map, row_headers = {}, {}, {}
  local text_width = p.width - COL_PREFIX_W
  for n, turn in ipairs(p.turns) do
    local expanded = p.expanded[turn.id]
    local marker = MARKER_NONE
    if #turn.blocks > 0 then
      marker = expanded and MARKER_EXPANDED or MARKER_COLLAPSED
    end
    row_map[#lines + 1] = { id = turn.id, turn = n }
    row_headers[#lines + 1] = true
    lines[#lines + 1] = {
      { string.format("%" .. NUM_W .. "d ", n), "tool" },
      { marker .. " ", "path" },
      { clip(turn.text, text_width) },
    }
    if expanded then
      for _, b in ipairs(turn.blocks) do
        row_map[#lines + 1] = { id = b.id, turn = n }
        lines[#lines + 1] = { { SUB_PREFIX .. b.label, "dim" } }
      end
    end
  end
  p.buf:set_lines(lines)
  p.row_map = row_map
  p.row_headers = row_headers
end

local function entry_key(e)
  return "i" .. e.id
end

local function row_of_key(p, key)
  for row, e in ipairs(p.row_map) do
    if entry_key(e) == key then
      return row
    end
  end
end

local function row_of_turn(p, n)
  for row, e in ipairs(p.row_map) do
    if p.row_headers[row] and e.turn == n then
      return row
    end
  end
end

local function clamp_cursor(p)
  if #p.row_map == 0 then
    p.cursor = nil
    return
  end
  p.cursor = row_of_key(p, p.cursor_key)
    or row_of_turn(p, p.cursor_turn)
    or math.min(p.cursor or 1, #p.row_map)
  p.cursor_turn = p.row_map[p.cursor].turn
  p.cursor_key = entry_key(p.row_map[p.cursor])
  p.win:set_cursor(p.cursor)
end

local function jump(p, e)
  local ok, err = maki.ui.scroll_to_block(e.id, { session = p.session })
  if not ok then
    -- The message behind the row is gone, by a rewind or by a chat switch in
    -- the tab. List again so the next click has a row that answers.
    maki.ui.flash(err)
    rebuild()
  end
end

local function move(p, delta)
  if #p.row_map == 0 then
    return
  end
  p.cursor = math.min(math.max((p.cursor or 1) + delta, 1), #p.row_map)
  local e = p.row_map[p.cursor]
  p.cursor_turn, p.cursor_key = e.turn, entry_key(e)
  p.win:set_cursor(p.cursor)
end

-- Folded by message id rather than by turn number, so a rewind that drops an
-- earlier turn leaves the folds on the turns they belong to.
local function toggle_turn(p, n)
  local id = p.turns[n].id
  p.expanded[id] = not p.expanded[id] or nil
  render(p)
  clamp_cursor(p)
end

local function handle_key(p, key)
  if key == "<M-j>" or key == "<M-Down>" then
    move(p, 1)
  elseif key == "<M-k>" or key == "<M-Up>" then
    move(p, -1)
  elseif key == "<M-o>" and p.cursor then
    toggle_turn(p, p.row_map[p.cursor].turn)
  elseif key == "<M-CR>" and p.cursor then
    jump(p, p.row_map[p.cursor])
  end
end

local function loop(p)
  while true do
    local ev = p.win:recv()
    if not ev or ev.type == "close" then
      break
    end
    if ev.type == "key" then
      handle_key(p, ev.key)
    elseif ev.type == "click" then
      local e = p.row_map[ev.row]
      if e then
        p.cursor = ev.row
        p.cursor_turn, p.cursor_key = e.turn, entry_key(e)
        p.win:set_cursor(ev.row)
        if p.row_headers[ev.row] and ev.col <= COL_PREFIX_W then
          toggle_turn(p, e.turn)
        else
          jump(p, e)
        end
      end
    elseif ev.type == "resize" then
      p.width = ev.width
      render(p)
      clamp_cursor(p)
    end
  end
  if pane == p then
    pane = nil
  end
end

function rebuild()
  local p = pane
  if not p or not p.win:is_open() then
    return
  end
  local turns, err = build_turns(p.session)
  if not turns then
    maki.ui.flash(err)
    return
  end
  p.turns = turns
  render(p)
  clamp_cursor(p)
end

local function open()
  if not maki.ui.transcript_outline or not maki.ui.scroll_to_block then
    maki.ui.flash(NO_JUMP_API)
    return
  end
  local session = maki.session.current()
  local p = {
    buf = maki.ui.buf({ scratch = true }),
    session = session,
    turns = {},
    row_map = {},
    row_headers = {},
    expanded = {},
    width = PANE_WIDTH,
    cursor_turn = 1,
  }
  local turns, err = build_turns(session)
  if not turns then
    maki.ui.flash(err)
    return
  end
  p.turns = turns
  p.win = maki.ui.open_win(p.buf, {
    session = session,
    title = TITLE,
    split = "left",
    width = PANE_WIDTH,
    border = "rounded",
    focus = false,
    cursor_line = true,
    keys = NAV_KEYS,
    footer = { { "M-j/k", "move" }, { "M-o", "fold" }, { "M-CR", "jump" } },
  })
  p.width = p.win.width
  render(p)
  clamp_cursor(p)
  pane = p
  maki.async.run(function()
    loop(p)
  end)
end

local function toggle()
  if pane then
    local p = pane
    pane = nil
    p.win:close()
  else
    open()
  end
end

maki.api.register_command({
  name = "/toc",
  description = "Toggle a left pane of turns; click the marker or press M-o to fold, click or M-CR to jump",
  handler = toggle,
})

local function dump()
  local session = pane and pane.session or nil
  local items, err = maki.ui.transcript_outline({ session = session })
  if not items then
    maki.log.error("toc dump: " .. tostring(err))
    return
  end
  for _, item in ipairs(items) do
    maki.log.info(string.format("toc dump: %d %s %q", item.id, item.kind, item.text))
  end
  maki.log.info("toc dump: " .. #items .. " jumpable blocks")
  maki.ui.flash("toc: outline dumped to log")
end

maki.api.register_command({
  name = "/toc-dump",
  description = "Write the transcript and turn classification to the log for debugging",
  handler = dump,
})

maki.keymap.set("n", "<M-t>", toggle, { desc = "Toggle contents pane" })

-- The outline answers for whichever chat the pane's tab shows, and rows are
-- keyed by the id of the message they were listed for, so a refresh keeps the
-- folds and the selection where they were. A chat cycle and a compaction are
-- reasons to list again. Nothing is needed when another tab takes the focus:
-- the host hides this window with its session, and the pane reads that
-- session by id either way.
maki.api.create_autocmd(
  { "TurnStart", "TurnEnd", "ToolDone", "TaskFocusChanged", "CompactionDone" },
  {
    callback = function()
      if pane then
        maki.async.run(rebuild)
      end
    end,
  }
)
