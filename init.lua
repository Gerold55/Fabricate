-- fabricate/init.lua
-- Fabricate: simple Create-like kinetic network for Luanti.
-- Not affiliated with the Create team.

local min    = rawget(_G, "core") or minetest
local vector = vector
local math   = math

local modname = min.get_current_modname() or "fabricate"
local NS      = modname .. ":"

-- -------------------------------------------------
-- Helpers
-- -------------------------------------------------
local function pos_to_key(p) return ("%d,%d,%d"):format(p.x,p.y,p.z) end

local DIRS = {
  {x= 1,y= 0,z= 0},{x=-1,y= 0,z= 0},
  {x= 0,y= 1,z= 0},{x= 0,y=-1,z= 0},
  {x= 0,y= 0,z= 1},{x= 0,y= 0,z=-1},
}

local function facedir_to_dir(param2)
  local rot = param2 % 4
  if rot == 0 then return {x=0,y=0,z=1}
  elseif rot==1 then return {x=1,y=0,z=0}
  elseif rot==2 then return {x=0,y=0,z=-1}
  else return {x=-1,y=0,z=0} end
end

local function has_water_near_wheel(pos)
  for dx=-1,1 do for dy=-1,1 do for dz=-1,1 do
    local np = {x=pos.x+dx,y=pos.y+dy,z=pos.z+dz}
    local n  = min.get_node_or_nil(np)
    if n then
      local def = min.registered_nodes[n.name]
      if def and def.liquidtype and def.liquidtype ~= "none" then return true end
    end
  end end end
  return false
end

-- -------------------------------------------------
-- Global registries / state
-- -------------------------------------------------
fabricate                    = rawget(_G, "fabricate") or {}
fabricate.tracked_mech       = fabricate.tracked_mech       or {}
fabricate.power_grid         = fabricate.power_grid         or {}
fabricate.get_power_for      = fabricate.get_power_for      or {}
fabricate.on_power_for       = fabricate.on_power_for       or {}
fabricate.dynamic_sources    = fabricate.dynamic_sources    or {}

local get_power_for = fabricate.get_power_for
local on_power_for  = fabricate.on_power_for

local function is_mech(name)
  local d = min.registered_nodes[name]
  return d and d.groups and d.groups.fabricate_mech == 1
end
local function is_source(name)
  local d = min.registered_nodes[name]
  return d and d.groups and d.groups.fabricate_source == 1
end
local function is_consumer(name)
  local d = min.registered_nodes[name]
  return d and d.groups and d.groups.fabricate_consumer == 1
end

local function track_mech(pos)   fabricate.tracked_mech[pos_to_key(pos)] = vector.new(pos) end
local function untrack_mech(pos) fabricate.tracked_mech[pos_to_key(pos)] = nil end

-- -------------------------------------------------
-- Explicit compatibility rules (face-adjacent)
-- -------------------------------------------------
local NAME = NS
local function can_connect(aname, bname)
  if not (is_mech(aname) and is_mech(bname)) then return false end

  local W  = NAME.."water_wheel"
  local G  = NAME.."gantry_shaft"
  local S  = NAME.."shaft"
  local X  = NAME.."gearbox"
  local F  = NAME.."encased_fan"
  local H  = NAME.."hand_crank"

    -- Wheel mates with gantry, bare shaft, or a fan
  if aname == W then return (bname == G or bname == S or bname == F) end
  if bname == W then return (aname == G or aname == S or aname == F) end

  -- Gantry bridges wheel ↔ driveline (and can pass to fan)
  if aname == G then return (bname == W or bname == S or bname == X or bname == G or bname == F) end
  if bname == G then return (aname == W or aname == S or aname == X or aname == G or aname == F) end

  -- Crank can inject into driveline/fan/gantry
  if aname == H then return (bname == S or bname == X or bname == G or bname == F) end
  if bname == H then return (aname == S or aname == X or aname == G or aname == F) end

  -- Shafts/gearboxes interconnect; fans can hang off them
  local A_drive = (aname == S or aname == X)
  local B_drive = (bname == S or bname == X)
  if A_drive and B_drive then return true end
  if A_drive and bname == F then return true end
  if B_drive and aname == F then return true end

  return false
end

-- -------------------------------------------------
-- BFS power propagation (uses can_connect)
-- -------------------------------------------------
local function add_power(accum, key, pos, p)
  local ex = accum[key]
  if not ex or ex.power < p then
    accum[key] = {pos = vector.new(pos), power = p}
  end
end

local function bfs(accum, start_pos, base_power)
  if base_power <= 0 then return end
  local queue, seen = {}, {}
  queue[1] = {pos = vector.new(start_pos), power = base_power}
  seen[pos_to_key(start_pos)] = base_power

  while #queue > 0 do
    local cur = table.remove(queue, 1)
    local pos, pwr = cur.pos, cur.power
    add_power(accum, pos_to_key(pos), pos, pwr)
    if pwr <= 1 then goto continue end

    local node_here = min.get_node_or_nil(pos)
    for _, d in ipairs(DIRS) do
      local np = {x=pos.x+d.x, y=pos.y+d.y, z=pos.z+d.z}
      local n  = min.get_node_or_nil(np)
      if node_here and n and is_mech(n.name) and can_connect(node_here.name, n.name) then
        local nkey, npwr = pos_to_key(np), pwr - 1
        if not seen[nkey] or seen[nkey] < npwr then
          seen[nkey] = npwr
          queue[#queue+1] = {pos = np, power = npwr}
        end
      end
    end
    ::continue::
  end
end


-- -------------------------------------------------
-- Globalstep: solve network + drive consumers
-- -------------------------------------------------
local step_accum = 0
min.register_globalstep(function(dtime)
  step_accum = step_accum + dtime
  if step_accum < 0.2 then return end
  local dt  = step_accum
  step_accum = 0
  local now = min.get_gametime()

  local accum = {}

  -- Start from every powered source
  for _, pos in pairs(fabricate.tracked_mech) do
    local node = min.get_node_or_nil(pos)
    if node and is_source(node.name) then
      local fn = get_power_for[node.name]
      local p  = fn and (fn(pos, node, dt, now) or 0) or 0
      if p > 0 then
        -- Ensure source itself is visible in the grid
        add_power(accum, pos_to_key(pos), pos, p)
        -- Then propagate
        bfs(accum, pos, p)
      end
    end
  end

  fabricate.power_grid = accum

-- === Terminal fan backfill ===
-- If a fan is adjacent to any powered mechanical neighbor, give it neighbor_power - 1.
for key, pos in pairs(fabricate.tracked_mech) do
  local n = min.get_node_or_nil(pos)
  if n and n.name == NS.."encased_fan" then
    local selfk = pos_to_key(pos)
    if not accum[selfk] then
      local best = 0
      for _, d in ipairs(DIRS) do
        local np = {x=pos.x+d.x, y=pos.y+d.y, z=pos.z+d.z}
        local nn = min.get_node_or_nil(np)
        if nn and is_mech(nn.name) and can_connect(n.name, nn.name) then
          local ek = pos_to_key(np)
          local e  = accum[ek]
          if e and e.power > best then best = e.power end
        end
      end
      if best > 0 then
        local p = math.max(1, best - 1)
        accum[selfk] = { pos = vector.new(pos), power = p }
      end
    end
  end
end

  -- Reset infotexts
  for _, pos in pairs(fabricate.tracked_mech) do
    min.get_meta(pos):set_string("infotext", "")
  end

  -- Drive consumers + label mechanical nodes
  for _, data in pairs(accum) do
    local pos, power = data.pos, data.power
    local node = min.get_node_or_nil(pos); if not node then goto continue end
    local name = node.name

    if is_consumer(name) then
      local cfn = on_power_for[name]
      if cfn then cfn(pos, node, power, dt) end
    end

    if is_mech(name) then
      local label = ({
        [NS.."water_wheel"] = "Water Wheel",
        [NS.."gantry_shaft"]= "Gantry Shaft",
        [NS.."shaft"]       = "Shaft",
        [NS.."gearbox"]     = "Gearbox",
        [NS.."hand_crank"]  = "Hand Crank",
        [NS.."encased_fan"] = "Encased Fan",
      })[name] or name
      min.get_meta(pos):set_string("infotext", label.." (power "..power..")")
    end
    ::continue::
  end

  -- Consumers without power → "no power"
  for _, pos in pairs(fabricate.tracked_mech) do
    local node = min.get_node_or_nil(pos)
    if node and is_consumer(node.name) and not accum[pos_to_key(pos)] then
      min.get_meta(pos):set_string("infotext", "Encased Fan (no power)")
    end
  end
end)

-- -------------------------------------------------
-- Components
-- -------------------------------------------------

-- Shaft
min.register_node(NS.."shaft", {
  description = "Fabricate Shaft",
  drawtype    = "nodebox",
  tiles       = {"fabricate_shaft.png"},
  paramtype   = "light",
  paramtype2  = "facedir",
  node_box    = { type="fixed", fixed = { {-0.1,-0.1,-0.5, 0.1,0.1,0.5} } }, -- rod along Z
  groups      = { cracky=2, oddly_breakable_by_hand=2, fabricate_mech=1 },
  on_construct= track_mech,
  on_destruct = untrack_mech,

  on_place = function(itemstack, placer, pt)
    if pt.type ~= "node" then return min.item_place(itemstack, placer, pt) end
    local under, above = pt.under, pt.above
    if not under or not above then return min.item_place(itemstack, placer, pt) end
    local dx, dz = under.x - above.x, under.z - above.z
    local param2 = (math.abs(dx) > math.abs(dz)) and 1 or 0 -- X vs Z
    return min.item_place_node(itemstack, placer, pt, param2)
  end,
})

-- Gearbox
min.register_node(NS.."gearbox", {
  description = "Fabricate Gearbox",
  tiles = {
    "fabricate_gearbox_top.png","fabricate_gearbox_top.png",
    "fabricate_gearbox_side.png","fabricate_gearbox_side.png",
    "fabricate_gearbox_side.png","fabricate_gearbox_side.png",
  },
  paramtype2   = "facedir",
  groups       = { cracky=2, fabricate_mech=1 },
  on_construct = track_mech,
  on_destruct  = untrack_mech,
})

-- Gantry Shaft (adapter that mounts flush to wheel side; stub outward)
local GANTRY_BOX = {
  type="fixed",
  fixed = {
    -- collar (toward clicked block)
    {-0.30,-0.30,-0.50,  0.30, 0.30,-0.25},
    -- outward stub for a regular shaft
    {-0.10,-0.10,-0.25,  0.10, 0.10, 0.50},
  }
}

min.register_node(NS.."gantry_shaft", {
  description = "Fabricate Gantry Shaft",
  drawtype    = "nodebox",
  node_box    = GANTRY_BOX,
  tiles       = {"fabricate_gantry.png"},
  paramtype   = "light",
  paramtype2  = "facedir",
  selection_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },
  collision_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },
  groups      = { cracky=2, oddly_breakable_by_hand=2, fabricate_mech=1 },
  on_construct= track_mech,
  on_destruct = untrack_mech,

  -- Make collar face the clicked block; stub points outward
  on_place = function(itemstack, placer, pt)
    if pt.type ~= "node" then return min.item_place(itemstack, placer, pt) end
    local under, above = pt.under, pt.above
    if not under or not above then return min.item_place(itemstack, placer, pt) end
    local dx, dz = under.x - above.x, under.z - above.z
    local param2
    if math.abs(dx) > math.abs(dz) then
      param2 = (dx > 0) and 3 or 1
    else
      param2 = (dz > 0) and 2 or 0
    end
    return min.item_place_node(itemstack, placer, pt, param2)
  end,
})

-- Hand Crank (dynamic test source)
min.register_node(NS.."hand_crank", {
  description = "Fabricate Hand Crank",
  drawtype    = "nodebox",
  tiles = {
    "fabricate_hand_crank_top.png","fabricate_hand_crank_bottom.png",
    "fabricate_hand_crank_side.png","fabricate_hand_crank_side.png",
    "fabricate_hand_crank_side.png","fabricate_hand_crank_side.png",
  },
  paramtype   = "light",
  paramtype2  = "facedir",
  node_box = {
    type="fixed",
    fixed = {
      {-0.2,-0.5,-0.2,  0.2,-0.1,0.2},
      {-0.05,-0.1,-0.05, 0.05,0.2,0.05},
      {0.05, 0.1,-0.15,  0.35,0.2,0.15},
    },
  },
  groups       = { choppy=2, oddly_breakable_by_hand=2, fabricate_mech=1, fabricate_source=1 },
  on_construct = function(pos)
    track_mech(pos)
    min.get_meta(pos):set_string("infotext","Hand Crank")
  end,
  on_destruct  = function(pos)
    untrack_mech(pos)
    fabricate.dynamic_sources[pos_to_key(pos)] = nil
  end,
  on_rightclick = function(pos, node, clicker)
    local key = pos_to_key(pos)
    fabricate.dynamic_sources[key] = {
      pos        = vector.new(pos),
      base_power = 8,
      until_time = min.get_gametime() + 2,
    }
    min.get_meta(pos):set_string("infotext","Hand Crank (active)")
  end,
})

get_power_for[NS.."hand_crank"] = function(pos, node, dt, now)
  local meta = fabricate.dynamic_sources[pos_to_key(pos)]
  if meta and meta.until_time and meta.until_time > now then
    return meta.base_power or 0
  end
  return 0
end

-- Water Wheel (source; mesh scaled 1.25; raised selection box)
min.register_node(NS.."water_wheel", {
  description  = "Fabricate Water Wheel",
  drawtype     = "mesh",
  mesh         = "water_wheel.obj",
  tiles        = {"mcl_core_planks_big_oak.png"},
  paramtype    = "light",
  paramtype2   = "facedir",
  visual_scale = 1.25,

  -- Clickable area: one block wide/deep, raised to reach the visible rim
  selection_box = { type="fixed", fixed = {{-0.5,-0.25,-0.5, 0.5,0.95,0.5}} },
  -- Collision stays 1×1×1 so it doesn't block neighbors
  collision_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },

  groups       = { choppy=2, oddly_breakable_by_hand=2, fabricate_mech=1, fabricate_source=1 },
  on_construct = function(pos)
    track_mech(pos)
    min.get_meta(pos):set_string("infotext","Water Wheel (no water)")
  end,
  on_destruct  = untrack_mech,
})

get_power_for[NS.."water_wheel"] = function(pos, node, dt, now)
  local m = min.get_meta(pos)
  if has_water_near_wheel(pos) then
    m:set_string("infotext","Water Wheel (power 8)")
    return 8
  end
  m:set_string("infotext","Water Wheel (no water)")
  return 0
end

-- === Encased Fan (consumer) ===
min.register_node(NS.."encased_fan", {
  description = "Fabricate Encased Fan",
  tiles = {
    "fabricate_fan_back.png",   -- top
    "fabricate_fan_back.png",   -- bottom
    "fabricate_fan_casing.png", -- right
    "fabricate_fan_casing.png", -- left
    "fabricate_fan_casing.png", -- back
    "fabricate_fan_front.png",  -- front (blows along facedir)
  },
  paramtype2   = "facedir",
  groups       = { cracky=2, fabricate_mech=1, fabricate_consumer=1 },
  on_construct = function(pos)
    track_mech(pos)
    min.get_meta(pos):set_string("infotext","Encased Fan (no power)")
  end,
  on_destruct  = untrack_mech,
})

-- Runs at power >= 2 (lower than before), and applies a gentle push.
on_power_for[NS.."encased_fan"] = function(pos, node, power, dt)
  local meta = min.get_meta(pos)
  if power < 2 then meta:set_string("infotext","Encased Fan (no power)");
    return
  end

  meta:set_string("infotext","Encased Fan (power "..power..")")

  -- Optional wind effect: pushes in the facedir axis.
  local dir   = facedir_to_dir(node.param2 or 0)
  local range = math.min(4 + math.floor(power/2), 12)

  -- Center a bit forward so the push is mostly in front of the fan.
  local c = {
    x = pos.x + dir.x * (range * 0.5 + 0.5),
    y = pos.y + dir.y * (range * 0.5),
    z = pos.z + dir.z * (range * 0.5 + 0.5),
  }

  for _, obj in ipairs(min.get_objects_inside_radius(c, range + 1)) do
    if obj:is_player() or obj:get_luaentity() then
      local v = obj:get_velocity() or {x=0, y=0, z=0}
      local boost = (power / 8) * 4
      obj:set_velocity({
        x = v.x + dir.x * boost,
        y = v.y + (dir.y * boost * 0.2),
        z = v.z + dir.z * boost,
      })
    end
  end
end

-- Track all existing fabricate_mech nodes when a mapblock loads
min.register_lbm({
  name = NS.."track_existing_mech",
  nodenames = {"group:fabricate_mech"},
  run_at_every_load = true,
  action = function(pos, node)
    track_mech(pos)
  end,
})

-- -------------------------------------------------
-- Crafting
-- -------------------------------------------------
min.register_craft({ output = NS.."shaft 4", recipe = {
  {"default:steel_ingot"}, {"default:stick"}, {"default:steel_ingot"},
}})
min.register_craft({ output = NS.."gearbox", recipe = {
  {"default:steel_ingot", NS.."shaft", "default:steel_ingot"},
  {"default:steel_ingot","default:copper_ingot","default:steel_ingot"},
  {"default:steel_ingot", NS.."shaft", "default:steel_ingot"},
}})
min.register_craft({ output = NS.."gantry_shaft 2", recipe = {
  {NS.."shaft","group:wood",NS.."shaft"},
}})
min.register_craft({ output = NS.."hand_crank", recipe = {
  {"group:wood"},{"default:stick"},{"default:stick"},
}})
min.register_craft({ output = NS.."water_wheel", recipe = {
  {"group:wood","group:wood","group:wood"},
  {"group:wood","default:steel_ingot","group:wood"},
  {"group:wood","group:wood","group:wood"},
}})
min.register_craft({ output = NS.."encased_fan", recipe = {
  {"default:steel_ingot","default:steel_ingot","default:steel_ingot"},
  {"default:steel_ingot",NS.."shaft","default:steel_ingot"},
  {"default:steel_ingot","default:copper_ingot","default:steel_ingot"},
}})

-- -------------------------------------------------
-- Debug: /fab_debug
-- -------------------------------------------------
min.register_chatcommand("fab_debug", {
  description = "List powered Fabricate nodes near you",
  func = function(name)
    local player = min.get_player_by_name(name)
    if not player then return false, "No player." end
    local p = vector.round(player:get_pos())
    local r = 12
    local out = {}
    for _, data in pairs(fabricate.power_grid) do
      local pos = data.pos
      if math.abs(pos.x-p.x)<=r and math.abs(pos.y-p.y)<=r and math.abs(pos.z-p.z)<=r then
        local n = min.get_node_or_nil(pos)
        out[#out+1] = ("%s @ %d,%d,%d = %d"):format(n and n.name or "?", pos.x, pos.y, pos.z, data.power)
      end
    end
    if #out==0 then return true, "No powered Fabricate nodes within "..r.." nodes." end
    table.sort(out)
    min.chat_send_player(name, "Powered Fabricate nodes:")
    for _, line in ipairs(out) do min.chat_send_player(name, "  "..line) end
    return true, ""
  end
})


min.register_chatcommand("fab_probe", {
  description = "Show Fabricate power at the pointed node",
  func = function(name)
    local pl = min.get_player_by_name(name); if not pl then return false,"no player" end
    local eye = pl:get_pos(); eye.y = eye.y + 1.5
    local look = pl:get_look_dir()
    local ray = min.raycast(eye, {x=eye.x+look.x*6,y=eye.y+look.y*6,z=eye.z+look.z*6}, true, false)
    local target
    for hit in ray do if hit.type=="node" then target = hit.under; break end end
    if not target then return true, "No node targeted." end
    local k = pos_to_key(target)
    local e = fabricate.power_grid[k]
    local n = min.get_node_or_nil(target)
    local name_str = n and n.name or "?"
    if e then
      return true, ("%s at %s has power %d"):format(name_str, min.pos_to_string(target), e.power)
    else
      return true, ("%s at %s has NO power"):format(name_str, min.pos_to_string(target))
    end
  end
})

min.register_chatcommand("fab_rescan", {
  description = "Rescan a radius around you and (re)track Fabricate parts",
  params = "[radius]",
  func = function(name, param)
    local player = min.get_player_by_name(name); if not player then return false, "No player." end
    local r = tonumber(param) or 16
    local pmin = vector.subtract(vector.round(player:get_pos()), r)
    local pmax = vector.add(vector.round(player:get_pos()), r)
    local count = 0
    for x = pmin.x, pmax.x do
      for y = pmin.y, pmax.y do
        for z = pmin.z, pmax.z do
          local pos = {x=x,y=y,z=z}
          local n = min.get_node_or_nil(pos)
          if n and is_mech(n.name) then
            track_mech(pos); count = count + 1
          end
        end
      end
    end
    return true, ("Tracked %d mechanical nodes within r=%d."):format(count, r)
  end
})
