-- fabricate/init.lua
-- Fabricate: simple Create-like kinetic network for Luanti.
-- Not affiliated with the Create team.

local min    = rawget(_G, "core") or minetest
local vector = vector
local math   = math

local modname = min.get_current_modname() or "fabricate"
local NS      = modname .. ":"

-- -------------------------------------------------
-- Global API (reload-safe)
-- -------------------------------------------------
fabricate = rawget(_G, "fabricate") or {}
fabricate.tracked_mech    = fabricate.tracked_mech    or {}
fabricate.power_grid      = fabricate.power_grid      or {}
fabricate.get_power_for   = fabricate.get_power_for   or {}
fabricate.on_power_for    = fabricate.on_power_for    or {}
fabricate.dynamic_sources = fabricate.dynamic_sources or {}
fabricate.belts           = fabricate.belts           or {}

local get_power_for = fabricate.get_power_for
local on_power_for  = fabricate.on_power_for

-- -------------------------------------------------
-- Helpers
-- -------------------------------------------------
local function pos_to_key(p)
  return ("%d,%d,%d"):format(p.x,p.y,p.z)
end

local DIRS = {
  {x= 1,y= 0,z= 0},{x=-1,y= 0,z= 0},
  {x= 0,y= 1,z= 0},{x= 0,y=-1,z= 0},
  {x= 0,y= 0,z= 1},{x= 0,y= 0,z=-1},
}

local HDIRS = { -- horizontal adjacency for wheel clusters
  {x= 1,y=0,z= 0}, {x=-1,y=0,z= 0},
  {x= 0,y=0,z= 1}, {x= 0,y=0,z=-1},
}

local function facedir_to_dir(param2)
  local rot = (param2 or 0) % 4
  if rot == 0 then return {x=0,y=0,z= 1}
  elseif rot==1 then return {x=1,y=0,z=0}
  elseif rot==2 then return {x=0,y=0,z=-1}
  else return {x=-1,y=0,z=0} end
end

local function has_water_near_wheel(pos)
  for dx=-1,1 do
    for dy=-1,1 do
      for dz=-1,1 do
        local np = {x=pos.x+dx,y=pos.y+dy,z=pos.z+dz}
        local n  = min.get_node_or_nil(np)
        if n then
          local def = min.registered_nodes[n.name]
          if def and def.liquidtype and def.liquidtype ~= "none" then
            return true
          end
        end
      end
    end
  end
  return false
end

-- contiguous, horizontally adjacent, water-fed wheel cluster size
local function wheel_cluster_size(pos, limit)
  limit = limit or 32
  local name = NS.."water_wheel"
  local function k(p) return ("%d,%d,%d"):format(p.x,p.y,p.z) end
  local n = min.get_node_or_nil(pos)
  if not (n and n.name == name and has_water_near_wheel(pos)) then return 0 end
  local q, seen, count = {vector.new(pos)}, {[k(pos)]=true}, 0
  while #q>0 and count<limit do
    local cur = table.remove(q,1); count = count + 1
    for _,d in ipairs(HDIRS) do
      local np = {x=cur.x+d.x, y=cur.y+d.y, z=cur.z+d.z}
      local kk = k(np)
      if not seen[kk] then
        local nn = min.get_node_or_nil(np)
        if nn and nn.name == name and has_water_near_wheel(np) then
          seen[kk] = true; q[#q+1] = np
        end
      end
    end
  end
  return count
end

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

local function track_mech(pos)
  fabricate.tracked_mech[pos_to_key(pos)] = vector.new(pos)
end
local function untrack_mech(pos)
  fabricate.tracked_mech[pos_to_key(pos)] = nil
end

-- =========================================================
-- Stress Units (very simple Create-like stress model)
-- =========================================================

-- How much stress each consumer needs to run at full speed.
-- Tune these numbers to taste.
local STRESS_COST = {
  [NS.."encased_fan"]      = 8,   -- light load
  [NS.."mechanical_drill"] = 16,  -- heavier load
  -- you can add more later: presses, saws, etc.
}

-- Optional: label for infotext
local function stress_label(name, available)
  local need = STRESS_COST[name]
  if not need or need <= 0 then
    return nil
  end
  if available < need then
    return ("(overstressed: needs %d SU, has %d)"):format(need, available)
  else
    return ("(OK: needs %d SU, has %d)"):format(need, available)
  end
end

-- Quick check helper
local function has_stress(name, available)
  local need = STRESS_COST[name]
  if not need or need <= 0 then
    return true, 0
  end
  if available < need then
    return false, need
  end
  return true, need
end

-- -------------------------------------------------
-- Crack Overlay Entity (spritesheet: 16x80, 5 frames)
-- -------------------------------------------------
-- Required textures in textures/:
--   fabricate_crack_strip.png (5 frames stacked vertically: 0..4)
--   fabricate_crack_empty.png (fully transparent 16x16)
local CRACK_SPRITE = "fabricate_crack_strip.png"
local CRACK_EMPTY  = "fabricate_crack_empty.png"
local CRACK_FRAMES = 5  -- frames indexed 0..4 (top→bottom)

local function crack_textures_for(dir, frame)
  local crack = CRACK_SPRITE .. "^[verticalframe:"..CRACK_FRAMES..":"..frame
  -- Entity face order: top, bottom, right(+X), left(-X), back(+Z), front(-Z)
  if     dir.x ==  1 then
    return {CRACK_EMPTY,CRACK_EMPTY,crack,      CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY}
  elseif dir.x == -1 then
    return {CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,crack,      CRACK_EMPTY,CRACK_EMPTY}
  elseif dir.z ==  1 then
    return {CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,crack,      CRACK_EMPTY}
  elseif dir.z == -1 then
    return {CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,crack}
  else
    return {CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY}
  end
end

min.register_entity(NS.."crack_overlay", {
  initial_properties = {
    visual = "cube",
    textures = {CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY},
    physical = false,
    collide_with_objects = false,
    pointable = false,
    visual_size = {x=1.0,y=1.0,z=1.0},
    use_texture_alpha = true,
    shaded = false,
    glow = 0,
    static_save = false,
  },
  _dir = {x=0,y=0,z=1},
  _frame = 0,

  set_face_and_frame = function(self, dir, frame)
    self._dir   = {x=dir.x,y=dir.y,z=dir.z}
    self._frame = frame
    self.object:set_properties({textures = crack_textures_for(dir, frame)})
  end,
})

local function find_overlay_at(tpos)
  for _, obj in ipairs(min.get_objects_inside_radius(
    {x=tpos.x+0.5,y=tpos.y+0.5,z=tpos.z+0.5}, 0.6)) do
    local ent = obj:get_luaentity()
    if ent and ent.name == NS.."crack_overlay" then
      return obj, ent
    end
  end
  return nil, nil
end

local function ensure_overlay(tpos, dir, frame)
  local obj, ent = find_overlay_at(tpos)
  if not obj then
    obj = min.add_entity(
      {x=tpos.x+0.5,y=tpos.y+0.5,z=tpos.z+0.5},
      NS.."crack_overlay"
    )
    ent = obj and obj:get_luaentity() or nil
  end
  if ent and ent.set_face_and_frame then
    ent:set_face_and_frame(dir, frame or 0)
  end
  return obj, ent
end

local function remove_overlay(tpos)
  local obj = find_overlay_at(tpos)
  if obj then obj:remove() end
end

-- -------------------------------------------------
-- Connectivity (face-adjacent)
-- -------------------------------------------------
local W  = NS.."water_wheel"
local G  = NS.."gantry_shaft"
local S  = NS.."shaft"
local X  = NS.."gearbox"
local F  = NS.."encased_fan"
local H  = NS.."hand_crank"
local D  = NS.."mechanical_drill"

local function can_connect(aname, bname)
  if not (is_mech(aname) and is_mech(bname)) then return false end

  -- Wheel mates with gantry, bare shaft, or a fan/drill
  if aname == W then return (bname == G or bname == S or bname == F or bname == D) end
  if bname == W then return (aname == G or aname == S or aname == F or aname == D) end

  -- Gantry bridges wheel ↔ driveline (and can pass to fan/drill)
  if aname == G then return (bname == W or bname == S or bname == X or bname == G or bname == F or bname == D) end
  if bname == G then return (aname == W or aname == S or aname == X or aname == G or aname == F or aname == D) end

  -- Crank can inject into driveline/fan/drill/gantry
  if aname == H then return (bname == S or bname == X or bname == G or bname == F or bname == D) end
  if bname == H then return (aname == S or aname == X or aname == G or aname == F or aname == D) end

  -- Shafts/gearboxes interconnect; fan/drill can hang off them
  local A_drive = (aname == S or aname == X)
  local B_drive = (bname == S or bname == X)
  if A_drive and B_drive then return true end
  if A_drive and (bname == F or bname == D) then return true end
  if B_drive and (aname == F or aname == D) then return true end

  return false
end

-- -------------------------------------------------
-- BFS power propagation
-- -------------------------------------------------
local function add_power(accum, key, pos, p)
  local ex = accum[key]
  if (not ex) or ex.power < p then
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
      if node_here and n and is_mech(n.name)
          and can_connect(node_here.name, n.name) then
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

  -- Sources → BFS
  for _, pos in pairs(fabricate.tracked_mech) do
    local node = min.get_node_or_nil(pos)
    if node and is_source(node.name) then
      local fn = get_power_for[node.name]
      local p  = fn and (fn(pos, node, dt, now) or 0) or 0
      if p > 0 then
        add_power(accum, pos_to_key(pos), pos, p)
        bfs(accum, pos, p)
      end
    end
  end

  -- Terminal backfill for FAN & DRILL (inherit neighbor_power-1 if BFS missed)
  for _, pos in pairs(fabricate.tracked_mech) do
    local n = min.get_node_or_nil(pos)
    if n and (n.name == F or n.name == D) then
      local selfk = pos_to_key(pos)
      if not accum[selfk] then
        local best = 0
        for _, d in ipairs(DIRS) do
          local np = {x=pos.x+d.x, y=pos.y+d.y, z=pos.z+d.z}
          local nn = min.get_node_or_nil(np)
          if nn and is_mech(nn.name) and can_connect(n.name, nn.name) then
            local e = accum[pos_to_key(np)]
            if e and e.power > best then best = e.power end
          end
        end
        if best > 0 then
          add_power(accum, selfk, pos, math.max(1, best - 1))
        end
      end
    end
  end

  fabricate.power_grid = accum

  -- Clear infotexts
  for _, pos in pairs(fabricate.tracked_mech) do
    min.get_meta(pos):set_string("infotext", "")
  end

  -- Drive consumers + labels
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
        [NS.."water_wheel"]      = "Water Wheel",
        [NS.."gantry_shaft"]     = "Gantry Shaft",
        [NS.."shaft"]            = "Shaft",
        [NS.."gearbox"]          = "Gearbox",
        [NS.."hand_crank"]       = "Hand Crank",
        [NS.."encased_fan"]      = "Encased Fan",
        [NS.."mechanical_drill"] = "Mechanical Drill",
      })[name] or name
      min.get_meta(pos):set_string("infotext", label.." (power "..power..")")
    end
    ::continue::
  end

  -- Unpowered consumers
  for _, pos in pairs(fabricate.tracked_mech) do
    local node = min.get_node_or_nil(pos)
    if node and is_consumer(node.name)
        and not accum[pos_to_key(pos)] then
      local label = ({
        [NS.."encased_fan"]      = "Encased Fan",
        [NS.."mechanical_drill"] = "Mechanical Drill",
      })[node.name] or "Consumer"
      min.get_meta(pos):set_string("infotext", label.." (no power)")
    end
  end
end)

-- ======================================================================
-- Wrench: rotate mechanical blocks & interact with fans
-- ======================================================================

-- simple rotator: step facedir yaw by 90°
local function wrench_rotate_node(pos, node)
  local def = min.registered_nodes[node.name]
  if not def or def.paramtype2 ~= "facedir" then return end

  local p2 = node.param2 or 0
  -- yaw-only: just cycle 0..3
  p2 = (p2 + 1) % 4

  node.param2 = p2
  min.swap_node(pos, node)
end

-- Item: Fabricate Wrench
min.register_craftitem(NS.."wrench", {
  description     = "Fabricate Wrench",
  inventory_image = "fabricate_wrench.png", -- add this texture
  stack_max       = 1,
})

-- Rotate any fabricate_mech node when punched with the wrench
min.register_on_punchnode(function(pos, node, puncher, pointed_thing)
  if not puncher or not puncher:is_player() then return end

  local stack = puncher:get_wielded_item()
  if stack:get_name() ~= NS.."wrench" then return end

  if not is_mech(node.name) then return end

  wrench_rotate_node(pos, node)
end)

-- Wrench crafting recipe (tweak as you like)
min.register_craft({
  output = NS.."wrench",
  recipe = {
    {"default:steel_ingot", "default:steel_ingot", ""},
    {"",                     "default:stick",       ""},
    {"",                     "default:stick",       ""},
  }
})

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
  node_box    = {
    type="fixed",
    fixed = { {-0.1,-0.1,-0.5, 0.1,0.1,0.5} }, -- rod along Z
  },
  groups      = { cracky=2, oddly_breakable_by_hand=2, fabricate_mech=1 },
  on_construct= track_mech,
  on_destruct = untrack_mech,

  on_place = function(itemstack, placer, pt)
    if pt.type ~= "node" then
      return min.item_place(itemstack, placer, pt)
    end
    local under, above = pt.under, pt.above
    if not under or not above then
      return min.item_place(itemstack, placer, pt)
    end
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

-- Gantry Shaft
local GANTRY_BOX = {
  type="fixed",
  fixed = {
    {-0.30,-0.30,-0.50,  0.30, 0.30,-0.25}, -- collar
    {-0.10,-0.10,-0.25,  0.10, 0.10, 0.50}, -- outward stub
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
  on_place = function(itemstack, placer, pt)
    if pt.type ~= "node" then
      return min.item_place(itemstack, placer, pt)
    end
    local under, above = pt.under, pt.above
    if not under or not above then
      return min.item_place(itemstack, placer, pt)
    end
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

-- Hand Crank (dynamic source)
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
  groups       = {
    choppy=2, oddly_breakable_by_hand=2,
    fabricate_mech=1, fabricate_source=1
  },
  on_construct = function(pos)
    track_mech(pos)
    min.get_meta(pos):set_string("infotext","Hand Crank")
  end,
  on_destruct  = function(pos)
    untrack_mech(pos)
    fabricate.dynamic_sources[pos_to_key(pos)] = nil
  end,
  on_rightclick = function(pos, node, clicker)
    fabricate.dynamic_sources[pos_to_key(pos)] = {
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

-- Water Wheel (source; recentered selection box + cluster boost)
do
  -- Selection box tuned for a 1.25 visual_scale wheel
  local SEL_OFF_X, SEL_OFF_Y, SEL_OFF_Z = 0.00, 0.12, 0.00
  local SEL_HW, SEL_HH, SEL_HD = 0.50, 0.62, 0.50
  local function make_selbox()
    local x1 = -SEL_HW + SEL_OFF_X; local x2 = SEL_HW + SEL_OFF_X
    local y1 = -SEL_HH + SEL_OFF_Y; local y2 = SEL_HH + SEL_OFF_Y
    local z1 = -SEL_HD + SEL_OFF_Z; local z2 = SEL_HD + SEL_OFF_Z
    return { type="fixed", fixed={{x1,y1,z1, x2,y2,z2}} }
  end

  min.register_node(NS.."water_wheel", {
    description  = "Fabricate Water Wheel",
    drawtype     = "mesh",
    mesh         = "water_wheel.obj",
    tiles        = {"mcl_core_planks_big_oak.png"},
    paramtype    = "light",
    paramtype2   = "facedir",
    visual_scale = 1.25,
    selection_box = make_selbox(),
    collision_box = { type="fixed",
      fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },
    groups       = {
      choppy=2, oddly_breakable_by_hand=2,
      fabricate_mech=1, fabricate_source=1
    },
    on_construct = function(pos)
      track_mech(pos)
      min.get_meta(pos):set_string("infotext","Water Wheel (no water)")
    end,
    on_destruct  = untrack_mech,
  })

  local WHEEL_BASE_POWER = 8
  local WHEEL_MAX_POWER  = 64
  get_power_for[NS.."water_wheel"] = function(pos, node, dt, now)
    local m = min.get_meta(pos)
    if not has_water_near_wheel(pos) then
      m:set_string("infotext","Water Wheel (no water)")
      return 0
    end
    local cluster = wheel_cluster_size(pos, 32)
    local power = math.min(
      WHEEL_MAX_POWER,
      WHEEL_BASE_POWER * math.max(1, cluster)
    )
    m:set_string("infotext",
      ("Water Wheel (cluster %d → power %d)")
        :format(cluster, power))
    return power
  end
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
    "fabricate_fan_front.png",  -- front (airflow along facedir)
  },
  paramtype2   = "facedir",
  groups       = { cracky=2, fabricate_mech=1, fabricate_consumer=1 },

  on_construct = function(pos)
    track_mech(pos)
    local meta = min.get_meta(pos)
    meta:set_string("mode", "push") -- "push" or "pull"
    meta:set_string("infotext", "Encased Fan (push, no power)")
  end,

  on_destruct  = untrack_mech,

  -- Use wrench right-click to toggle push/pull
  on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
    if not clicker or not clicker:is_player() then return itemstack end

    local wield = clicker:get_wielded_item()
    if wield:get_name() ~= NS.."wrench" then
      -- not holding wrench: let other interactions (like formspecs) happen later if we add them
      return itemstack
    end

    local meta = min.get_meta(pos)
    local mode = meta:get_string("mode")
    if mode == "pull" then
      mode = "push"
    else
      mode = "pull"
    end
    meta:set_string("mode", mode)

    -- infotext wording; on_power_for will usually overwrite with power/medium
    meta:set_string("infotext",
      ("Encased Fan (%s)"):format(mode))

    return itemstack
  end,
})

-- ======================================================================
-- Encased Fan helpers: medium detection, particles, item washing/smelting
-- ======================================================================

-- Shared recipe tables (can be edited from other files)
FAN_WASH_RECIPES  = FAN_WASH_RECIPES  or {}
FAN_SMELT_RECIPES = FAN_SMELT_RECIPES or {}

-- Decide what the fan is blowing through: "air" | "water" | "lava"
local function fan_get_medium(pos, dir)
  local front = {
    x = pos.x + dir.x,
    y = pos.y + dir.y,
    z = pos.z + dir.z,
  }
  local node = min.get_node_or_nil(front)
  if not node then
    return "air", front
  end

  local def = min.registered_nodes[node.name]
  if not def then
    return "air", front
  end

  -- Liquids
  if def.liquidtype and def.liquidtype ~= "none" then
    local g = def.groups or {}
    if (g.lava and g.lava > 0) or node.name:find("lava") then
      return "lava", front
    else
      return "water", front
    end
  end

  -- Fallback: name-based
  if node.name:find("lava") then return "lava", front end
  if node.name:find("water") then return "water", front end

  return "air", front
end

-- Pick texture for particle stream
local function fan_particle_texture(medium)
  if medium == "water" then return "default_water.png" end
  if medium == "lava"  then return "default_lava.png"  end
  -- add this texture in your pack, or change to something that exists
  return "fabricate_fan_air.png"
end

on_power_for[NS.."encased_fan"] = function(pos, node, power, dt)
  local meta = min.get_meta(pos)
  local mode = meta:get_string("mode")
  if mode ~= "pull" then mode = "push" end  -- default sanity

  if power < 2 then
    meta:set_string("infotext",
      ("Encased Fan (%s, no power)"):format(mode))
    return
  end

  local dir = facedir_to_dir(node.param2 or 0)

  -- medium + position of the block directly in front
  local medium, front_pos = fan_get_medium(pos, dir)

  meta:set_string("infotext",
    ("Encased Fan (%s, %s, power %d)")
      :format(mode, medium, power))

  local eff_dir = {
    x = (mode == "push") and dir.x or -dir.x,
    y = (mode == "push") and dir.y or -dir.y,
    z = (mode == "push") and dir.z or -dir.z,
  }

  local range = math.min(4 + math.floor(power / 2), 12)

  -- Center of tunnel for gameplay (unchanged)
  local c = {
    x = pos.x + dir.x * (range * 0.5 + 0.5),
    y = pos.y + dir.y * (range * 0.5),
    z = pos.z + dir.z * (range * 0.5 + 0.5),
  }

  -- === PARTICLES =======================================================
  local ptex = fan_particle_texture(medium)
  if min.add_particlespawner and ptex then
    -- If blowing through water/lava, spawn particles a bit **after** that block,
    -- so you see them past the fluid.
    local base_x, base_y, base_z

    if medium == "water" or medium == "lava" then
      -- just beyond the fluid block
      base_x = front_pos.x + dir.x * 0.7
      base_y = front_pos.y + dir.y * 0.7
      base_z = front_pos.z + dir.z * 0.7
    else
      -- regular air: just in front of the fan
      base_x = pos.x + dir.x * 0.6
      base_y = pos.y + dir.y * 0.5
      base_z = pos.z + dir.z * 0.6
    end

    min.add_particlespawner({
      amount = 16,
      time   = 0.1,

      -- small box around the base,
      -- but we stretch it slightly along the direction so it *looks* like a stream
      minpos = {
        x = base_x - 0.3,
        y = base_y - 0.2,
        z = base_z - 0.3,
      },
      maxpos = {
        x = base_x + 0.3 + dir.x * 0.8,
        y = base_y + 0.2,
        z = base_z + 0.3 + dir.z * 0.8,
      },

      minvel = {
        x = eff_dir.x * 1.0,
        y = eff_dir.y * 0.2,
        z = eff_dir.z * 1.0,
      },
      maxvel = {
        x = eff_dir.x * 2.5,
        y = eff_dir.y * 0.6,
        z = eff_dir.z * 2.5,
      },

      minacc = {x = 0, y = 0, z = 0},
      maxacc = {x = 0, y = 0, z = 0},
      minexptime = 0.2,
      maxexptime = 0.8,
      minsize = 0.7,
      maxsize = 1.8,
      texture = ptex,
      glow    = (medium == "lava") and 4 or 0,
    })
  end

  -- === ENTITY / ITEM HANDLING (unchanged from your last version) ======
  -- keep the rest of your code here: airflow, washing/smelting, etc.
  -----------------------------------------------------------------------
  for _, obj in ipairs(min.get_objects_inside_radius(c, range + 1)) do
    local ent = obj:get_luaentity()
    local is_helper = ent and ent.name and ent.name:find("^"..NS)
    if not is_helper then
      local is_item = ent and ent.name == "__builtin:item"

      local p = obj:get_pos()
      if p then
        local along =
          (dir.x ~= 0 and (p.x - pos.x) * dir.x) or
          (dir.z ~= 0 and (p.z - pos.z) * dir.z) or 0

        if along >= -1 and along <= range + 2 then
          local v = obj:get_velocity() or {x = 0, y = 0, z = 0}
          local boost = (power / 8) * 4

          v.x = v.x + eff_dir.x * boost
          v.y = v.y + eff_dir.y * (boost * 0.2)
          v.z = v.z + eff_dir.z * boost

          v.x = v.x * 0.96
          v.z = v.z * 0.96
          obj:set_velocity(v)

          if is_item and (medium == "water" or medium == "lava") then
            local stack = ItemStack(ent.itemstring or "")
            if not stack:is_empty() then
              local iname   = stack:get_name()
              local outname = (medium == "water")
                and FAN_WASH_RECIPES[iname]
                or  FAN_SMELT_RECIPES[iname]

              if outname then
                stack:set_name(outname)
                stack:set_count(stack:get_count())
                ent.itemstring = stack:to_string()
                if ent.set_item then ent:set_item(stack) end
              end
            end
          end
        end
      end
    end
  end
end

-- ======================================================================
-- Mechanical Drill (consumer) + cracking overlay + stress gate
-- ======================================================================

min.register_node(NS.."mechanical_drill", {
  description = "Fabricate Mechanical Drill",
  drawtype    = "nodebox",
  tiles = {
    "fabricate_drill_top.png",
    "fabricate_drill_bottom.png",
    "fabricate_drill_side.png",
    "fabricate_drill_side.png",
    "fabricate_drill_back.png",
    "fabricate_drill_front.png",
  },
  paramtype   = "light",
  paramtype2  = "facedir",
  node_box = {
    type="fixed",
    fixed = {
      {-0.40,-0.40,-0.40,  0.40, 0.40, 0.10}, -- body
      {-0.10,-0.10, 0.10,  0.10, 0.10, 0.55}, -- bit
    },
  },
  selection_box = {
    type  = "fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}},
  },
  collision_box = {
    type  = "fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}},
  },
  groups       = { cracky=2, fabricate_mech=1, fabricate_consumer=1 },
  on_construct = function(pos)
    track_mech(pos)
    local m = min.get_meta(pos)
    m:set_string("infotext","Mechanical Drill (no power)")
    m:set_float("drill_progress", 0.0)
    m:set_string("drill_target", "")
    m:set_int("drill_stage", 0)
  end,
  on_destruct  = function(pos)
    local node = min.get_node_or_nil(pos)
    local dir  = facedir_to_dir(node and node.param2 or 0)
    local tpos = {x=pos.x+dir.x, y=pos.y+dir.y, z=pos.z+dir.z}
    remove_overlay(tpos)
    untrack_mech(pos)
  end,
})

local function node_hardness(nodename)
  if nodename == "air" then return 0 end
  local def = min.registered_nodes[nodename]
  if not def then return 6 end
  if def.drawtype == "airlike" then return 0 end
  if def.walkable == false then return 0 end
  if def.liquidtype and def.liquidtype ~= "none" then return 0 end
  local g = def.groups or {}
  local h = 2
  if g.cracky  then h = h + g.cracky  * 2 end
  if g.crumbly then h = h + g.crumbly * 1 end
  if g.choppy  then h = h + g.choppy  * 1 end
  if g.level   then h = h + g.level   * 1 end
  return math.max(1, h)
end

on_power_for[NS.."mechanical_drill"] = function(pos, node, power, dt)
  local meta = min.get_meta(pos)

  ------------------------------------------------------------------
  -- 1) STRESS GATE
  ------------------------------------------------------------------
  -- assumes has_stress(name, power) -> ok:boolean, required:number
  --         stress_label(name, power) -> string like "(OK 8/16)" or "(overstressed)"
  local ok, _need = has_stress(NS.."mechanical_drill", power)
  local stress_str = stress_label(NS.."mechanical_drill", power) or ("(power "..power..")")

  if not ok then
    meta:set_string("infotext", "Mechanical Drill "..stress_str)
    -- reset cracking + progress if overstressed
    local dir  = facedir_to_dir(node.param2 or 0)
    local tpos = {x=pos.x+dir.x, y=pos.y+dir.y, z=pos.z+dir.z}
    remove_overlay(tpos)
    meta:set_float("drill_progress", 0.0)
    meta:set_string("drill_target","")
    meta:set_int("drill_stage", 0)
    return
  end

  ------------------------------------------------------------------
  -- 2) LOW POWER GATE
  ------------------------------------------------------------------
  if power < 2 then
    meta:set_string("infotext", "Mechanical Drill "..stress_str.." (no power)")
    local dir  = facedir_to_dir(node.param2 or 0)
    local tpos = {x=pos.x+dir.x, y=pos.y+dir.y, z=pos.z+dir.z}
    remove_overlay(tpos)
    meta:set_float("drill_progress", 0.0)
    meta:set_string("drill_target", "")
    meta:set_int("drill_stage", 0)
    return
  end

  ------------------------------------------------------------------
  -- 3) TARGET BLOCK
  ------------------------------------------------------------------
  local dir  = facedir_to_dir(node.param2 or 0)
  local tpos = { x = pos.x + dir.x,
                 y = pos.y + dir.y,
                 z = pos.z + dir.z }
  local tnode = min.get_node_or_nil(tpos)

  if not tnode then
    meta:set_string("infotext","Mechanical Drill "..stress_str.." (idle: unloaded)")
    meta:set_float("drill_progress", 0.0)
    remove_overlay(tpos)
    meta:set_string("drill_target", "")
    meta:set_int("drill_stage", 0)
    return
  end

  local tname = tnode.name
  local def   = min.registered_nodes[tname]
  if (not def) or tname=="air"
      or (def.liquidtype and def.liquidtype~="none")
      or def.walkable==false then
    meta:set_string("infotext","Mechanical Drill "..stress_str.." (idle)")
    meta:set_float("drill_progress", 0.0)
    remove_overlay(tpos)
    meta:set_string("drill_target", "")
    meta:set_int("drill_stage", 0)
    return
  end

  if min.is_protected(tpos, "") then
    meta:set_string("infotext","Mechanical Drill "..stress_str.." (area protected)")
    remove_overlay(tpos)
    return
  end

  ------------------------------------------------------------------
  -- 4) PER-BLOCK STATE + PROGRESS
  ------------------------------------------------------------------
  local key = min.pos_to_string(tpos)
  if meta:get_string("drill_target") ~= key then
    -- new target: reset progress + cracks
    meta:set_string("drill_target", key)
    meta:set_float("drill_progress", 0.0)
    meta:set_int("drill_stage", 0)
    remove_overlay(tpos)
  end

  local hardness = node_hardness(tname)
  local prog     = meta:get_float("drill_progress")
  local speed    = (power / 8) * 1.2 -- 8 power ≈ 1.2 hardness/sec

  prog = prog + speed * dt

  -- frame 0..(CRACK_FRAMES-1) from progress
  local frame = math.min(
    CRACK_FRAMES-1,
    math.floor((prog / hardness) * CRACK_FRAMES)
  )
  local last  = meta:get_int("drill_stage")
  if frame ~= last then
    ensure_overlay(tpos, dir, frame)
    meta:set_int("drill_stage", frame)
  end

  ------------------------------------------------------------------
  -- 5) BREAK BLOCK
  ------------------------------------------------------------------
  if prog >= hardness then
    local drops = min.get_node_drops(tname) or {}
    min.remove_node(tpos)
    for _, item in ipairs(drops) do
      min.add_item(tpos, item)
    end
    remove_overlay(tpos)
    prog = 0.0
    meta:set_string("drill_target","")
    meta:set_int("drill_stage", 0)
  end

  meta:set_float("drill_progress", prog)

  local percent = (prog / hardness) * 100
  meta:set_string(
    "infotext",
    ("Mechanical Drill %s, %.0f%%")
      :format(stress_str, percent)
  )
end

-- -------------------------------------------------
-- LBM: Track existing fabricate_mech nodes when a mapblock loads
-- -------------------------------------------------
min.register_lbm({
  name = NS.."track_existing_mech",
  nodenames = {"group:fabricate_mech"},
  run_at_every_load = true,
  action = function(pos, node) track_mech(pos) end,
})

-- -------------------------------------------------
-- Crafting (core parts)
-- -------------------------------------------------
min.register_craft({ output = NS.."shaft 4", recipe = {
  {"default:steel_ingot"},
  {"default:stick"},
  {"default:steel_ingot"},
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
  {"group:wood"},
  {"default:stick"},
  {"default:stick"},
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
min.register_craft({ output = NS.."mechanical_drill", recipe = {
  {"default:steel_ingot", NS.."shaft",       "default:steel_ingot"},
  {"default:steel_ingot", "default:diamond", "default:steel_ingot"},
  {"default:steel_ingot", NS.."gearbox",     "default:steel_ingot"},
}})

-- ======================================================================
-- Create-like Shafts + Mechanical Belts (no pulley blocks)
-- ======================================================================

-- ---- Tunables ----------------------------------------------------------
local BELT_MIN_POWER   = 2
local BELT_BASE_SPEED  = 1.6   -- m/s at min power
local BELT_SPEED_GAIN  = 0.25  -- m/s per extra power
local BELT_SPEED_MAX   = 6.0
local BELT_CENTER_PULL = 2.2
local BELT_PICKUP_Y    = 0.55
local BELT_FRICTION    = 0.10

local function belt_speed_for_power(p)
  if not p or p < BELT_MIN_POWER then return 0 end
  local s = BELT_BASE_SPEED + (p - BELT_MIN_POWER) * BELT_SPEED_GAIN
  return (s > BELT_SPEED_MAX) and BELT_SPEED_MAX or s
end

-- line_id -> {segments={pos...}, axis="x"/"z", dir=±1, slope=0/±1, speed=0, anchors={a={pos,normal},b={...}}}
local BELT_COUNTER = 0
local function new_line_id()
  BELT_COUNTER = BELT_COUNTER + 1
  return "belt_"..min.get_gametime().."_"..BELT_COUNTER
end

-- Shared segment nodeboxes
local BELT_FLAT_BOX = {
  type="fixed",
  fixed={
    {-0.5,-0.5,-0.5,  0.5,-0.375,0.5},
    {-0.5,-0.375,-0.5,0.5,-0.345,0.5},
  }
}
local BELT_STEP_BOX = {
  type="fixed",
  fixed={
    {-0.5,-0.5,-0.5,  0.5,-0.375,0.5},
    {-0.5,-0.375,-0.5,0.5,-0.312,0.5},
  }
}

-- Virtual belt segments
min.register_node(NS.."belt_segment", {
  description = "Belt Segment (Flat)",
  drawtype    = "nodebox",
  node_box    = BELT_FLAT_BOX,
  selection_box = { type="fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,-0.345,0.5}} },
  collision_box = { type="fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,-0.375,0.5}} },
  tiles       = {
    "mcl_core_iron_block.png^[colorize:#3a3a3a:180",
    "mcl_core_iron_block.png^[colorize:#1e1e1e:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
  },
  paramtype   = "light",
  paramtype2  = "facedir",
  groups      = { cracky=2, not_in_creative_inventory=1 },
  drop        = "",
})

min.register_node(NS.."belt_segment_slope", {
  description = "Belt Segment (Slope)",
  drawtype    = "nodebox",
  node_box    = BELT_STEP_BOX,
  selection_box = { type="fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,-0.312,0.5}} },
  collision_box = { type="fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,-0.375,0.5}} },
  tiles       = {
    "mcl_core_iron_block.png^[colorize:#3a3a3a:160",
    "mcl_core_iron_block.png^[colorize:#1e1e1e:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
  },
  paramtype   = "light",
  paramtype2  = "facedir",
  groups      = { cracky=2, not_in_creative_inventory=1 },
  drop        = "",
})

-- ========= Create-like belt linker (no pulley blocks, shafts must face same dir) =========

local BELT_MAX_LEN = 128   -- hard cap like Create

local function is_driveline(name)
  return name == NS.."shaft" or name == NS.."gearbox" or name == NS.."gantry_shaft"
end

-- Normal of the clicked face (horizontal only)
local function pointed_normal(pt)
  if not pt or pt.type ~= "node" or not pt.under or not pt.above then return nil end
  local n = {
    x = pt.under.x - pt.above.x,
    y = pt.under.y - pt.above.y,
    z = pt.under.z - pt.above.z,
  }
  if n.y ~= 0 then return nil end
  if math.abs(n.x) + math.abs(n.z) ~= 1 then return nil end
  return n
end

-- For shafts we only allow belts on the side faces perpendicular to the rod axis.
-- Shaft param2: 0 => rod along Z, 1 => rod along X (your node)
local function shaft_face_ok(node, face_normal)
  if node.name ~= NS.."shaft" then
    -- gearboxes / gantries: any horizontal side is allowed
    return face_normal.y == 0
  end
  local alongX = (node.param2 or 0) % 4 == 1
  if alongX then
    -- rod along ±X ⇒ valid faces are ±Z
    return face_normal.x == 0 and face_normal.z ~= 0
  else
    -- rod along ±Z ⇒ valid faces are ±X
    return face_normal.z == 0 and face_normal.x ~= 0
  end
end

local function axis_of(a, b)
  if a.x == b.x and a.z ~= b.z then return "z" end
  if a.z == b.z and a.x ~= b.x then return "x" end
  return nil
end

local function dir_1d(a, b, axis)
  if axis == "x" then return (b.x > a.x) and 1 or -1 end
  if axis == "z" then return (b.z > a.z) and 1 or -1 end
  return 0
end

-- Build straight/slope belt run, returns line id or nil,err
local function build_belt_run(user, a_pos, b_pos)
  -- 1) Both blocks must be driveline
  local an = min.get_node_or_nil(a_pos)
  local bn = min.get_node_or_nil(b_pos)
  if not (an and bn and is_driveline(an.name) and is_driveline(bn.name)) then
    return nil, "Anchors must be shafts / gearboxes / gantries."
  end

  -- 2) Must be aligned on X or Z (no corners)
  local ax = axis_of(a_pos, b_pos)
  if not ax then
    return nil, "Shafts must align on X or Z (no corners)."
  end

  -- 3) Direction, length, vertical delta
  local dir   = dir_1d(a_pos, b_pos, ax)
  local steps = (ax=="x") and math.abs(b_pos.x - a_pos.x)
                           or math.abs(b_pos.z - a_pos.z)
  local dy    = b_pos.y - a_pos.y

  if steps == 0 and dy == 0 then
    return nil, "Anchors overlap."
  end
  if steps + math.abs(dy) > BELT_MAX_LEN then
    return nil, "Belt is too long."
  end

  -- 4) Create belt line
  local lid = new_line_id()
  fabricate.belts[lid] = {
    segments = {},
    axis     = ax,
    dir      = dir,
    slope    = (dy==0) and 0 or ((dy>0) and 1 or -1),
    speed    = 0,
    anchors  = {
      a = vector.new(a_pos),
      b = vector.new(b_pos),
    }
  }

  local facedir = (ax=="x")
    and ((dir==1) and 1 or 3)
    or  ((dir==1) and 0 or 2)

  local cx, cy, cz = a_pos.x, a_pos.y, a_pos.z
  local ax_step     = (dir==1) and 1 or -1
  local remain_y    = dy

  local function place_seg(p, name)
    local nn = min.get_node_or_nil(p)
    if nn and nn.name ~= "air"
           and nn.name ~= NS.."belt_segment"
           and nn.name ~= NS.."belt_segment_slope" then
      return false, "Path blocked at "..min.pos_to_string(p)
    end
    -- base node
    min.set_node(p, {name=name, param2=facedir})
    -- tiny raised copy used as belt “track”
    local pp = {x=p.x, y=p.y+0.05, z=p.z}
    min.set_node(pp, {name=name, param2=facedir})
    table.insert(fabricate.belts[lid].segments, vector.new(pp))
    return true
  end

  -- run along axis, weaving in vertical steps
  for i = 1, steps do
    if remain_y ~= 0 then
      cy = cy + ((remain_y>0) and 1 or -1)
      local okp, errp = place_seg({x=cx, y=cy, z=cz}, NS.."belt_segment_slope")
      if not okp then fabricate.belts[lid] = nil; return nil, errp end
      remain_y = (remain_y>0) and (remain_y-1) or (remain_y+1)
    else
      local okp, errp = place_seg({x=cx, y=cy, z=cz}, NS.."belt_segment")
      if not okp then fabricate.belts[lid] = nil; return nil, errp end
    end
    if ax == "x" then cx = cx + ax_step else cz = cz + ax_step end
  end

  while remain_y ~= 0 do
    cy = cy + ((remain_y>0) and 1 or -1)
    local okp, errp = place_seg({x=cx, y=cy, z=cz}, NS.."belt_segment_slope")
    if not okp then fabricate.belts[lid] = nil; return nil, errp end
    remain_y = (remain_y>0) and (remain_y-1) or (remain_y+1)
  end

  return lid
end

-- Player tool: click driveline A then driveline B
min.register_craftitem(NS.."belt_linker", {
  description = "Fabricate Mechanical Belt",
  inventory_image = "mcl_core_iron_block.png^[colorize:#3a3a3a:150",
  on_use = function(stack, user, pointed)
    if not user or not pointed or pointed.type ~= "node" then return stack end

    local pos  = pointed.under
    local node = min.get_node_or_nil(pos)
    if not node or not is_driveline(node.name) then
      min.chat_send_player(user:get_player_name(),
        "Click a shaft / gearbox / gantry.")
      return stack
    end

    -- Require side face (no top / bottom)
    if pointed.above and pointed.under then
      local ny = pointed.under.y - pointed.above.y
      if ny ~= 0 then
        min.chat_send_player(user:get_player_name(),
          "Click a horizontal side of the shaft.")
        return stack
      end
    end

    local um = user:get_meta()
    local a_pos_s = um:get_string("fab_link_a_pos")

    -- First click
    if a_pos_s == "" then
      um:set_string("fab_link_a_pos", min.pos_to_string(pos))
      min.chat_send_player(user:get_player_name(),
        "First shaft set. Click the second shaft with the belt linker.")
      return stack
    end

    -- Second click
    local a_pos = min.string_to_pos(a_pos_s)
    um:set_string("fab_link_a_pos", "")

    if not a_pos then
      min.chat_send_player(user:get_player_name(),
        "Internal error: bad saved position.")
      return stack
    end

    local lid, err = build_belt_run(user, a_pos, pos)
    if not lid then
      min.chat_send_player(user:get_player_name(),
        "Belt failed: "..(err or "?"))
    else
      min.chat_send_player(user:get_player_name(), "Belt built.")
    end

    return stack
  end
})

-- Crafting
min.register_craft({
  output = NS.."belt_linker",
  recipe = {
    {"group:wool","group:wool","group:wool"},
    {"","default:steel_ingot",""},
    {"group:wool","group:wool","group:wool"},
  }
})

-- Remove whole belt by punching any segment
-- Remove whole belt by punching any segment
min.register_on_punchnode(function(pos, node, puncher, pt)
  if node.name ~= NS.."belt_segment"
  and node.name ~= NS.."belt_segment_slope" then
    return
  end

  for id, line in pairs(fabricate.belts) do
    for _, sp in ipairs(line.segments or {}) do
      if sp.x == pos.x and sp.y == pos.y and sp.z == pos.z then
        -- remove all segments of this belt
        for _, p in ipairs(line.segments or {}) do
          local n2 = min.get_node_or_nil(p)
          if n2 and (n2.name == NS.."belt_segment"
                 or n2.name == NS.."belt_segment_slope") then
            min.remove_node(p)
          end
        end
        fabricate.belts[id] = nil
        if puncher and puncher:is_player() then
          min.chat_send_player(puncher:get_player_name(), "Belt removed.")
        end
        return
      end
    end
  end
end)

-- ---- Movement step (entities & items) ----------------------------------
local belt_step_accum = 0
min.register_globalstep(function(dtime)
  belt_step_accum = belt_step_accum + dtime
  if belt_step_accum < 0.1 then return end
  local dt = belt_step_accum
  belt_step_accum = 0

  -- Reset computed speeds
  for _, line in pairs(fabricate.belts or {}) do
    line.speed = 0
  end

  -- Compute speed from anchor shaft power
  for lid, line in pairs(fabricate.belts or {}) do
    local best = 0
    if line.anchors then
      local a = line.anchors.a and line.anchors.a.pos
      local b = line.anchors.b and line.anchors.b.pos
      if a then
        local ea = fabricate.power_grid[pos_to_key(a)]
        if ea and ea.power and ea.power > best then best = ea.power end
      end
      if b then
        local eb = fabricate.power_grid[pos_to_key(b)]
        if eb and eb.power and eb.power > best then best = eb.power end
      end
    end
    line.speed = belt_speed_for_power(best)
  end

  -- Move riders
  for lid, line in pairs(fabricate.belts or {}) do
    local spd = line.speed or 0
    if spd <= 0 then goto nextline end
    local dir = (line.axis=="x")
      and {x=line.dir,y=0,z=0}
      or  {x=0,y=0,z=line.dir}
    local perp = (line.axis=="x")
      and {x=0,y=0,z=1}
      or  {x=1,y=0,z=0}
    local ybias = (line.slope==0) and 0 or (line.slope * 0.5)

    for _, segpos in ipairs(line.segments or {}) do
      local scan_center = {
        x = segpos.x + 0.5,
        y = segpos.y + BELT_PICKUP_Y,
        z = segpos.z + 0.5,
      }
      for _, obj in ipairs(
        min.get_objects_inside_radius(scan_center, 0.8)
      ) do
        local ent = obj:get_luaentity()
        if ent and ent.name and ent.name:find("^"..NS) then
          goto nextobj
        end -- ignore our helpers

        local p = obj:get_pos(); if not p then goto nextobj end
        if math.abs(p.y - (segpos.y + 0.525)) < 0.35 then
          local v = obj:get_velocity() or {x=0,y=0,z=0}

          -- Forward push
          v.x = v.x + dir.x * spd * dt * 8
          v.z = v.z + dir.z * spd * dt * 8

          -- Keep seated on slopes
          v.y = (obj:is_player() and v.y)
            or math.min(v.y + ybias * dt, 1.0)

          -- Centering toward belt middle
          local offx = (p.x - (segpos.x + 0.5))
          local offz = (p.z - (segpos.z + 0.5))
          local lateral = offx * perp.x + offz * perp.z
          v.x = v.x - perp.x * lateral * BELT_CENTER_PULL * dt
          v.z = v.z - perp.z * lateral * BELT_CENTER_PULL * dt

          -- Mild friction
          v.x = v.x * (1 - BELT_FRICTION * dt)
          v.z = v.z * (1 - BELT_FRICTION * dt)

          obj:set_velocity(v)

          -- Keep items from sinking
          if not obj:is_player()
              and p.y < segpos.y + 0.45 then
            obj:set_pos({x=p.x, y=segpos.y + 0.46, z=p.z})
          end
        end
        ::nextobj::
      end
    end
    ::nextline::
  end
end)

-- -------------------------------------------------
-- Debug commands
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
      if math.abs(pos.x-p.x)<=r
          and math.abs(pos.y-p.y)<=r
          and math.abs(pos.z-p.z)<=r then
        local n = min.get_node_or_nil(pos)
        out[#out+1] = ("%s @ %d,%d,%d = %d")
          :format(n and n.name or "?", pos.x, pos.y, pos.z, data.power)
      end
    end
    if #out==0 then
      return true,
        "No powered Fabricate nodes within "..r.." nodes."
    end
    table.sort(out)
    min.chat_send_player(name, "Powered Fabricate nodes:")
    for _, line in ipairs(out) do
      min.chat_send_player(name, "  "..line)
    end
    return true, ""
  end
})

min.register_chatcommand("fab_probe", {
  description = "Show Fabricate power at the pointed node",
  func = function(name)
    local pl = min.get_player_by_name(name)
    if not pl then return false,"no player" end
    local eye = pl:get_pos(); eye.y = eye.y + 1.5
    local look = pl:get_look_dir()
    local ray = min.raycast(
      eye,
      {x=eye.x+look.x*6,y=eye.y+look.y*6,z=eye.z+look.z*6},
      true, false
    )
    local target
    for hit in ray do
      if hit.type=="node" then target = hit.under; break end
    end
    if not target then return true, "No node targeted." end
    local k = pos_to_key(target)
    local e = fabricate.power_grid[k]
    local n = min.get_node_or_nil(target)
    local name_str = n and n.name or "?"
    if e then
      return true, ("%s at %s has power %d")
        :format(name_str, min.pos_to_string(target), e.power)
    else
      return true, ("%s at %s has NO power")
        :format(name_str, min.pos_to_string(target))
    end
  end
})

min.register_chatcommand("fab_rescan", {
  description = "Rescan a radius around you and (re)track Fabricate parts",
  params = "[radius]",
  func = function(name, param)
    local player = min.get_player_by_name(name)
    if not player then return false, "No player." end
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
    return true,
      ("Tracked %d mechanical nodes within r=%d.")
        :format(count, r)
  end
})

min.register_chatcommand("fab_belts", {
  description = "List all active belts",
  func = function(name)
    for id, line in pairs(fabricate.belts or {}) do
      min.chat_send_player(
        name,
        ("%s: %d segments, speed %.2f")
          :format(id, #line.segments, line.speed or 0)
      )
    end
    return true, "Done."
  end
})
