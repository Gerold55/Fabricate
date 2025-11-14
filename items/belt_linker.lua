-- fabricate/items/belt_linker.lua
-- Mechanical Belt linker & extension logic

local fabricate = rawget(_G, "fabricate")
assert(fabricate, "fabricate: init.lua must load before belt_linker")

local min    = fabricate.min
local NS     = fabricate.NS
local H      = fabricate.helpers

local pos_to_key   = H.pos_to_key
local is_mech      = H.is_mech
local track_mech   = H.track_mech
local untrack_mech = H.untrack_mech

local BELT_MAX_LEN = fabricate.belt_max_len or 20

local function same_pos(a, b)
  return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

-- Find belt line & which anchor ("a" or "b") is at this position
local function find_belt_anchor_at(pos)
  for id, line in pairs(fabricate.belts or {}) do
    if line.anchors then
      local a = line.anchors.a
      local b = line.anchors.b
      if same_pos(a, pos) then
        return id, line, "a"
      elseif same_pos(b, pos) then
        return id, line, "b"
      end
    end
  end
  return nil, nil, nil
end

-- Try to extend an existing belt by moving its end shaft outward by 1 block.
-- Returns true if handled (success or fail with message), false if no belt at this shaft.
local function try_extend_belt(user, shaft_pos, node)
  local player = user and user:is_player() and user or nil
  local pname  = player and player:get_player_name() or nil

  local id, line, which = find_belt_anchor_at(shaft_pos)
  if not line then
    return false -- no belt anchored here, let normal linker logic run
  end

  local dir  = line.dir or {x=0,y=0,z=0}
  local kind = line.kind or "horizontal"

  -- Determine "outward" direction from this end:
  -- line.dir is from anchor A -> B.
  -- If we're extending A, go opposite dir; if B, go along dir.
  local sign = (which == "a") and -1 or 1
  local new_pos = {
    x = shaft_pos.x + dir.x * sign,
    y = shaft_pos.y + dir.y * sign,
    z = shaft_pos.z + dir.z * sign,
  }

  -- Compute new length (steps) and enforce max
  local old_steps = line.steps or ( (#line.segments or {}) - 1 )
  local new_steps = old_steps + 1
  if new_steps > BELT_MAX_LEN then
    if pname then
      min.chat_send_player(pname,
        ("Cannot extend: belt would exceed max length (%d)."):format(BELT_MAX_LEN))
    end
    return true
  end

  -- New shaft position must be free
  local n = min.get_node_or_nil(new_pos)
  if n and n.name ~= "air" then
    if pname then
      min.chat_send_player(pname,
        "Cannot extend: space for new shaft is blocked at "..min.pos_to_string(new_pos))
    end
    return true
  end

  -- Grab old shaft facing so new one matches
  local old_node = node or min.get_node_or_nil(shaft_pos)
  local param2   = old_node and old_node.param2 or 0

  -- Decide which belt segment node to use on the old shaft position
  local belt_name =
    (kind == "horizontal" or kind == "vertical")
      and NS.."belt_segment"
      or NS.."belt_segment_slope"

  -- 1) Convert old shaft block into belt segment in-world
  min.set_node(shaft_pos, {name = belt_name, param2 = param2})

  -- 2) Place new shaft one block further out
  min.set_node(new_pos, {name = NS.."shaft", param2 = param2})

  -- 3) Update mechanical tracking (so power graph sees new shaft)
  untrack_mech(shaft_pos)
  track_mech(new_pos)

  -- 4) Update line anchors / segments / steps
  if which == "a" then
    -- For anchor A, we extended "before" the belt.
    line.anchors.a = vector.new(new_pos)
    line.segments = line.segments or {}
    table.insert(line.segments, 1, vector.new(new_pos))
  else
    -- For anchor B, we extended "after" the belt.
    line.anchors.b = vector.new(new_pos)
    line.segments = line.segments or {}
    line.segments[#line.segments+1] = vector.new(new_pos)
  end

  line.steps = new_steps

  if pname then
    min.chat_send_player(pname, "Mechanical Belt extended by one block.")
  end

  return true
end

-- =========================================================
-- Belt linker item
-- =========================================================

min.register_craftitem(NS.."belt_linker", {
  description     = "Fabricate Mechanical Belt",
  inventory_image = "mcl_core_iron_block.png^[colorize:#3a3a3a:150",
  stack_max       = 64,

  on_use = function(stack, user, pointed)
    if not user or not pointed or pointed.type ~= "node" then
      return stack
    end

    local pos  = pointed.under
    local node = min.get_node_or_nil(pos)
    if not node then
      return stack
    end

    local pname = user:get_player_name() or ""

    -- -------------------------------------------------
    -- 1) EXTENSION: click an end shaft of an existing belt
    -- -------------------------------------------------
    -- Only if this is a shaft AND we're not in the middle of a 2-click link
    local um        = user:get_meta()
    local saved_pos = um:get_string("fab_link_a_pos")

    if node.name == NS.."shaft" and saved_pos == "" then
      local handled = try_extend_belt(user, pos, node)
      if handled then
        -- Belt extension does NOT consume the item
        return stack
      end
      -- If not handled, fall through to normal linking logic
    end

    -- -------------------------------------------------
    -- 2) NORMAL LINKING: click Shaft/Gearbox/Gantry A, then B
    -- -------------------------------------------------
    local name = node.name
    if name ~= NS.."shaft"
    and name ~= NS.."gearbox"
    and name ~= NS.."gantry_shaft" then
      min.chat_send_player(pname,
        "Click a shaft, gearbox, or gantry with the belt.")
      return stack
    end

    -- Require side face (no top/bottom clicks)
    if pointed.above and pointed.under then
      local ny = pointed.under.y - pointed.above.y
      if ny ~= 0 then
        min.chat_send_player(pname,
          "Click a horizontal side of the shaft.")
        return stack
      end
    end

    -- First click?
    if saved_pos == "" then
      um:set_string("fab_link_a_pos", min.pos_to_string(pos))
      min.chat_send_player(pname,
        "First shaft set. Click the second shaft with the belt.")
      return stack
    end

    -- Second click
    local a_pos = min.string_to_pos(saved_pos)
    um:set_string("fab_link_a_pos", "")

    if not a_pos then
      min.chat_send_player(pname, "Internal error: bad saved position.")
      return stack
    end

    -- Can't link a shaft to itself
    if same_pos(a_pos, pos) then
      min.chat_send_player(pname, "Anchors overlap; pick a different second shaft.")
      return stack
    end

    -- Build the belt run using the shared API from nodes/belts.lua
    if not fabricate.build_belt_run then
      min.chat_send_player(pname, "Internal error: belt builder missing.")
      return stack
    end

    local lid, err = fabricate.build_belt_run(user, a_pos, pos)
    if not lid then
      min.chat_send_player(pname, "Belt failed: "..(err or "?"))
    else
      -- Create-style behavior: creating belts consumes ONE belt
      -- but extending does not; you can tweak this if desired.
      stack:take_item(1)
    end

    return stack
  end,
})

-- Crafting recipe for the belt item
min.register_craft({
  output = NS.."belt_linker",
  recipe = {
    {"group:wool","group:wool","group:wool"},
    {"","default:steel_ingot",""},
    {"group:wool","group:wool","group:wool"},
  }
})
