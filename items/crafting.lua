-- items/crafting.lua
local min = fabricate.min
local NS  = fabricate.NS

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
