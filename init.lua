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

local get_power_for = fabricate.get_power_for
local on_power_for  = fabricate.on_power_for

-- -------------------------------------------------
-- Helpers
-- -------------------------------------------------
local function pos_to_key(p) return ("%d,%d,%d"):format(p.x,p.y,p.z) end

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

local function track_mech(pos)   fabricate.tracked_mech[pos_to_key(pos)] = vector.new(pos) end
local function untrack_mech(pos) fabricate.tracked_mech[pos_to_key(pos)] = nil end

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
  if     dir.x ==  1 then return {CRACK_EMPTY,CRACK_EMPTY,crack,      CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY}
  elseif dir.x == -1 then return {CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,crack,      CRACK_EMPTY,CRACK_EMPTY}
  elseif dir.z ==  1 then return {CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,crack,      CRACK_EMPTY}
  elseif dir.z == -1 then return {CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,CRACK_EMPTY,crack}
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
  for _, obj in ipairs(min.get_objects_inside_radius({x=tpos.x+0.5,y=tpos.y+0.5,z=tpos.z+0.5}, 0.6)) do
    local ent = obj:get_luaentity()
    if ent and ent.name == NS.."crack_overlay" then return obj, ent end
  end
  return nil, nil
end

local function ensure_overlay(tpos, dir, frame)
  local obj, ent = find_overlay_at(tpos)
  if not obj then
    obj = min.add_entity({x=tpos.x+0.5,y=tpos.y+0.5,z=tpos.z+0.5}, NS.."crack_overlay")
    ent = obj and obj:get_luaentity() or nil
  end
  if ent and ent.set_face_and_frame then ent:set_face_and_frame(dir, frame or 0) end
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
        [NS.."water_wheel"]     = "Water Wheel",
        [NS.."gantry_shaft"]    = "Gantry Shaft",
        [NS.."shaft"]           = "Shaft",
        [NS.."gearbox"]         = "Gearbox",
        [NS.."hand_crank"]      = "Hand Crank",
        [NS.."encased_fan"]     = "Encased Fan",
        [NS.."mechanical_drill"]= "Mechanical Drill",
      })[name] or name
      min.get_meta(pos):set_string("infotext", label.." (power "..power..")")
    end
    ::continue::
  end

  -- Unpowered consumers
  for _, pos in pairs(fabricate.tracked_mech) do
    local node = min.get_node_or_nil(pos)
    if node and is_consumer(node.name) and not accum[pos_to_key(pos)] then
      local label = ({
        [NS.."encased_fan"]      = "Encased Fan",
        [NS.."mechanical_drill"] = "Mechanical Drill",
      })[node.name] or "Consumer"
      min.get_meta(pos):set_string("infotext", label.." (no power)")
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
    collision_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },
    groups       = { choppy=2, oddly_breakable_by_hand=2, fabricate_mech=1, fabricate_source=1 },
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
    local power = math.min(WHEEL_MAX_POWER, WHEEL_BASE_POWER * math.max(1, cluster))
    m:set_string("infotext", ("Water Wheel (cluster %d → power %d)"):format(cluster, power))
    return power
  end
end

-- Encased Fan (consumer)
min.register_node(NS.."encased_fan", {
  description = "Fabricate Encased Fan",
  tiles = {
    "fabricate_fan_back.png",   -- top
    "fabricate_fan_back.png",   -- bottom
    "fabricate_fan_casing.png", -- right
    "fabricate_fan_casing.png", -- left
    "fabricate_fan_casing.png", -- back
    "fabricate_fan_front.png",  -- front
  },
  paramtype2   = "facedir",
  groups       = { cracky=2, fabricate_mech=1, fabricate_consumer=1 },
  on_construct = function(pos)
    track_mech(pos)
    min.get_meta(pos):set_string("infotext","Encased Fan (no power)")
  end,
  on_destruct  = untrack_mech,
})

on_power_for[NS.."encased_fan"] = function(pos, node, power, dt)
  local meta = min.get_meta(pos)
  if power < 2 then meta:set_string("infotext","Encased Fan (no power)"); return end
  meta:set_string("infotext","Encased Fan (power "..power..")")

  local dir   = facedir_to_dir(node.param2 or 0)
  local range = math.min(4 + math.floor(power/2), 12)
  local c = {
    x = pos.x + dir.x * (range*0.5 + 0.5),
    y = pos.y + dir.y * (range*0.5),
    z = pos.z + dir.z * (range*0.5 + 0.5),
  }
  for _, obj in ipairs(min.get_objects_inside_radius(c, range + 1)) do
    if obj:is_player() or obj:get_luaentity() then
      local v = obj:get_velocity() or {x=0,y=0,z=0}
      local boost = (power/8)*4
      obj:set_velocity({ x=v.x+dir.x*boost, y=v.y+(dir.y*boost*0.2), z=v.z+dir.z*boost })
    end
  end
end

-- Mechanical Drill (consumer) + cracking overlay
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
  selection_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },
  collision_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}} },
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
    local dir = facedir_to_dir(node and node.param2 or 0)
    local tpos = {x=pos.x+dir.x,y=pos.y+dir.y,z=pos.z+dir.z}
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
  if power < 2 then
    meta:set_string("infotext","Mechanical Drill (no power)")
    meta:set_float("drill_progress", 0.0)
    local dir = facedir_to_dir(node.param2 or 0)
    remove_overlay({x=pos.x+dir.x,y=pos.y+dir.y,z=pos.z+dir.z})
    meta:set_string("drill_target", "")
    meta:set_int("drill_stage", 0)
    return
  end

  local dir  = facedir_to_dir(node.param2 or 0)
  local tpos = { x=pos.x + dir.x, y=pos.y + dir.y, z=pos.z + dir.z }
  local tnode= min.get_node_or_nil(tpos)
  if not tnode then
    meta:set_string("infotext","Mechanical Drill (idle: unloaded)")
    meta:set_float("drill_progress", 0.0)
    remove_overlay(tpos)
    meta:set_string("drill_target", "")
    meta:set_int("drill_stage", 0)
    return
  end

  local tname = tnode.name
  local def   = min.registered_nodes[tname]
  if (not def) or tname=="air" or (def.liquidtype and def.liquidtype~="none") or def.walkable==false then
    meta:set_string("infotext","Mechanical Drill (idle)")
    meta:set_float("drill_progress", 0.0)
    remove_overlay(tpos)
    meta:set_string("drill_target", "")
    meta:set_int("drill_stage", 0)
    return
  end

  if min.is_protected(tpos, "") then
    meta:set_string("infotext","Mechanical Drill (area protected)")
    remove_overlay(tpos)
    return
  end

  local key = min.pos_to_string(tpos)
  if meta:get_string("drill_target") ~= key then
    meta:set_string("drill_target", key)
    meta:set_float("drill_progress", 0.0)
    meta:set_int("drill_stage", 0)
    remove_overlay(tpos)
  end

  local hardness = node_hardness(tname)
  local prog = meta:get_float("drill_progress")
  local speed = (power / 8) * 1.2 -- 8 power ~ 1.2 hardness/sec
  prog = prog + speed * dt

  -- frame 0..(CRACK_FRAMES-1) from progress
  local frame = math.min(CRACK_FRAMES-1, math.floor((prog / hardness) * CRACK_FRAMES))
  local last  = meta:get_int("drill_stage")
  if frame ~= last then
    ensure_overlay(tpos, dir, frame)
    meta:set_int("drill_stage", frame)
  end

  if prog >= hardness then
    local drops = min.get_node_drops(tname) or {}
    min.remove_node(tpos)
    for _, item in ipairs(drops) do min.add_item(tpos, item) end
    remove_overlay(tpos)
    prog = 0.0
    meta:set_string("drill_target","")
    meta:set_int("drill_stage", 0)
  end

  meta:set_float("drill_progress", prog)
  meta:set_string("infotext", ("Mechanical Drill (power %d, %.0f%%)"):format(power, (prog / hardness) * 100))
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
min.register_craft({ output = NS.."mechanical_drill", recipe = {
  {"default:steel_ingot", NS.."shaft",       "default:steel_ingot"},
  {"default:steel_ingot", "default:diamond", "default:steel_ingot"},
  {"default:steel_ingot", NS.."gearbox",     "default:steel_ingot"},
}})

-- ======================================================================
-- Create-like 2-Pulley Conveyor Belts
-- ======================================================================

-- -------- Tunables -----------------------------------------------------
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

-- -------- Runtime registry ---------------------------------------------
fabricate.belts = fabricate.belts or {}   -- line_id -> {segments={pos...}, axis="x"/"z", dir=±1, slope=0/±1, speed=0}
local BELT_COUNTER = 0
local function new_line_id()
  BELT_COUNTER = BELT_COUNTER + 1
  return "belt_"..min.get_gametime().."_"..BELT_COUNTER
end

-- -------- Nodes: pulleys & segments ------------------------------------

-- Segment nodeboxes (flat and slope “step”)
local BELT_FLAT_BOX = {
  type="fixed",
  fixed={
    {-0.5, -0.5, -0.5,  0.5, -0.375, 0.5},
    {-0.5, -0.375,-0.5,  0.5, -0.345, 0.5},
  }
}
local BELT_STEP_BOX = {
  type="fixed",
  fixed={
    {-0.5, -0.5, -0.5,  0.5, -0.375, 0.5}, -- base
    {-0.5, -0.375,-0.5,  0.5, -0.312, 0.5}, -- slightly higher “ramp”
  }
}

-- Pulley (drive/endpoints)
min.register_node(NS.."belt_pulley", {
  description = "Fabricate Belt Pulley",
  tiles = {
    "mcl_core_iron_block.png","mcl_core_iron_block.png",
    "mcl_core_iron_block.png","mcl_core_iron_block.png",
    "mcl_core_iron_block.png","mcl_core_iron_block.png",
  },
  paramtype2   = "facedir",
  groups       = { cracky=2, fabricate_mech=1, fabricate_consumer=1 },
  on_construct = function(pos)
    track_mech(pos)
    min.get_meta(pos):set_string("infotext","Pulley (no belt)")
  end,
  on_destruct  = function(pos)
    -- If this pulley anchors a belt, tear the belt down.
    local m   = min.get_meta(pos)
    local lid = m:get_string("belt_line_id")
    if lid ~= "" then
      local line = fabricate.belts[lid]
      if line then
        for _,sp in ipairs(line.segments) do
          local n = min.get_node_or_nil(sp)
          if n and (n.name == NS.."belt_segment" or n.name == NS.."belt_segment_slope") then
            min.remove_node(sp)
          end
        end
        fabricate.belts[lid] = nil
      end
    end
    untrack_mech(pos)
  end,
})

-- Flat segment
min.register_node(NS.."belt_segment", {
  description = "Fabricate Belt Segment (Flat)",
  drawtype    = "nodebox",
  node_box    = BELT_FLAT_BOX,
  selection_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,-0.345,0.5}} },
  collision_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,-0.375,0.5}} },
  tiles       = {
    "mcl_core_iron_block.png^[colorize:#3a3a3a:180",
    "mcl_core_iron_block.png^[colorize:#1e1e1e:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
    "mcl_core_iron_block.png^[colorize:#2c2c2c:200",
  },
  paramtype   = "light",
  paramtype2  = "facedir", -- axis/orientation
  groups      = { cracky=2, not_in_creative_inventory=1 },
  drop        = "", -- segments are virtual; breaking pulleys returns belts
})

-- Slope “step” segment
min.register_node(NS.."belt_segment_slope", {
  description = "Fabricate Belt Segment (Slope)",
  drawtype    = "nodebox",
  node_box    = BELT_STEP_BOX,
  selection_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,-0.312,0.5}} },
  collision_box = { type="fixed", fixed = {{-0.5,-0.5,-0.5, 0.5,-0.375,0.5}} },
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

-- Belts get power via pulleys: show speed in infotext. Movement happens in belt step.
on_power_for[NS.."belt_pulley"] = function(pos, node, power, dt)
  local m   = min.get_meta(pos)
  local lid = m:get_string("belt_line_id")
  local speed = belt_speed_for_power(power)
  if lid ~= "" then
    local line = fabricate.belts[lid]
    if line then line.speed = math.max(line.speed, speed) end -- either end can drive; take max
    m:set_string("infotext", ("Pulley (belt %s) speed %.2f m/s"):format(lid, speed))
  else
    m:set_string("infotext", (speed>0) and ("Pulley (no belt) speed %.2f m/s"):format(speed) or "Pulley (no belt)")
  end
end

-- -------- Belt building tool (spool) -----------------------------------
min.register_craftitem(NS.."belt_spool", {
  description = "Fabricate Belt Spool",
  inventory_image = "mcl_core_iron_block.png^[colorize:#3a3a3a:150",
  on_use = function(stack, user, pointed)
    if not user or not pointed or pointed.type ~= "node" then return stack end
    local pos = pointed.under
    local n   = min.get_node_or_nil(pos)
    if not n or n.name ~= NS.."belt_pulley" then
      min.chat_send_player(user:get_player_name(), "Click a belt pulley.")
      return stack
    end
    local meta = user:get_meta()
    local stored = meta:get_string("fab_spool_first")
    if stored == "" then
      meta:set_string("fab_spool_first", min.pos_to_string(pos))
      min.chat_send_player(user:get_player_name(), "First pulley set. Click the second pulley.")
      return stack
    end
    local p1 = min.string_to_pos(stored)
    meta:set_string("fab_spool_first","")
    if not p1 then return stack end
    -- Build between p1 and pos
    local ok, err = (function(a,b)
      -- Same axis X or Z only (like Create). Y may differ.
      if a.x ~= b.x and a.z ~= b.z then
        return false, "Pulleys must align on X or Z."
      end
      -- Determine axis/dir
      local axis, dir, len
      if a.x == b.x then axis="z"; dir = (b.z > a.z) and 1 or -1; len = math.abs(b.z - a.z)
      else               axis="x"; dir = (b.x > a.x) and 1 or -1; len = math.abs(b.x - a.x) end
      local dy = b.y - a.y
      -- Refuse zero-length
      if len == 0 and dy == 0 then return false, "Pulleys overlap." end

      -- Reserve a line id and write to both pulleys
      local lid = new_line_id()
      fabricate.belts[lid] = {segments={}, axis=axis, dir=dir, slope=(dy==0) and 0 or ((dy>0) and 1 or -1), speed=0}

      min.get_meta(a):set_string("belt_line_id", lid)
      min.get_meta(b):set_string("belt_line_id", lid)

      -- Lay segments from a → b. We stair-step Y until we match dy, then run flat.
      local sx = a.x; local sy = a.y; local sz = a.z
      local ex = b.x; local ey = b.y; local ez = b.z

      local step_axis = (axis=="x") and "x" or "z"
      local total_steps = (axis=="x") and math.abs(ex - sx) or math.abs(ez - sz)
      local remaining_y = dy

      local place_seg = function(p, nodename, param2)
        -- refuse to overwrite non-air
        local nn = min.get_node_or_nil(p)
        if nn and nn.name ~= "air" and nn.name ~= NS.."belt_segment" and nn.name ~= NS.."belt_segment_slope" then
          return false, "Path blocked at "..min.pos_to_string(p)
        end
        min.set_node(p, {name=nodename, param2=param2})
        table.insert(fabricate.belts[lid].segments, vector.new(p))
        return true
      end

      local facedir = (axis=="x") and ((dir==1) and 1 or 3) or ((dir==1) and 0 or 2) -- shaft-like

      local cx,cy,cz = sx, sy, sz
      local ax_step = (dir==1) and 1 or -1
      for i=1,total_steps do
        -- slope first if we still need vertical travel
        if remaining_y ~= 0 then
          local slope_dir = (remaining_y>0) and 1 or -1
          cy = cy + slope_dir
          local okp, errp = place_seg({x=cx,y=cy,z=cz}, NS.."belt_segment_slope", facedir)
          if not okp then fabricate.belts[lid]=nil; return false, errp end
          remaining_y = remaining_y - slope_dir
        else
          local okp, errp = place_seg({x=cx,y=cy,z=cz}, NS.."belt_segment", facedir)
          if not okp then fabricate.belts[lid]=nil; return false, errp end
        end
        if step_axis=="x" then cx = cx + ax_step else cz = cz + ax_step end
      end

      -- if we still have Y left after horizontal (shouldn’t happen), climb it
      while remaining_y ~= 0 do
        local slope_dir = (remaining_y>0) and 1 or -1
        cy = cy + slope_dir
        local okp, errp = place_seg({x=cx,y=cy,z=cz}, NS.."belt_segment_slope", facedir)
        if not okp then fabricate.belts[lid]=nil; return false, errp end
        remaining_y = remaining_y - slope_dir
      end

      min.chat_send_player(user:get_player_name(), "Belt built: "..lid)
      return true
    end)(p1, pos)

    if not ok then
      min.chat_send_player(user:get_player_name(), "Belt failed: "..(err or "?"))
    end
    return stack
  end
})

-- Allow removing belts by punching a segment (drops the spool back)
min.register_on_punchnode(function(pos, node, puncher, pointed_thing)
  if node.name ~= NS.."belt_segment" and node.name ~= NS.."belt_segment_slope" then return end
  -- Find line id by scanning pulleys around the run (cheap: look 8 blocks around)
  local removed = false
  local around = min.find_nodes_in_area(
    {x=pos.x-8,y=pos.y-8,z=pos.z-8},
    {x=pos.x+8,y=pos.y+8,z=pos.z+8},
    {NS.."belt_pulley"}
  )
  for _,pp in ipairs(around or {}) do
    local lid = min.get_meta(pp):get_string("belt_line_id")
    if lid ~= "" then
      local line = fabricate.belts[lid]
      if line then
        for _,sp in ipairs(line.segments) do
          local n = min.get_node_or_nil(sp)
          if n and (n.name == NS.."belt_segment" or n.name == NS.."belt_segment_slope") then
            min.remove_node(sp)
          end
        end
        fabricate.belts[lid]=nil
        -- clear pulleys that referenced it
        for _,pp2 in ipairs(around) do
          if min.get_meta(pp2):get_string("belt_line_id")==lid then
            min.get_meta(pp2):set_string("belt_line_id","")
            min.get_meta(pp2):set_string("infotext","Pulley (no belt)")
          end
        end
        removed = true
        break
      end
    end
  end
  if removed and puncher then
    min.chat_send_player(puncher:get_player_name(), "Belt removed.")
  end
end)

-- -------- Movement step (items & actors) --------------------------------
local belt_step_accum = 0
min.register_globalstep(function(dtime)
  belt_step_accum = belt_step_accum + dtime
  if belt_step_accum < 0.1 then return end
  local dt = belt_step_accum
  belt_step_accum = 0

  -- Reset all lines’ computed speed for this tick
  for _,line in pairs(fabricate.belts) do line.speed = 0 end

  -- Read speed from power at any segment’s tile (via either pulley hook already ran),
  -- plus directly from grid at segments (in case solver put power on them later)
  for lid, line in pairs(fabricate.belts) do
    -- If pulleys updated speed via on_power_for, keep it; otherwise compute from local grid
    if (line.speed or 0) <= 0 then
      local best = 0
      for _,p in ipairs(line.segments) do
        local e = fabricate.power_grid[pos_to_key(p)]
        if e and e.power and e.power > best then best = e.power end
      end
      line.speed = belt_speed_for_power(best)
    end
  end

  -- Move things on each segment
  for lid, line in pairs(fabricate.belts) do
    local spd = line.speed or 0
    if spd <= 0 then goto nextline end

    -- forward vector from axis/dir
    local dir = (line.axis=="x") and {x=line.dir,y=0,z=0} or {x=0,y=0,z=line.dir}
    -- perpendicular for centering
    local perp = (line.axis=="x") and {x=0,y=0,z=1} or {x=1,y=0,z=0}
    local ybias = (line.slope==0) and 0 or (line.slope * 0.5) -- gentle lift on slopes

    for _, segpos in ipairs(line.segments) do
      local scan_center = {x = segpos.x + 0.5, y = segpos.y + BELT_PICKUP_Y, z = segpos.z + 0.5}
      for _, obj in ipairs(min.get_objects_inside_radius(scan_center, 0.8)) do
        local ent = obj:get_luaentity()
        if ent and ent.name and ent.name:find("^"..NS) then goto nextobj end

        local p = obj:get_pos(); if not p then goto nextobj end
        if math.abs(p.y - (segpos.y + 0.525)) < 0.35 then
          local v = obj:get_velocity() or {x=0,y=0,z=0}

          -- Forward push
          v.x = v.x + dir.x * spd * dt * 8
          v.z = v.z + dir.z * spd * dt * 8

          -- Up/down bias on slopes to keep things seated
          v.y = (obj:is_player() and v.y) or math.min(v.y + ybias * dt, 1.0)

          -- Centering
          local off = { x = (p.x - (segpos.x + 0.5)), z = (p.z - (segpos.z + 0.5)) }
          local lateral = off.x * perp.x + off.z * perp.z
          v.x = v.x - perp.x * lateral * BELT_CENTER_PULL * dt
          v.z = v.z - perp.z * lateral * BELT_CENTER_PULL * dt

          -- Friction
          v.x = v.x * (1 - BELT_FRICTION * dt)
          v.z = v.z * (1 - BELT_FRICTION * dt)

          obj:set_velocity(v)

          -- Keep items from sinking
          if not obj:is_player() and p.y < segpos.y + 0.45 then
            obj:set_pos({x=p.x, y=segpos.y + 0.46, z=p.z})
          end
        end
        ::nextobj::
      end
    end

    ::nextline::
  end
end)

-- -------- Crafting ------------------------------------------------------
min.register_craft({
  output = NS.."belt_pulley 2",
  recipe = {
    {"default:steel_ingot", NS.."shaft",          "default:steel_ingot"},
    {"default:steel_ingot","default:copper_ingot","default:steel_ingot"},
    {"default:steel_ingot", NS.."shaft",          "default:steel_ingot"},
  }
})
min.register_craft({ output = NS.."belt_spool",
  recipe = { {"group:wool","group:wool","group:wool"},
             {"","default:steel_ingot",""},
             {"group:wool","group:wool","group:wool"} }
})

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
