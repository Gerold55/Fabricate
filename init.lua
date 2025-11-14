-- fabricate/init.lua
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
-- Helpers (stay in init.lua)
-- -------------------------------------------------
local function pos_to_key(p)
  return ("%d,%d,%d"):format(p.x,p.y,p.z)
end

local DIRS = {
  {x= 1,y= 0,z= 0},{x=-1,y= 0,z= 0},
  {x= 0,y= 1,z= 0},{x= 0,y=-1,z= 0},
  {x= 0,y= 0,z= 1},{x= 0,y= 0,z=-1},
}

local HDIRS = {
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
-- Stress Units (simple model)
-- =========================================================
local STRESS_COST = {
  [NS.."encased_fan"]      = 8,
  [NS.."mechanical_drill"] = 16,
}

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
-- Crack overlay entity + helpers
-- -------------------------------------------------
local CRACK_SPRITE = "fabricate_crack_strip.png"
local CRACK_EMPTY  = "fabricate_crack_empty.png"
local CRACK_FRAMES = 5

local function crack_textures_for(dir, frame)
  local crack = CRACK_SPRITE .. "^[verticalframe:"..CRACK_FRAMES..":"..frame
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
-- Connectivity helper
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

  if aname == W then return (bname == G or bname == S or bname == F or bname == D) end
  if bname == W then return (aname == G or aname == S or aname == F or aname == D) end

  if aname == G then return (bname == W or bname == S or bname == X or bname == G or bname == F or bname == D) end
  if bname == G then return (aname == W or aname == S or aname == X or aname == G or aname == F or aname == D) end

  if aname == H then return (bname == S or bname == X or bname == G or bname == F or bname == D) end
  if bname == H then return (aname == S or aname == X or aname == G or aname == F or aname == D) end

  local A_drive = (aname == S or aname == X)
  local B_drive = (bname == S or bname == X)
  if A_drive and B_drive then return true end
  if A_drive and (bname == F or bname == D) then return true end
  if B_drive and (aname == F or aname == D) then return true end

  return false
end

-- =========================================================
-- Internal helper bundle for sub-files (nodes/*.lua)
-- =========================================================
fabricate._internal = fabricate._internal or {}
local _i = fabricate._internal

_i.min    = min
_i.vector = vector
_i.math   = math

_i.modname = modname
_i.NS      = NS

_i.DIRS    = DIRS
_i.HDIRS   = HDIRS

_i.pos_to_key        = pos_to_key
_i.facedir_to_dir    = facedir_to_dir
_i.has_water_near    = has_water_near_wheel
_i.wheel_cluster_size= wheel_cluster_size

_i.is_mech           = is_mech
_i.is_source         = is_source
_i.is_consumer       = is_consumer
_i.track_mech        = track_mech
_i.untrack_mech      = untrack_mech

_i.has_stress        = has_stress
_i.stress_label      = stress_label

_i.CRACK_FRAMES      = CRACK_FRAMES
_i.ensure_overlay    = ensure_overlay
_i.remove_overlay    = remove_overlay

_i.can_connect       = can_connect

_i.get_power_for     = fabricate.get_power_for
_i.on_power_for      = fabricate.on_power_for
_i.belts             = fabricate.belts

-- -------------------------------------------------
-- Export helpers + constants
-- -------------------------------------------------
fabricate.NS      = NS
fabricate.min     = min
fabricate.DIRS    = DIRS
fabricate.HDIRS   = HDIRS
fabricate.helpers = {
  pos_to_key        = pos_to_key,
  facedir_to_dir    = facedir_to_dir,
  has_water_near    = has_water_near_wheel,
  wheel_cluster_size= wheel_cluster_size,
  is_mech           = is_mech,
  is_source         = is_source,
  is_consumer       = is_consumer,
  track_mech        = track_mech,
  untrack_mech      = untrack_mech,
  has_stress        = has_stress,
  stress_label      = stress_label,
  ensure_overlay    = ensure_overlay,
  remove_overlay    = remove_overlay,
  can_connect       = can_connect,
}

-- Recipes shared for fan
FAN_WASH_RECIPES  = FAN_WASH_RECIPES  or {}
FAN_SMELT_RECIPES = FAN_SMELT_RECIPES or {}

-- -------------------------------------------------
-- Load the rest (everything else is in separate files)
-- -------------------------------------------------
local path = min.get_modpath(modname)

dofile(path.."/core/power.lua")
dofile(path.."/core/debug.lua")

dofile(path.."/nodes/components.lua")
dofile(path.."/nodes/encased_fan.lua")
dofile(path.."/nodes/mechanical_drill.lua")
dofile(path.."/nodes/belts.lua")
dofile(path.."/nodes/chute.lua")

dofile(path.."/items/wrench.lua")
dofile(path.."/items/belt_linker.lua")
dofile(path.."/items/crafting.lua")
