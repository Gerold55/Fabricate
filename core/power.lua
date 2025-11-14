-- core/power.lua
local min      = fabricate.min
local vector   = vector
local NS       = fabricate.NS
local helpers  = fabricate.helpers
local DIRS     = fabricate.DIRS

local pos_to_key   = helpers.pos_to_key
local is_mech      = helpers.is_mech
local is_source    = helpers.is_source
local can_connect  = helpers.can_connect
local track_mech   = helpers.track_mech
local has_water    = helpers.has_water_near
local wheel_cluster_size = helpers.wheel_cluster_size

local get_power_for = fabricate.get_power_for
local on_power_for  = fabricate.on_power_for

-- -------------------------------------------------
-- Hand crank power
-- -------------------------------------------------
get_power_for[NS.."hand_crank"] = function(pos, node, dt, now)
  local meta = fabricate.dynamic_sources[pos_to_key(pos)]
  if meta and meta.until_time and meta.until_time > now then
    return meta.base_power or 0
  end
  return 0
end

-- -------------------------------------------------
-- Water wheel power
-- -------------------------------------------------
local WHEEL_BASE_POWER = 8
local WHEEL_MAX_POWER  = 64

get_power_for[NS.."water_wheel"] = function(pos, node, dt, now)
  local m = min.get_meta(pos)
  if not has_water(pos) then
    m:set_string("infotext","Water Wheel (no water)")
    return 0
  end
  local cluster = wheel_cluster_size(pos, 32)
  local power = math.min(
    WHEEL_MAX_POWER,
    WHEEL_BASE_POWER * math.max(1, cluster)
  )
  m:set_string("infotext",
    ("Water Wheel (cluster %d → power %d)"):format(cluster, power))
  return power
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

  -- Sources
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

  -- Terminal backfill for encased fan & drill
  local F = NS.."encased_fan"
  local D = NS.."mechanical_drill"
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

  -- Drive consumers + label mech
  for _, data in pairs(accum) do
    local pos, power = data.pos, data.power
    local node = min.get_node_or_nil(pos); if not node then goto continue end
    local name = node.name

    if helpers.is_consumer(name) then
      local cfn = on_power_for[name]
      if cfn then cfn(pos, node, power, dt) end
    end

    if helpers.is_mech(name) then
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
    if node and helpers.is_consumer(node.name)
        and not accum[pos_to_key(pos)] then
      local label = ({
        [NS.."encased_fan"]      = "Encased Fan",
        [NS.."mechanical_drill"] = "Mechanical Drill",
      })[node.name] or "Consumer"
      min.get_meta(pos):set_string("infotext", label.." (no power)")
    end
  end
end)

-- Track existing mech on load
min.register_lbm({
  name = NS.."track_existing_mech",
  nodenames = {"group:fabricate_mech"},
  run_at_every_load = true,
  action = function(pos, node) track_mech(pos) end,
})
