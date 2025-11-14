-- fabricate/nodes/chute.lua
--
-- Chutes & Smart Chutes
-- - One-stack internal buffer (16 / 64)
-- - Pull from above (items + inventories)
-- - Default: send items downward
-- - Encased Fan powered chutes:
--     * Fan below = push items up
--     * Fan above = pull items up
-- - Output to:
--     * another chute
--     * an inventory below
--     * a belt segment below
--     * empty space (drops item)

local fabricate = rawget(_G, "fabricate")
assert(fabricate, "fabricate: global API table missing, init.lua must load first")

local min    = fabricate.min
local NS     = fabricate.NS
local H      = fabricate.helpers
local DIRS   = fabricate.DIRS

local pos_to_key        = H.pos_to_key
local facedir_to_dir    = H.facedir_to_dir
local is_mech           = H.is_mech               -- not used yet, but handy
local has_stress        = H.has_stress           -- future smart uses
local stress_label      = H.stress_label
local ensure_overlay    = H.ensure_overlay       -- future; drills use it
local remove_overlay    = H.remove_overlay
local can_connect       = H.can_connect

local POWER_GRID        = fabricate.power_grid   -- updated by power.lua

-- State: list of all chutes to tick
fabricate.chutes = fabricate.chutes or {}
local CHUTES = fabricate.chutes

---------------------------------------------------------------------------
-- Nodeboxes / visuals
---------------------------------------------------------------------------

local CHUTE_BOX = {
  type = "fixed",
  fixed = {
    -- four thin walls -> hollow tube
    {-0.5,-0.5,-0.5, -0.4, 0.5, 0.5},
    { 0.4,-0.5,-0.5,  0.5, 0.5, 0.5},
    {-0.4,-0.5,-0.5,  0.4, 0.5,-0.4},
    {-0.4,-0.5, 0.4,  0.4, 0.5, 0.5},

    -- small top rim so it doesn’t look like a pure hole
    {-0.5, 0.45,-0.5,  0.5, 0.5, 0.5},
  },
}

local function track_chute(pos)
  CHUTES[pos_to_key(pos)] = vector.new(pos)
end

local function untrack_chute(pos)
  CHUTES[pos_to_key(pos)] = nil
end

-- Capacity helper
local function chute_capacity(name)
  if name == NS.."smart_chute" then
    return 64
  else
    return 16
  end
end

-- Common chute node def base
local function base_chute_def(desc, smart)
  return {
    description   = desc,
    drawtype      = "nodebox",
    node_box      = CHUTE_BOX,
    selection_box = { type="fixed", fixed={{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },
    collision_box = { type="fixed", fixed={{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },
    tiles = {
      "fabricate_chute_top.png",
      "fabricate_chute_bottom.png",
      "fabricate_chute_side.png",
      "fabricate_chute_side.png",
      "fabricate_chute_side.png",
      "fabricate_chute_side.png",
    },
    paramtype   = "light",
    paramtype2  = "facedir", -- future: allow slanted / decorative variants
    groups      = {
      cracky = 2,
      oddly_breakable_by_hand = 2,
      fabricate_chute = 1,
    },
    on_construct = function(pos)
      track_chute(pos)
      local meta = min.get_meta(pos)
      meta:set_string("buffer", "")
      if smart then
        -- Smart chute extras (simple version):
        --   filter_name  = allowed item ("" = any)
        --   max_stack    = max count (<= 64)
        meta:set_string("filter_name", "")
        meta:set_int("max_stack", 64)
        meta:set_string("infotext", "Smart Chute (empty)")
      else
        meta:set_string("infotext", "Chute (empty)")
      end
    end,
    on_destruct = function(pos)
      untrack_chute(pos)
      local meta = min.get_meta(pos)
      local buf  = meta:get_string("buffer")
      if buf ~= "" then
        local stack = ItemStack(buf)
        if not stack:is_empty() then
          min.add_item({x=pos.x+0.5,y=pos.y+0.5,z=pos.z+0.5}, stack)
        end
      end
    end,
  }
end

---------------------------------------------------------------------------
-- Register Chute + Smart Chute
---------------------------------------------------------------------------

min.register_node(NS.."chute", base_chute_def("Fabricate Chute", false))
min.register_node(NS.."smart_chute", base_chute_def("Fabricate Smart Chute", true))

-- LBM to re-track existing ones
min.register_lbm({
  name            = NS.."track_chutes",
  nodenames       = {NS.."chute", NS.."smart_chute"},
  run_at_every_load = true,
  action = function(pos, node)
    track_chute(pos)
  end,
})

---------------------------------------------------------------------------
-- Helper: basic inventory IO
---------------------------------------------------------------------------

-- Try to add stack to an inventory's "main" list.
-- Returns leftover ItemStack (possibly empty).
local function chute_put_into_inventory(inv, stack)
  if not inv or stack:is_empty() then
    return stack
  end
  if inv:get_size("main") and inv:get_size("main") > 0 then
    return inv:add_item("main", stack)
  end
  return stack
end

-- Try to extract *one* stack from an inventory above the chute.
-- Only pulls when buffer is empty.
local function chute_pull_from_inventory_above(pos, buffer, cap)
  if not buffer:is_empty() then
    return buffer
  end

  local above = {x=pos.x, y=pos.y+1, z=pos.z}
  local node  = min.get_node_or_nil(above)
  if not node then return buffer end

  local meta = min.get_meta(above)
  local inv  = meta:get_inventory()
  if not inv or not inv:get_size("main") or inv:get_size("main") <= 0 then
    return buffer
  end

  for i = 1, inv:get_size("main") do
    local st = inv:get_stack("main", i)
    if not st:is_empty() then
      local take = math.min(cap, st:get_count())
      local pulled = st:take_item(take)
      inv:set_stack("main", i, st)
      return pulled
    end
  end

  return buffer
end

---------------------------------------------------------------------------
-- Helper: pull items from entities on top of chute
---------------------------------------------------------------------------

local function chute_pull_item_entities(pos, buffer, cap)
  if buffer:get_count() >= cap then
    return buffer
  end

  local center = {x=pos.x+0.5, y=pos.y+1.0, z=pos.z+0.5}
  local need   = cap - buffer:get_count()

  for _, obj in ipairs(min.get_objects_inside_radius(center, 0.6)) do
    local ent = obj:get_luaentity()
    if ent and ent.name == "__builtin:item" then
      local st = ItemStack(ent.itemstring or "")
      if not st:is_empty() then
        if buffer:is_empty() then
          -- adopt this item type
          local take = math.min(need, st:get_count())
          buffer = st:take_item(take)
          need   = cap - buffer:get_count()
        elseif buffer:get_name() == st:get_name() then
          local take = math.min(need, st:get_count())
          local part = st:take_item(take)
          buffer:set_count(buffer:get_count() + part:get_count())
          need = cap - buffer:get_count()
        else
          -- different type: ignore
        end

        if st:is_empty() then
          obj:remove()
        else
          ent.itemstring = st:to_string()
          if ent.set_item then ent:set_item(st) end
        end

        if need <= 0 then
          break
        end
      end
    end
  end

  return buffer
end

---------------------------------------------------------------------------
-- Helper: determine chute direction based on Encased Fans
--   Default: "down"
--   Fan below (powered encased fan)  => "up"
--   Fan above (powered encased fan)  => "up"
---------------------------------------------------------------------------

local function chute_flow_direction(pos)
  local down = {x=pos.x, y=pos.y-1, z=pos.z}
  local up   = {x=pos.x, y=pos.y+1, z=pos.z}

  local nd = min.get_node_or_nil(down)
  if nd and nd.name == NS.."encased_fan" then
    local e = POWER_GRID[pos_to_key(down)]
    if e and e.power and e.power > 0 then
      return "up"
    end
  end

  local nu = min.get_node_or_nil(up)
  if nu and nu.name == NS.."encased_fan" then
    local e = POWER_GRID[pos_to_key(up)]
    if e and e.power and e.power > 0 then
      return "up"
    end
  end

  return "down"
end

---------------------------------------------------------------------------
-- Helper: send buffer to target (chute / inv / belt / empty)
---------------------------------------------------------------------------

local function chute_output(pos, node, buffer, dir)
  if buffer:is_empty() then
    return buffer
  end

  local dest
  if dir == "up" then
    dest = {x=pos.x, y=pos.y+1, z=pos.z}
  else
    dest = {x=pos.x, y=pos.y-1, z=pos.z}
  end

  local dn = min.get_node_or_nil(dest)

  -- Nothing there or air / non-walkable: drop into space
  if not dn or dn.name == "air" then
    min.add_item({x=dest.x+0.5, y=dest.y+0.5, z=dest.z+0.5}, buffer)
    buffer:clear()
    return buffer
  end

  local def = min.registered_nodes[dn.name]

  -- Another chute below / above
  if dn.name == NS.."chute" or dn.name == NS.."smart_chute" then
    local meta2   = min.get_meta(dest)
    local buf_str = meta2:get_string("buffer")
    local buf2    = (buf_str ~= "" and ItemStack(buf_str)) or ItemStack("")
    local cap2    = chute_capacity(dn.name)

    if buf2:is_empty() then
      -- whole stack moves or capped to capacity
      local move = buffer:take_item(math.min(cap2, buffer:get_count()))
      buf2 = move
    elseif buf2:get_name() == buffer:get_name() and buf2:get_count() < cap2 then
      local room = cap2 - buf2:get_count()
      local move = buffer:take_item(math.min(room, buffer:get_count()))
      buf2:set_count(buf2:get_count() + move:get_count())
    else
      -- other type or full: can't insert
      meta2:set_string("buffer", buf2:to_string())
      return buffer
    end

    meta2:set_string("buffer", buf2:is_empty() and "" or buf2:to_string())
    return buffer
  end

  -- Belt: drop item onto belt surface
  if dn.name == NS.."belt_segment" or dn.name == NS.."belt_segment_slope" then
    min.add_item({x=dest.x+0.5, y=dest.y+0.6, z=dest.z+0.5}, buffer)
    buffer:clear()
    return buffer
  end

  -- Inventory below / above
  if def and def.groups and def.groups.immovable ~= 1 then
    local meta2 = min.get_meta(dest)
    local inv2  = meta2:get_inventory()
    if inv2 then
      local leftover = chute_put_into_inventory(inv2, buffer)
      buffer = leftover
      return buffer
    end
  end

  -- Fallback: just drop
  min.add_item({x=dest.x+0.5, y=dest.y+0.5, z=dest.z+0.5}, buffer)
  buffer:clear()
  return buffer
end

---------------------------------------------------------------------------
-- Globalstep: update all chutes
---------------------------------------------------------------------------

local chute_step_accum = 0

min.register_globalstep(function(dtime)
  chute_step_accum = chute_step_accum + dtime
  if chute_step_accum < 0.2 then return end
  local dt = chute_step_accum
  chute_step_accum = 0

  for key, pos in pairs(CHUTES) do
    local node = min.get_node_or_nil(pos)
    if not node or (node.name ~= NS.."chute" and node.name ~= NS.."smart_chute") then
      CHUTES[key] = nil
    else
      local meta   = min.get_meta(pos)
      local bufstr = meta:get_string("buffer")
      local buffer = (bufstr ~= "" and ItemStack(bufstr)) or ItemStack("")
      local cap    = chute_capacity(node.name)

      -- Smart chute limit (optional extra filter)
      if node.name == NS.."smart_chute" then
        local max_stack = meta:get_int("max_stack")
        if max_stack > 0 and max_stack < cap then
          cap = max_stack
        end
        local filter = meta:get_string("filter_name")
        if filter ~= "" and not buffer:is_empty()
            and buffer:get_name() ~= filter then
          -- wrong item inside: just hold it (player configured badly)
        end
      end

      -- 1) Pull item entities from top
      buffer = chute_pull_item_entities(pos, buffer, cap)

      -- 2) Pull from inventory above (only if buffer empty)
      buffer = chute_pull_from_inventory_above(pos, buffer, cap)

      -- 3) Direction: gravity or fan powered
      local flow_dir = chute_flow_direction(pos)

      -- 4) Try to output buffer
      buffer = chute_output(pos, node, buffer, flow_dir)

      -- 5) Infotext
      local label = (node.name == NS.."smart_chute") and "Smart Chute" or "Chute"
      if buffer:is_empty() then
        meta:set_string("infotext", label.." (empty, "..flow_dir..")")
        meta:set_string("buffer", "")
      else
        meta:set_string("infotext",
          ("%s (%s x%d, %s)"):format(
            label,
            buffer:get_name(),
            buffer:get_count(),
            flow_dir
          )
        )
        meta:set_string("buffer", buffer:to_string())
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Crafting
---------------------------------------------------------------------------

min.register_craft({
  output = NS.."chute 4",
  recipe = {
    {"default:iron_lump","default:iron_lump","default:iron_lump"},
    {"","group:wood",""},
    {"default:iron_lump","default:iron_lump","default:iron_lump"},
  }
})

min.register_craft({
  output = NS.."smart_chute",
  recipe = {
    {NS.."chute", "default:mese_crystal", NS.."chute"},
    {"","default:steel_ingot",""},
    {"","default:steel_ingot",""},
  }
})
