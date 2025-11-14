-- nodes/mechanical_drill.lua
local min     = fabricate.min
local NS      = fabricate.NS
local helpers = fabricate.helpers

local facedir_to_dir = helpers.facedir_to_dir
local track_mech     = helpers.track_mech
local untrack_mech   = helpers.untrack_mech
local ensure_overlay = helpers.ensure_overlay
local remove_overlay = helpers.remove_overlay
local has_stress     = helpers.has_stress
local stress_label   = helpers.stress_label

local on_power_for   = fabricate.on_power_for

local CRACK_FRAMES   = 5

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

  local ok, _need = has_stress(NS.."mechanical_drill", power)
  local stress_str = stress_label(NS.."mechanical_drill", power) or ("(power "..power..")")

  local function reset_state(tpos, label)
    meta:set_string("infotext", label)
    meta:set_float("drill_progress", 0.0)
    meta:set_string("drill_target","")
    meta:set_int("drill_stage", 0)
    if tpos then remove_overlay(tpos) end
  end

  local dir  = facedir_to_dir(node.param2 or 0)
  local tpos = { x = pos.x + dir.x,
                 y = pos.y + dir.y,
                 z = pos.z + dir.z }

  if not ok then
    reset_state(tpos, "Mechanical Drill "..stress_str)
    return
  end

  if power < 2 then
    reset_state(tpos, "Mechanical Drill "..stress_str.." (no power)")
    return
  end

  local tnode = min.get_node_or_nil(tpos)
  if not tnode then
    reset_state(tpos, "Mechanical Drill "..stress_str.." (idle: unloaded)")
    return
  end

  local tname = tnode.name
  local def   = min.registered_nodes[tname]
  if (not def) or tname=="air"
      or (def.liquidtype and def.liquidtype~="none")
      or def.walkable==false then
    reset_state(tpos, "Mechanical Drill "..stress_str.." (idle)")
    return
  end

  if min.is_protected(tpos, "") then
    meta:set_string("infotext","Mechanical Drill "..stress_str.." (area protected)")
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
  local prog     = meta:get_float("drill_progress")
  local speed    = (power / 8) * 1.2

  prog = prog + speed * dt

  local frame = math.min(
    CRACK_FRAMES-1,
    math.floor((prog / hardness) * CRACK_FRAMES)
  )
  local last  = meta:get_int("drill_stage")
  if frame ~= last then
    ensure_overlay(tpos, dir, frame)
    meta:set_int("drill_stage", frame)
  end

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
  meta:set_string(
    "infotext",
    ("Mechanical Drill %s, %.0f%%")
      :format(stress_str, (prog / hardness) * 100)
  )
end
