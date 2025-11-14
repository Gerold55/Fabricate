-- items/wrench.lua
local min     = fabricate.min
local NS      = fabricate.NS
local helpers = fabricate.helpers

local is_mech        = helpers.is_mech

local function wrench_rotate_node(pos, node)
  local def = min.registered_nodes[node.name]
  if not def or def.paramtype2 ~= "facedir" then return end
  local p2 = node.param2 or 0
  p2 = (p2 + 1) % 4
  node.param2 = p2
  min.swap_node(pos, node)
end

min.register_craftitem(NS.."wrench", {
  description     = "Fabricate Wrench",
  inventory_image = "fabricate_wrench.png",
  stack_max       = 1,
})

min.register_craft({
  output = NS.."wrench",
  recipe = {
    {"default:steel_ingot", "default:steel_ingot", ""},
    {"",                     "default:stick",       ""},
    {"",                     "default:stick",       ""},
  }
})

min.register_on_punchnode(function(pos, node, puncher, pointed_thing)
  if not puncher or not puncher:is_player() then return end
  local stack = puncher:get_wielded_item()
  if stack:get_name() ~= NS.."wrench" then return end
  if not is_mech(node.name) then return end
  wrench_rotate_node(pos, node)
end)
