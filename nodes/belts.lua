-- nodes/belts.lua
-- Mechanical belts for Fabricate (Create-like)

local min  = fabricate.min
local NS   = fabricate.NS
local H    = fabricate.helpers

local pos_to_key     = H.pos_to_key
local facedir_to_dir = H.facedir_to_dir
local is_mech        = H.is_mech
local can_connect    = H.can_connect

-- -------------------------------------------------
-- Tunables
-- -------------------------------------------------
local BELT_MIN_POWER   = 2
local BELT_BASE_SPEED  = 1.6   -- m/s at min power
local BELT_SPEED_GAIN  = 0.25  -- m/s per extra power
local BELT_SPEED_MAX   = 6.0
local BELT_CENTER_PULL = 2.2
local BELT_PICKUP_Y    = 0.40  -- height where we scan for riders
local BELT_FRICTION    = 0.10
local BELT_MAX_LEN     = 20    -- keep this modest like Create

fabricate.belt_max_len = BELT_MAX_LEN

local function belt_speed_for_power(p)
  if not p or p < BELT_MIN_POWER then return 0 end
  local s = BELT_BASE_SPEED + (p - BELT_MIN_POWER) * BELT_SPEED_GAIN
  return (s > BELT_SPEED_MAX) and BELT_SPEED_MAX or s
end

-- line_id -> {
--   segments={pos...}, axis="x"/"z", dir=±1, slope=0/±1,
--   speed=0, anchors={a=vector,b=vector}, steps=int
-- }
local BELT_COUNTER = 0
local function new_line_id()
  BELT_COUNTER = BELT_COUNTER + 1
  return "belt_"..min.get_gametime().."_"..BELT_COUNTER
end

-- -------------------------------------------------
-- Geometry: Create-style hollow casing
-- -------------------------------------------------
-- Mid section: hollow rectangular frame with belt inside
local BELT_MID_BOX = {
  type = "fixed",
  fixed = {
    -- bottom + top slabs
    {-0.5, -0.5, -0.5,  0.5, -0.4, 0.5},   -- bottom
    {-0.5,  0.4, -0.5,  0.5,  0.5, 0.5},   -- top

    -- side walls
    {-0.5, -0.4, -0.5, -0.4,  0.4, 0.5},   -- left
    { 0.4, -0.4, -0.5,  0.5,  0.4, 0.5},   -- right

    -- inner belt slab
    {-0.45, -0.05, -0.5, 0.45, 0.05, 0.5},
  }
}

-- End section: same frame but with rollers visible at both ends
local BELT_END_BOX = {
  type = "fixed",
  fixed = {
    -- frame (same as mid)
    {-0.5, -0.5, -0.5,  0.5, -0.4, 0.5},
    {-0.5,  0.4, -0.5,  0.5,  0.5, 0.5},
    {-0.5, -0.4, -0.5, -0.4,  0.4, 0.5},
    { 0.4, -0.4, -0.5,  0.5,  0.4, 0.5},
    {-0.45, -0.05, -0.5, 0.45, 0.05, 0.5},

    -- rollers front
    {-0.45, -0.15,  0.30, -0.25, 0.15, 0.50},
    { 0.25, -0.15,  0.30,  0.45, 0.15, 0.50},
    -- rollers back
    {-0.45, -0.15, -0.50, -0.25, 0.15, -0.30},
    { 0.25, -0.15, -0.50,  0.45, 0.15, -0.30},
  }
}

local BELT_SELECT_BOX  = {type="fixed", fixed={{-0.5,-0.5,-0.5, 0.5,0.5,0.5}}}
local BELT_COLLIDE_BOX = BELT_SELECT_BOX

-- -------------------------------------------------
-- Belt nodes
-- -------------------------------------------------
min.register_node(NS.."belt_segment_mid", {
  description   = "Mechanical Belt (Middle)",
  drawtype      = "nodebox",
  node_box      = BELT_MID_BOX,
  selection_box = BELT_SELECT_BOX,
  collision_box = BELT_COLLIDE_BOX,
  tiles = {
    "fabricate_belt_top.png",
    "fabricate_belt_bottom.png",
    "fabricate_belt_side.png",
    "fabricate_belt_side.png",
    "fabricate_belt_side.png",
    "fabricate_belt_side.png",
  },
  paramtype   = "light",
  paramtype2  = "facedir",
  groups      = {cracky=1, not_in_creative_inventory=1},
  drop        = "",
})

min.register_node(NS.."belt_segment_end", {
  description   = "Mechanical Belt (End)",
  drawtype      = "nodebox",
  node_box      = BELT_END_BOX,
  selection_box = BELT_SELECT_BOX,
  collision_box = BELT_COLLIDE_BOX,
  tiles = {
    "fabricate_belt_top.png",
    "fabricate_belt_bottom.png",
    "fabricate_belt_side.png",
    "fabricate_belt_side.png",
    "fabricate_belt_side.png",
    "fabricate_belt_side.png",
  },
  paramtype   = "light",
  paramtype2  = "facedir",
  groups      = {cracky=1, not_in_creative_inventory=1},
  drop        = "",
})

-- -------------------------------------------------
-- Build belt lines
-- -------------------------------------------------
local function is_driveline(name)
  return name == NS.."shaft"
      or name == NS.."gearbox"
      or name == NS.."gantry_shaft"
end

local function axis_of(a, b)
  if a.x == b.x and a.z ~= b.z then return "z" end
  if a.z == b.z and a.x ~= b.x then return "x" end
  return nil
end

local function dir_1d(a, b, axis)
  if axis == "x" then return (b.x > a.x) and 1 or -1 end
  if axis == "z" then return (b.z > a.z) and 1 or -1 end
  return 0
end

-- place a segment node, record its exact position in line.segments
local function place_seg(line_id, p, facedir, is_end)
  local nn = min.get_node_or_nil(p)
  if nn and nn.name ~= "air"
         and nn.name ~= NS.."belt_segment_mid"
         and nn.name ~= NS.."belt_segment_end" then
    return false, "Path blocked at "..min.pos_to_string(p)
  end

  local name = is_end and NS.."belt_segment_end"
                      or  NS.."belt_segment_mid"

  min.set_node(p, {name = name, param2 = facedir})

  fabricate.belts[line_id].segments[#fabricate.belts[line_id].segments+1] =
    vector.new(p)

  return true
end

-- Build straight/slope belt run, returns line_id or nil, err
local function build_belt_run(user, a_pos, b_pos)
  -- 1) Anchors must be driveline blocks
  local an = min.get_node_or_nil(a_pos)
  local bn = min.get_node_or_nil(b_pos)
  if not (an and bn and is_driveline(an.name) and is_driveline(bn.name)) then
    return nil, "Anchors must be shafts / gearboxes / gantries."
  end

  -- 2) straight in X or Z
  local ax = axis_of(a_pos, b_pos)
  if not ax then
    return nil, "Shafts must align on X or Z (no corners)."
  end

  -- 3) length + slope
  local dir   = dir_1d(a_pos, b_pos, ax)
  local steps = (ax=="x") and math.abs(b_pos.x - a_pos.x)
                           or math.abs(b_pos.z - a_pos.z)
  local dy    = b_pos.y - a_pos.y

  if steps == 0 and dy == 0 then
    return nil, "Anchors overlap."
  end
  if steps + math.abs(dy) > BELT_MAX_LEN then
    return nil, "Belt is too long."
  end

  -- 4) create belt record
  local lid = new_line_id()
  fabricate.belts[lid] = {
    segments = {},
    axis     = ax,
    dir      = dir, -- ±1 along axis from A -> B
    slope    = (dy==0) and 0 or ((dy>0) and 1 or -1),
    speed    = 0,
    anchors  = {
      a = vector.new(a_pos),
      b = vector.new(b_pos),
    },
    steps    = steps + math.abs(dy),
  }

  -- facedir so the frame faces along the run
  local facedir = (ax=="x")
    and ((dir==1) and 1 or 3)
    or  ((dir==1) and 0 or 2)

  local cx, cy, cz  = a_pos.x, a_pos.y, a_pos.z
  local ax_step     = (dir==1) and 1 or -1
  local remain_y    = dy

  -- step 0 is a_pos, step steps is b_pos, we place between them
  for i = 1, steps do
    if remain_y ~= 0 then
      cy = cy + ((remain_y>0) and 1 or -1)
      remain_y = (remain_y>0) and (remain_y-1) or (remain_y+1)
    end

    local seg_pos = {x=cx, y=cy, z=cz}
    local is_end  = (i == 1 or i == steps)
    local ok, err = place_seg(lid, seg_pos, facedir, is_end)
    if not ok then
      fabricate.belts[lid] = nil
      return nil, err
    end

    if ax == "x" then
      cx = cx + ax_step
    else
      cz = cz + ax_step
    end
  end

  -- any remaining vertical steps after horizontal run
  while remain_y ~= 0 do
    cy = cy + ((remain_y>0) and 1 or -1)
    remain_y = (remain_y>0) and (remain_y-1) or (remain_y+1)

    local is_end = true -- extreme end; rollers look fine here
    local ok, err = place_seg(lid, {x=cx, y=cy, z=cz}, facedir, is_end)
    if not ok then
      fabricate.belts[lid] = nil
      return nil, err
    end
  end

  return lid
end

fabricate.build_belt_run = build_belt_run

-- -------------------------------------------------
-- Removal by punching any belt node
-- -------------------------------------------------
min.register_on_punchnode(function(pos, node, puncher, pt)
  if node.name ~= NS.."belt_segment_mid"
  and node.name ~= NS.."belt_segment_end" then
    return
  end

  for id, line in pairs(fabricate.belts or {}) do
    for _, sp in ipairs(line.segments or {}) do
      if sp.x == pos.x and sp.y == pos.y and sp.z == pos.z then
        -- remove all segments of this line
        for _, p in ipairs(line.segments or {}) do
          local n2 = min.get_node_or_nil(p)
          if n2 and (n2.name == NS.."belt_segment_mid"
                 or  n2.name == NS.."belt_segment_end") then
            min.remove_node(p)
          end
        end
        fabricate.belts[id] = nil
        if puncher and puncher:is_player() then
          min.chat_send_player(puncher:get_player_name(), "Belt removed.")
        end
        return
      end
    end
  end
end)

-- -------------------------------------------------
-- Movement step
-- -------------------------------------------------
local belt_step_accum = 0

min.register_globalstep(function(dtime)
  belt_step_accum = belt_step_accum + dtime
  if belt_step_accum < 0.1 then return end
  local dt = belt_step_accum
  belt_step_accum = 0

  -- reset speeds
  for _, line in pairs(fabricate.belts or {}) do
    line.speed = 0
  end

  -- compute speed from anchor shaft power
  local grid = fabricate.power_grid or {}
  for _, line in pairs(fabricate.belts or {}) do
    local best = 0
    if line.anchors then
      local a = line.anchors.a
      local b = line.anchors.b
      if a then
        local e = grid[pos_to_key(a)]
        if e and e.power and e.power > best then best = e.power end
      end
      if b then
        local e = grid[pos_to_key(b)]
        if e and e.power and e.power > best then best = e.power end
      end
    end
    line.speed = belt_speed_for_power(best)
  end

  -- move riders
  for _, line in pairs(fabricate.belts or {}) do
    local spd = line.speed or 0
    if spd <= 0 then goto nextline end

    local dir_vec = (line.axis=="x")
      and {x=line.dir,y=0,z=0}
      or  {x=0,y=0,z=line.dir}
    local perp = (line.axis=="x")
      and {x=0,y=0,z=1}
      or  {x=1,y=0,z=0}

    local ybias = (line.slope==0) and 0 or (line.slope * 0.5)

    for _, segpos in ipairs(line.segments or {}) do
      local scan_center = {
        x = segpos.x + 0.5,
        y = segpos.y + BELT_PICKUP_Y,
        z = segpos.z + 0.5,
      }

      for _, obj in ipairs(min.get_objects_inside_radius(scan_center, 0.8)) do
        local ent = obj:get_luaentity()
        if ent and ent.name and ent.name:find("^"..NS) then
          goto nextobj
        end

        local p = obj:get_pos()
        if not p then goto nextobj end

        -- must be reasonably close vertically
        if math.abs(p.y - (segpos.y + 0.0)) > 0.6 then
          goto nextobj
        end

        local v = obj:get_velocity() or {x=0,y=0,z=0}

        -- forward push
        v.x = v.x + dir_vec.x * spd * dt * 8
        v.z = v.z + dir_vec.z * spd * dt * 8

        -- slopes
        v.y = (obj:is_player() and v.y)
          or math.min(v.y + ybias * dt, 1.0)

        -- centering
        local offx = (p.x - (segpos.x + 0.5))
        local offz = (p.z - (segpos.z + 0.5))
        local lateral = offx * perp.x + offz * perp.z
        v.x = v.x - perp.x * lateral * BELT_CENTER_PULL * dt
        v.z = v.z - perp.z * lateral * BELT_CENTER_PULL * dt

        -- friction
        v.x = v.x * (1 - BELT_FRICTION * dt)
        v.z = v.z * (1 - BELT_FRICTION * dt)

        obj:set_velocity(v)

        -- keep non-players from sinking
        if not obj:is_player()
        and p.y < segpos.y + 0.1 then
          obj:set_pos({x=p.x, y=segpos.y + 0.12, z=p.z})
        end

        ::nextobj::
      end
    end
    ::nextline::
  end
end)
