-- fabricate/init.lua
-- Fabricate: tiny Create-like kinetic system for Luanti / Minetest.
-- Not affiliated with Minecraft's Create mod.

local min = rawget(_G, "core") or minetest
local vector = vector
local math = math

local modname = min.get_current_modname() or "fabricate"
local NS = modname .. ":"

local S = (min.get_translator and min.get_translator(modname)) or function(s) return s end

fabricate = rawget(_G, "fabricate") or {}
_G.fabricate = fabricate

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function pos_to_key(p)
	return ("%d,%d,%d"):format(p.x, p.y, p.z)
end

local dirs = {
	{x= 1,y= 0,z= 0},
	{x=-1,y= 0,z= 0},
	{x= 0,y= 1,z= 0},
	{x= 0,y=-1,z= 0},
	{x= 0,y= 0,z= 1},
	{x= 0,y= 0,z=-1},
}

local function facedir_to_dir(param2)
	local rot = param2 % 4
	if rot == 0 then
		return {x=0,y=0,z=1}
	elseif rot == 1 then
		return {x=1,y=0,z=0}
	elseif rot == 2 then
		return {x=0,y=0,z=-1}
	else
		return {x=-1,y=0,z=0}
	end
end

-- 3x3x3 water detection around wheel node (good enough for now)
local function has_water_near_wheel(pos)
	for dx = -1, 1 do
	for dy = -1, 1 do
	for dz = -1, 1 do
		local np = {x = pos.x + dx, y = pos.y + dy, z = pos.z + dz}
		local n  = min.get_node_or_nil(np)
		if n then
			local def = min.registered_nodes[n.name]
			if def and def.liquidtype and def.liquidtype ~= "none" then
				return true
			end
		end
	end end end
	return false
end

-----------------------------------------------------------------------
-- Group-based mechanical graph (simple & reliable)
-----------------------------------------------------------------------

-- We don't rely on a bunch of separate tables.
-- Instead we use node groups:
--   fabricate_mech    = 1  (part of the mechanical network)
--   fabricate_source  = 1  (emits power via get_power)
--   fabricate_consumer= 1  (handles on_power)

fabricate.power_grid = fabricate.power_grid or {}
fabricate.tracked_mech = fabricate.tracked_mech or {}

local tracked_mech = fabricate.tracked_mech

local function is_mech(name)
	local def = min.registered_nodes[name]
	return def and def.groups and def.groups.fabricate_mech == 1
end

local function is_source(name)
	local def = min.registered_nodes[name]
	return def and def.groups and def.groups.fabricate_source == 1
end

local function is_consumer(name)
	local def = min.registered_nodes[name]
	return def and def.groups and def.groups.fabricate_consumer == 1
end

local function track_mech(pos)
	tracked_mech[pos_to_key(pos)] = vector.new(pos)
end

local function untrack_mech(pos)
	tracked_mech[pos_to_key(pos)] = nil
end

-- Per-node behavior tables (by name)
local get_power_for  = {}  -- name -> function(pos, node, dt, now) -> power
local on_power_for   = {}  -- name -> function(pos, node, power, dt)

-----------------------------------------------------------------------
-- BFS from all powered sources through connected mechanical nodes
-----------------------------------------------------------------------

local function add_power(accum, key, pos, p)
	local ex = accum[key]
	if not ex or ex.power < p then
		accum[key] = {pos = vector.new(pos), power = p}
	end
end

local function bfs(accum, start_pos, base_power)
	if base_power <= 0 then return end

	local queue = {}
	local seen  = {}

	local skey = pos_to_key(start_pos)
	queue[1] = {pos = vector.new(start_pos), power = base_power}
	seen[skey] = base_power

	while #queue > 0 do
		local cur = table.remove(queue, 1)
		local pos = cur.pos
		local pwr = cur.power
		local key = pos_to_key(pos)

		add_power(accum, key, pos, pwr)

		if pwr <= 1 then goto continue end

		for _, d in ipairs(dirs) do
			local np = {x = pos.x + d.x, y = pos.y + d.y, z = pos.z + d.z}
			local n  = min.get_node_or_nil(np)
			if n and is_mech(n.name) then
				local nkey = pos_to_key(np)
				local npwr = pwr - 1
				if not seen[nkey] or seen[nkey] < npwr then
					seen[nkey] = npwr
					queue[#queue+1] = {pos = np, power = npwr}
				end
			end
		end

		::continue::
	end
end

-----------------------------------------------------------------------
-- Globalstep: evaluate graph
-----------------------------------------------------------------------

local step_accum = 0

min.register_globalstep(function(dtime)
	step_accum = step_accum + dtime
	if step_accum < 0.2 then return end
	local dt = step_accum
	step_accum = 0

	local now = min.get_gametime()
	local accum = {}

	-- 1) Find powered sources
	for _, pos in pairs(tracked_mech) do
		local node = min.get_node_or_nil(pos)
		if node and is_source(node.name) then
			local fn = get_power_for[node.name]
			local p = fn and (fn(pos, node, dt, now) or 0) or 0
			if p > 0 then
				bfs(accum, pos, p)
			end
		end
	end

	-- Save
	fabricate.power_grid = accum

	-- 2) Clear mechanical infotext (we'll overwrite)
	for _, pos in pairs(tracked_mech) do
		min.get_meta(pos):set_string("infotext", "")
	end

	-- 3) Drive consumers + label mech with power
	for _, data in pairs(accum) do
		local pos   = data.pos
		local power = data.power
		local node  = min.get_node_or_nil(pos)
		if not node then goto continue end

		local name = node.name

		if is_consumer(name) then
			local fn = on_power_for[name]
			if fn then fn(pos, node, power, dt) end
		end

		if is_mech(name) then
			local m = min.get_meta(pos)
			local label = name
			if name == NS.."water_wheel" then
				label = "Water Wheel"
			elseif name == NS.."shaft" then
				label = "Shaft"
			elseif name == NS.."gearbox" then
				label = "Gearbox"
			elseif name == NS.."hand_crank" then
				label = "Hand Crank"
			elseif name == NS.."encased_fan" then
				label = "Encased Fan"
			end
			m:set_string("infotext", label.." (power "..power..")")
		end

		::continue::
	end

	-- 4) Any consumer with no entry in accum stays / is reset to "no power"
	for _, pos in pairs(tracked_mech) do
		local node = min.get_node_or_nil(pos)
		if node and is_consumer(node.name) then
			local key = pos_to_key(pos)
			if not accum[key] then
				local m = min.get_meta(pos)
				m:set_string("infotext", "Encased Fan (no power)")
			end
		end
	end
end)

-----------------------------------------------------------------------
-- Shaft (mechanical connector)
-----------------------------------------------------------------------

min.register_node(NS.."shaft", {
	description = S("Fabricate Shaft"),
	drawtype   = "nodebox",
	tiles      = {"fabricate_shaft.png"},
	paramtype  = "light",
	paramtype2 = "facedir",

	-- rod along Z when param2 = 0
	node_box = {
		type  = "fixed",
		fixed = { {-0.1,-0.1,-0.5, 0.1,0.1,0.5} },
	},

	groups = {
		cracky = 2,
		oddly_breakable_by_hand = 2,
		fabricate_mech = 1,
	},

	on_construct = function(pos)
		track_mech(pos)
	end,

	on_destruct = function(pos)
		untrack_mech(pos)
	end,

	-- Align shaft so when placed on side of wheel/block it points inward
	on_place = function(itemstack, placer, pointed_thing)
		if pointed_thing.type ~= "node" then
			return min.item_place(itemstack, placer, pointed_thing)
		end

		local under = pointed_thing.under
		local above = pointed_thing.above
		if not under or not above then
			return min.item_place(itemstack, placer, pointed_thing)
		end

		local dx = under.x - above.x
		local dz = under.z - above.z
		local param2

		if math.abs(dx) > math.abs(dz) then
			param2 = 1 -- shaft along X
		else
			param2 = 0 -- shaft along Z
		end

		return min.item_place_node(itemstack, placer, pointed_thing, param2)
	end,
})

-----------------------------------------------------------------------
-- Gearbox (mechanical connector)
-----------------------------------------------------------------------

min.register_node(NS.."gearbox", {
	description = S("Fabricate Gearbox"),
	tiles = {
		"fabricate_gearbox_top.png", "fabricate_gearbox_top.png",
		"fabricate_gearbox_side.png","fabricate_gearbox_side.png",
		"fabricate_gearbox_side.png","fabricate_gearbox_side.png",
	},
	paramtype2 = "facedir",
	groups = {
		cracky = 2,
		fabricate_mech = 1,
	},

	on_construct = function(pos)
		track_mech(pos)
	end,

	on_destruct = function(pos)
		untrack_mech(pos)
	end,
})

-----------------------------------------------------------------------
-- Hand Crank (source; optional helper)
-----------------------------------------------------------------------

min.register_node(NS.."hand_crank", {
	description = S("Fabricate Hand Crank"),
	drawtype   = "nodebox",
	tiles = {
		"fabricate_hand_crank_top.png",
		"fabricate_hand_crank_bottom.png",
		"fabricate_hand_crank_side.png",
		"fabricate_hand_crank_side.png",
		"fabricate_hand_crank_side.png",
		"fabricate_hand_crank_side.png",
	},
	paramtype  = "light",
	paramtype2 = "facedir",
	node_box = {
		type = "fixed",
		fixed = {
			{-0.2,-0.5,-0.2,  0.2,-0.1,0.2},
			{-0.05,-0.1,-0.05, 0.05,0.2,0.05},
			{0.05, 0.1,-0.15,  0.35,0.2,0.15},
		},
	},
	groups = {
		choppy = 2,
		oddly_breakable_by_hand = 2,
		fabricate_mech = 1,
		fabricate_source = 1,
	},

	on_construct = function(pos)
		track_mech(pos)
		min.get_meta(pos):set_string("infotext", "Hand Crank")
	end,

	on_destruct = function(pos)
		untrack_mech(pos)
		fabricate.dynamic_sources[pos_to_key(pos)] = nil
	end,

	on_rightclick = function(pos, node, clicker, itemstack, pt)
		local key = pos_to_key(pos)
		fabricate.dynamic_sources[key] = {
			pos        = vector.new(pos),
			base_power = 8,
			until_time = min.get_gametime() + 2,
		}
		min.get_meta(pos):set_string("infotext", "Hand Crank (active)")
	end,
})

get_power_for[NS.."hand_crank"] = function(pos, node, dt, now)
	local meta = fabricate.dynamic_sources[pos_to_key(pos)]
	if meta and meta.until_time and meta.until_time > now then
		return meta.base_power or 0
	end
	return 0
end

-----------------------------------------------------------------------
-- Water Wheel (source)
-----------------------------------------------------------------------

min.register_node(NS.."water_wheel", {
	description = S("Fabricate Water Wheel"),
	drawtype   = "mesh",
	mesh       = "water_wheel.obj",
	tiles      = {"mcl_core_planks_big_oak.png"},
	paramtype  = "light",
	paramtype2 = "facedir",
	visual_scale = 1.25,
	selection_box = {
		type  = "fixed",
		fixed = {{-0.625,-0.625,-0.625, 0.625,0.625,0.625}},
	},
	collision_box = {
		type  = "fixed",
		fixed = {{-0.625,-0.625,-0.625, 0.625,0.625,0.625}},
	},
	groups = {
		choppy = 2,
		oddly_breakable_by_hand = 2,
		fabricate_mech = 1,
		fabricate_source = 1,
	},

	on_construct = function(pos)
		track_mech(pos)
		min.get_meta(pos):set_string("infotext", "Water Wheel (no water)")
	end,

	on_destruct = function(pos)
		untrack_mech(pos)
	end,
})

get_power_for[NS.."water_wheel"] = function(pos, node, dt, now)
	local m = min.get_meta(pos)
	if has_water_near_wheel(pos) then
		m:set_string("infotext", "Water Wheel (power 8)")
		return 8
	else
		m:set_string("infotext", "Water Wheel (no water)")
		return 0
	end
end

-----------------------------------------------------------------------
-- Encased Fan (consumer)
-----------------------------------------------------------------------

min.register_node(NS.."encased_fan", {
	description = S("Fabricate Encased Fan"),
	tiles = {
		"fabricate_fan_back.png",
		"fabricate_fan_back.png",
		"fabricate_fan_casing.png",
		"fabricate_fan_casing.png",
		"fabricate_fan_casing.png",
		"fabricate_fan_front.png",
	},
	paramtype2 = "facedir",
	groups = {
		cracky = 2,
		fabricate_mech = 1,
		fabricate_consumer = 1,
	},

	on_construct = function(pos)
		track_mech(pos)
		min.get_meta(pos):set_string("infotext", "Encased Fan (no power)")
	end,

	on_destruct = function(pos)
		untrack_mech(pos)
	end,
})

on_power_for[NS.."encased_fan"] = function(pos, node, power, dt)
	local meta = min.get_meta(pos)
	if power < 3 then
		meta:set_string("infotext", "Encased Fan (no power)")
		return
	end

	meta:set_string("infotext", "Encased Fan (power "..power..")")

	local dir   = facedir_to_dir(node.param2 or 0)
	local range = math.min(4 + math.floor(power / 2), 12)

	local center = {
		x = pos.x + dir.x * (range * 0.5 + 0.5),
		y = pos.y + dir.y * (range * 0.5),
		z = pos.z + dir.z * (range * 0.5 + 0.5),
	}

	local objs = min.get_objects_inside_radius(center, range + 1)
	for _, obj in ipairs(objs) do
		if obj:is_player() or obj:get_luaentity() then
			local opos = obj:get_pos()
			if opos then
				local rel = {
					x = opos.x - pos.x,
					y = opos.y - pos.y,
					z = opos.z - pos.z,
				}
				local dot = rel.x * dir.x + rel.y * dir.y + rel.z * dir.z
				if dot > 0 then
					local vel   = obj:get_velocity() or {x=0,y=0,z=0}
					local boost = (power / 8) * 4
					obj:set_velocity({
						x = vel.x + dir.x * boost,
						y = vel.y + (dir.y * boost * 0.2),
						z = vel.z + dir.z * boost,
					})
				end
			end
		end
	end
end

-----------------------------------------------------------------------
-- Simple debugging: /fab_debug
-----------------------------------------------------------------------

min.register_chatcommand("fab_debug", {
	description = "List powered Fabricate nodes near you",
	func = function(name, param)
		local player = min.get_player_by_name(name)
		if not player then return false, "No player." end
		local p = vector.round(player:get_pos())
		local r = 12
		local out = {}
		for _, data in pairs(fabricate.power_grid) do
			local pos = data.pos
			if math.abs(pos.x-p.x) <= r
			and math.abs(pos.y-p.y) <= r
			and math.abs(pos.z-p.z) <= r then
				local n = min.get_node_or_nil(pos)
				local nn = n and n.name or "unknown"
				out[#out+1] = ("%s @ %d,%d,%d = %d"):format(nn, pos.x, pos.y, pos.z, data.power)
			end
		end
		if #out == 0 then
			return true, "No powered Fabricate nodes within "..r.." nodes."
		end
		table.sort(out)
		min.chat_send_player(name, "Powered Fabricate nodes:")
		for _, line in ipairs(out) do
			min.chat_send_player(name, "  "..line)
		end
		return true, ""
	end
})
