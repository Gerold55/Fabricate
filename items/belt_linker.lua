-- items/belt_linker.lua
-- Mechanical Belt linker (Create-like two-click placement)

local fabricate = rawget(_G, "fabricate")
assert(fabricate, "fabricate: init.lua must load before belt_linker")

local min  = fabricate.min
local NS   = fabricate.NS

local function same_pos(a, b)
  return a and b and a.x == b.x and a.y == b.y and a.z == b.z
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
    local name  = node.name

    -- Must click valid driveline part
    if name ~= NS.."shaft"
    and name ~= NS.."gearbox"
    and name ~= NS.."gantry_shaft" then
      min.chat_send_player(pname,
        "Click a shaft, gearbox, or gantry with the belt.")
      return stack
    end

    -- Require side face (no top/bottom)
    if pointed.above and pointed.under then
      local ny = pointed.under.y - pointed.above.y
      if ny ~= 0 then
        min.chat_send_player(pname,
          "Click a horizontal side of the shaft.")
        return stack
      end
    end

    local um        = user:get_meta()
    local saved_pos = um:get_string("fab_link_a_pos")

    -- First click: store A
    if saved_pos == "" then
      um:set_string("fab_link_a_pos", min.pos_to_string(pos))
      min.chat_send_player(pname,
        "First shaft set. Click the second shaft with the belt.")
      return stack
    end

    -- Second click: B + build
    local a_pos = min.string_to_pos(saved_pos)
    um:set_string("fab_link_a_pos", "")

    if not a_pos then
      min.chat_send_player(pname, "Internal error: bad saved position.")
      return stack
    end

    if same_pos(a_pos, pos) then
      min.chat_send_player(pname,
        "Anchors overlap; pick a different second shaft.")
      return stack
    end

    if not fabricate.build_belt_run then
      min.chat_send_player(pname, "Internal error: belt builder missing.")
      return stack
    end

    local lid, err = fabricate.build_belt_run(user, a_pos, pos)
    if not lid then
      min.chat_send_player(pname, "Belt failed: "..(err or "?"))
      return stack
    else
      min.chat_send_player(pname, "Mechanical Belt placed.")
      -- Create behavior: initial belt placement consumes ONE belt
      stack:take_item(1)
    end

    return stack
  end,
})

-- Crafting recipe for belt item
min.register_craft({
  output = NS.."belt_linker",
  recipe = {
    {"group:wool","group:wool","group:wool"},
    {"","default:steel_ingot",""},
    {"group:wool","group:wool","group:wool"},
  }
})
