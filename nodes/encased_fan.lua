-- nodes/encased_fan.lua
local min     = fabricate.min
local NS      = fabricate.NS
local helpers = fabricate.helpers

local facedir_to_dir = helpers.facedir_to_dir
local track_mech     = helpers.track_mech
local untrack_mech   = helpers.untrack_mech
local has_stress     = helpers.has_stress
local stress_label   = helpers.stress_label

local on_power_for   = fabricate.on_power_for

-- Fan node
min.register_node(NS.."encased_fan", {
  description = "Fabricate Encased Fan",
  tiles = {
    "fabricate_fan_back.png",
    "fabricate_fan_back.png",
    "fabricate_fan_casing.png",
    "fabricate_fan_casing.png",
    "fabricate_fan_casing.png",
    "fabricate_fan_front.png",
  },
  paramtype2   = "facedir",
  groups       = { cracky=2, fabricate_mech=1, fabricate_consumer=1 },

  on_construct = function(pos)
    track_mech(pos)
    local meta = min.get_meta(pos)
    meta:set_string("mode", "push")
    meta:set_string("infotext", "Encased Fan (push, no power)")
  end,

  on_destruct  = untrack_mech,

  on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
    if not clicker or not clicker:is_player() then return itemstack end
    local wield = clicker:get_wielded_item()
    if wield:get_name() ~= NS.."wrench" then
      return itemstack
    end
    local meta = min.get_meta(pos)
    local mode = meta:get_string("mode")
    mode = (mode == "pull") and "push" or "pull"
    meta:set_string("mode", mode)
    meta:set_string("infotext", ("Encased Fan (%s)"):format(mode))
    return itemstack
  end,
})

-- helpers
local function fan_get_medium(pos, dir)
  local front = {x=pos.x+dir.x, y=pos.y+dir.y, z=pos.z+dir.z}
  local node = min.get_node_or_nil(front)
  if not node then return "air", front end
  local def = min.registered_nodes[node.name]
  if not def then return "air", front end

  if def.liquidtype and def.liquidtype ~= "none" then
    local g = def.groups or {}
    if (g.lava and g.lava>0) or node.name:find("lava") then
      return "lava", front
    else
      return "water", front
    end
  end
  if node.name:find("lava") then return "lava", front end
  if node.name:find("water") then return "water", front end
  return "air", front
end

local function fan_particle_texture(medium)
  if medium == "water" then return "default_water.png" end
  if medium == "lava"  then return "default_lava.png"  end
  return "fabricate_fan_air.png"
end

-- Power handler
on_power_for[NS.."encased_fan"] = function(pos, node, power, dt)
  local meta = min.get_meta(pos)
  local mode = meta:get_string("mode")
  if mode ~= "pull" then mode = "push" end

  local ok, _need = has_stress(NS.."encased_fan", power)
  local stress_str = stress_label(NS.."encased_fan", power) or ("(power "..power..")")

  if not ok or power < 2 then
    meta:set_string("infotext",
      ("Encased Fan %s (no power)"):format(stress_str))
    return
  end

  local dir = facedir_to_dir(node.param2 or 0)
  local medium, front_pos = fan_get_medium(pos, dir)

  meta:set_string("infotext",
    ("Encased Fan %s, %s, power %d")
      :format(stress_str, medium, power))

  local eff_dir = {
    x = (mode == "push") and dir.x or -dir.x,
    y = (mode == "push") and dir.y or -dir.y,
    z = (mode == "push") and dir.z or -dir.z,
  }

  local range = math.min(4 + math.floor(power / 2), 12)
  local c = {
    x = pos.x + dir.x * (range * 0.5 + 0.5),
    y = pos.y + dir.y * (range * 0.5),
    z = pos.z + dir.z * (range * 0.5 + 0.5),
  }

  local ptex = fan_particle_texture(medium)
  if min.add_particlespawner and ptex then
    local base_x, base_y, base_z
    if medium == "water" or medium == "lava" then
      base_x = front_pos.x + dir.x * 0.7
      base_y = front_pos.y + dir.y * 0.7
      base_z = front_pos.z + dir.z * 0.7
    else
      base_x = pos.x + dir.x * 0.6
      base_y = pos.y + dir.y * 0.5
      base_z = pos.z + dir.z * 0.6
    end

    min.add_particlespawner({
      amount = 16,
      time   = 0.1,
      minpos = {x=base_x-0.3, y=base_y-0.2, z=base_z-0.3},
      maxpos = {x=base_x+0.3+dir.x*0.8, y=base_y+0.2, z=base_z+0.3+dir.z*0.8},
      minvel = {x=eff_dir.x*1.0, y=eff_dir.y*0.2, z=eff_dir.z*1.0},
      maxvel = {x=eff_dir.x*2.5, y=eff_dir.y*0.6, z=eff_dir.z*2.5},
      minacc = {x=0,y=0,z=0},
      maxacc = {x=0,y=0,z=0},
      minexptime = 0.2,
      maxexptime = 0.8,
      minsize = 0.7,
      maxsize = 1.8,
      texture = ptex,
      glow    = (medium == "lava") and 4 or 0,
    })
  end

  for _, obj in ipairs(min.get_objects_inside_radius(c, range + 1)) do
    local ent = obj:get_luaentity()
    local is_helper = ent and ent.name and ent.name:find("^"..NS)
    if is_helper then goto next_obj end

    local is_item = ent and ent.name == "__builtin:item"
    local p = obj:get_pos()
    if not p then goto next_obj end

    local along =
      (dir.x ~= 0 and (p.x - pos.x) * dir.x) or
      (dir.z ~= 0 and (p.z - pos.z) * dir.z) or 0

    if along >= -1 and along <= range + 2 then
      local v = obj:get_velocity() or {x=0,y=0,z=0}
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
            ent.itemstring = stack:to_string()
            if ent.set_item then ent:set_item(stack) end
          end
        end
      end
    end
    ::next_obj::
  end
end
