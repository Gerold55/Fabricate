-- nodes/components.lua
local min     = fabricate.min
local vector  = vector
local NS      = fabricate.NS
local helpers = fabricate.helpers

local track_mech   = helpers.track_mech
local untrack_mech = helpers.untrack_mech

---------------------------------------------------
-- Shaft
---------------------------------------------------
-- Shaft (slimmer stub so belts encompass it better)
min.register_node(NS.."shaft", {
  description = "Fabricate Shaft",
  drawtype    = "nodebox",
  tiles       = {"fabricate_shaft.png"},
  paramtype   = "light",
  paramtype2  = "facedir",
  node_box    = {
    type = "fixed",
    -- thinner and slightly shorter rod along Z
    fixed = { {-0.08,-0.08,-0.45, 0.08,0.08,0.45} },
  },
  selection_box = {
    type  = "fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,0.5,0.5}},
  },
  collision_box = {
    type  = "fixed",
    fixed = {{-0.08,-0.08,-0.45, 0.08,0.08,0.45}},
  },
  groups      = { cracky=2, oddly_breakable_by_hand=2, fabricate_mech=1 },
  on_construct= fabricate.helpers.track_mech,
  on_destruct = fabricate.helpers.untrack_mech,

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

---------------------------------------------------
-- Gearbox
---------------------------------------------------
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

---------------------------------------------------
-- Gantry Shaft
---------------------------------------------------
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

---------------------------------------------------
-- Hand Crank
---------------------------------------------------
local pos_to_key = helpers.pos_to_key

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

---------------------------------------------------
-- Water Wheel (node definition only; power is in core/power.lua)
---------------------------------------------------
do
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
end
