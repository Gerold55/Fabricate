-- fabricate/nodes/belts.lua
-- Mechanical Belt segments + movement

local fabricate = rawget(_G, "fabricate")
assert(fabricate, "fabricate: init.lua must load before belts")

local min    = fabricate.min
local NS     = fabricate.NS
local H      = fabricate.helpers

local pos_to_key     = H.pos_to_key
local facedir_to_dir = H.facedir_to_dir

-- Shared power grid filled by core/power.lua
local POWER_GRID = fabricate.power_grid

fabricate.belts = fabricate.belts or {}
local BELTS = fabricate.belts

-- -------------------------------------------------
-- Config / Tunables
-- -------------------------------------------------

-- Adjustable via minetest.conf: fabricate_belt_max_len (default 20)
local BELT_MAX_LEN     = tonumber(min.settings:get("fabricate_belt_max_len") or "20")
local BELT_MIN_POWER   = 2
local BELT_BASE_SPEED  = 1.6   -- m/s at min power
local BELT_SPEED_GAIN  = 0.25  -- m/s per extra power
local BELT_SPEED_MAX   = 4.5   -- slightly lowered to be less yeet-y
local BELT_CENTER_PULL = 2.0
local BELT_PICKUP_Y    = 0.55
local BELT_FRICTION    = 0.25  -- stronger friction so velocity doesn't explode

local BELT_COUNTER = 0
local function new_line_id()
  BELT_COUNTER = BELT_COUNTER + 1
  return "belt_"..min.get_gametime().."_"..BELT_COUNTER
end

local function belt_speed_for_power(p)
  if not p or p < BELT_MIN_POWER then return 0 end
  local s = BELT_BASE_SPEED + (p - BELT_MIN_POWER) * BELT_SPEED_GAIN
  return (s > BELT_SPEED_MAX) and BELT_SPEED_MAX or s
end

-- -------------------------------------------------
-- Nodes: belt segments
-- -------------------------------------------------

local BELT_FLAT_BOX = {
  type = "fixed",
  fixed = {
    {-0.5,-0.5,-0.5,  0.5,-0.375,0.5},
    {-0.5,-0.375,-0.5,0.5,-0.345,0.5},
  }
}

local BELT_SLOPE_BOX = {
  type = "fixed",
  fixed = {
    {-0.5,-0.5,-0.5,  0.5,-0.375,0.5},
    {-0.5,-0.375,-0.5,0.5,-0.312,0.5},
  }
}

min.register_node(NS.."belt_segment", {
  description = "Fabricate Belt Segment (Flat)",
  drawtype    = "nodebox",
  node_box    = BELT_FLAT_BOX,
  selection_box = {
    type = "fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,-0.345,0.5}},
  },
  collision_box = {
    type = "fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,-0.375,0.5}},
  },
  tiles = {
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
  description = "Fabricate Belt Segment (Slope)",
  drawtype    = "nodebox",
  node_box    = BELT_SLOPE_BOX,
  selection_box = {
    type = "fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,-0.312,0.5}},
  },
  collision_box = {
    type = "fixed",
    fixed = {{-0.5,-0.5,-0.5, 0.5,-0.375,0.5}},
  },
  tiles = {
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

-- -------------------------------------------------
-- Geometry helpers for belt layout
-- -------------------------------------------------

-- Compute direction + step count and classify:
--  "horizontal" | "vertical" | "diagonal"
local function compute_dir_and_steps(a, b)
  local dx = b.x - a.x
  local dy = b.y - a.y
  local dz = b.z - a.z

  if dx == 0 and dz == 0 then
    if dy == 0 then
      return nil, nil, "Anchors overlap."
    end
    local dir = {x=0, y=(dy>0) and 1 or -1, z=0}
    return dir, math.abs(dy), "vertical"
  end

  if dy == 0 then
    -- strictly horizontal on X or Z
    if dx ~= 0 and dz == 0 then
      local dir = {x=(dx>0) and 1 or -1, y=0, z=0}
      return dir, math.abs(dx), "horizontal"
    elseif dz ~= 0 and dx == 0 then
      local dir = {x=0, y=0, z=(dz>0) and 1 or -1}
      return dir, math.abs(dz), "horizontal"
    else
      return nil, nil, "Belt must be in a straight line (no corners)."
    end
  end

  -- Diagonal 45°: exactly one of dx/dz non-zero, and |dy| == |horizontal|
  if dx ~= 0 and dz ~= 0 then
    return nil, nil, "Diagonal belts can only turn toward Y in a single axis."
  end

  local horiz = (dx ~= 0) and dx or dz
  if math.abs(dy) ~= math.abs(horiz) then
    return nil, nil, "Diagonal belts must be 45° (|dy| == |horizontal|)."
  end

  if dx ~= 0 then
    return {
      x = (dx>0) and 1 or -1,
      y = (dy>0) and 1 or -1,
      z = 0,
    }, math.abs(dx), "diagonal"
  else
    return {
      x = 0,
      y = (dy>0) and 1 or -1,
      z = (dz>0) and 1 or -1,
    }, math.abs(dz), "diagonal"
  end
end

-- Expose for linker so it can read max length
fabricate.belt_max_len = BELT_MAX_LEN

-- -------------------------------------------------
-- Build a belt line (called from items/belt_linker.lua)
--  - a_pos / b_pos are shaft positions (anchors)
--  - we place nodes only between shafts
--  - BUT: segments list includes anchors too so belt "covers" shafts
-- -------------------------------------------------
function fabricate.build_belt_run(user, a_pos, b_pos)
  local dir, steps, kind, err = compute_dir_and_steps(a_pos, b_pos)
  if not dir then
    return nil, err
  end

  if steps > BELT_MAX_LEN then
    return nil, ("Belt is too long (max %d segments)."):format(BELT_MAX_LEN)
  end

  -- 1) Plan path *between* anchors
  local path_positions = {}
  local cx, cy, cz = a_pos.x, a_pos.y, a_pos.z

  local function add_step()
    cx = cx + dir.x
    cy = cy + dir.y
    cz = cz + dir.z
    path_positions[#path_positions+1] = {x=cx, y=cy, z=cz}
  end

  -- steps is distance anchor→anchor in blocks;
  -- inner path is all blocks strictly between them (so steps-1).
  for _ = 1, steps-1 do
    add_step()
  end

  -- 2) Validate path: do not overwrite solid nodes
  for _, p in ipairs(path_positions) do
    local n = min.get_node_or_nil(p)
    if n and n.name ~= "air"
        and n.name ~= NS.."belt_segment"
        and n.name ~= NS.."belt_segment_slope" then
      return nil, "Path blocked at "..min.pos_to_string(p)
    end
  end

  -- 3) Decide facedir for belt strip based on horizontal component
  local facedir
  if math.abs(dir.x) > math.abs(dir.z) then
    -- along X
    facedir = (dir.x == 1) and 1 or 3
  elseif math.abs(dir.z) > 0 then
    -- along Z
    facedir = (dir.z == 1) and 0 or 2
  else
    -- pure vertical, just default to 0
    facedir = 0
  end

  -- 4) Place belt segment nodes only on path (between shafts)
  for _, p in ipairs(path_positions) do
    local name =
      (kind == "horizontal" or kind == "vertical")
        and NS.."belt_segment"
        or NS.."belt_segment_slope"
    min.set_node(p, {name = name, param2 = facedir})
  end

  -- 5) Build segments list for movement:
  --    we want the belt to *encompass* the shafts, so we treat
  --    the anchors themselves as "virtual segments".
  local segments = {}
  segments[#segments+1] = vector.new(a_pos)
  for _, p in ipairs(path_positions) do
    segments[#segments+1] = vector.new(p)
  end
  segments[#segments+1] = vector.new(b_pos)

  local lid = new_line_id()
  BELTS[lid] = {
    id       = lid,
    dir      = dir,       -- 3D direction, components -1..1
    kind     = kind,      -- "horizontal" | "vertical" | "diagonal"
    steps    = steps,
    segments = segments,  -- includes both anchors and belt nodes
    anchors  = {
      a = vector.new(a_pos),
      b = vector.new(b_pos),
    },
    speed    = 0,
  }

  if user and user:is_player() then
    min.chat_send_player(user:get_player_name(), "Mechanical Belt created.")
  end

  return lid
end

-- -------------------------------------------------
-- Removal: punch any segment to remove whole belt
-- -------------------------------------------------
min.register_on_punchnode(function(pos, node, puncher, pt)
  if node.name ~= NS.."belt_segment"
  and node.name ~= NS.."belt_segment_slope" then
    return
  end

  for id, line in pairs(BELTS) do
    for _, sp in ipairs(line.segments or {}) do
      if sp.x == pos.x and sp.y == pos.y and sp.z == pos.z then
        -- remove all belt *nodes* in world (we only placed along path)
        for _, p in ipairs(line.segments or {}) do
          local n2 = min.get_node_or_nil(p)
          if n2 and (n2.name == NS.."belt_segment"
                  or n2.name == NS.."belt_segment_slope") then
            min.remove_node(p)
          end
        end
        BELTS[id] = nil
        if puncher and puncher:is_player() then
          min.chat_send_player(puncher:get_player_name(), "Mechanical Belt removed.")
        end
        return
      end
    end
  end
end)

-- -------------------------------------------------
-- Movement globalstep
--  - Items & entities ride belts
--  - Vertical belts: no movement (Create rule)
--  - Diagonal belts: move items up/down along slope
--  - Much gentler accel + clamped velocity (no 10-block flings)
-- -------------------------------------------------

local belt_step_accum = 0

min.register_globalstep(function(dtime)
  belt_step_accum = belt_step_accum + dtime
  if belt_step_accum < 0.1 then return end
  local dt = belt_step_accum
  belt_step_accum = 0

  -- Reset speeds
  for _, line in pairs(BELTS) do
    line.speed = 0
  end

  -- Determine speed from anchor shaft powers
  for _, line in pairs(BELTS) do
    local best = 0
    if line.anchors then
      for _, pos in pairs(line.anchors) do
        local e = POWER_GRID[pos_to_key(pos)]
        if e and e.power and e.power > best then
          best = e.power
        end
      end
    end
    line.speed = belt_speed_for_power(best)
  end

  -- Move riders
  for _, line in pairs(BELTS) do
    local spd = line.speed or 0
    if spd <= 0 then goto next_line end

    local dir  = line.dir or {x=0,y=0,z=0}
    local kind = line.kind or "horizontal"

    -- Pure vertical belts: items cannot be moved (Create rule)
    if dir.x == 0 and dir.z == 0 then
      goto next_line
    end

    -- gentle accel factor
    local accel = spd * 2.0
    local max_speed = spd * 1.5  -- clamp vel to ~1.5× belt speed (horizontal plane)

    for _, segpos in ipairs(line.segments or {}) do
      local scan_center = {
        x = segpos.x + 0.5,
        y = segpos.y + BELT_PICKUP_Y,
        z = segpos.z + 0.5,
      }

      local objs = min.get_objects_inside_radius(scan_center, 0.8)
      for _, obj in ipairs(objs) do
        local ent = obj:get_luaentity()
        -- ignore our crack overlay / helpers
        if ent and ent.name and ent.name:find("^"..NS) then
          goto next_obj
        end

        local p = obj:get_pos()
        if not p then goto next_obj end

        -- Is this object roughly at belt height near this segment?
        if math.abs(p.y - (segpos.y + BELT_PICKUP_Y)) < 0.45 then
          local v = obj:get_velocity() or {x=0,y=0,z=0}

          -- Push along horizontal components always
          v.x = v.x + dir.x * accel * dt
          v.z = v.z + dir.z * accel * dt

          -- Only diagonal belts get vertical motion (slope)
          if kind == "diagonal" then
            v.y = v.y + dir.y * accel * dt
          end

          -- Center toward belt middle (horizontal only)
          local offx = (p.x - (segpos.x + 0.5))
          local offz = (p.z - (segpos.z + 0.5))
          v.x = v.x - offx * BELT_CENTER_PULL * dt
          v.z = v.z - offz * BELT_CENTER_PULL * dt

          -- Clamp horizontal speed so it doesn't explode
          local hv2 = v.x * v.x + v.z * v.z
          local maxv2 = max_speed * max_speed
          if hv2 > maxv2 and hv2 > 0 then
            local scale = max_speed / math.sqrt(hv2)
            v.x = v.x * scale
            v.z = v.z * scale
          end

          -- Mild friction
          v.x = v.x * (1 - BELT_FRICTION * dt)
          v.z = v.z * (1 - BELT_FRICTION * dt)

          obj:set_velocity(v)

          -- Keep non-players from sinking into the belt
          if not obj:is_player()
              and p.y < segpos.y + 0.45 then
            obj:set_pos({x=p.x, y=segpos.y + 0.46, z=p.z})
          end
        end

        ::next_obj::
      end
    end

    ::next_line::
  end
end)
