-- nodes/belts.lua
-- Mechanical belts for Fabricate (Create-like, entity visuals)

local min  = fabricate.min
local NS   = fabricate.NS
local H    = fabricate.helpers

local pos_to_key = H.pos_to_key

------------------------------------------------------------
-- Tunables
------------------------------------------------------------

fabricate.belt_max_len   = fabricate.belt_max_len or 20
local BELT_MAX_LEN       = fabricate.belt_max_len
local BELT_MIN_POWER     = 2
local BELT_BASE_SPEED    = 1.6   -- m/s at min power
local BELT_SPEED_GAIN    = 0.25  -- m/s per extra power
local BELT_SPEED_MAX     = 6.0
local BELT_CENTER_PULL   = 2.2
local BELT_PICKUP_Y      = 0.55
local BELT_FRICTION      = 0.10

local function belt_speed_for_power(p)
  if not p or p < BELT_MIN_POWER then return 0 end
  local s = BELT_BASE_SPEED + (p - BELT_MIN_POWER) * BELT_SPEED_GAIN
  if s > BELT_SPEED_MAX then s = BELT_SPEED_MAX end
  return s
end

------------------------------------------------------------
-- Utility
------------------------------------------------------------

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

local function is_driveline(name)
  return name == NS.."shaft"
      or name == NS.."gearbox"
      or name == NS.."gantry_shaft"
end

------------------------------------------------------------
-- Invisible shaft variant (for being "inside" the belt)
------------------------------------------------------------

local shaft_def = table.copy(min.registered_nodes[NS.."shaft"] or {})
if next(shaft_def) then
  shaft_def.description = (shaft_def.description or "Shaft") .. " (hidden)"
  shaft_def.drawtype    = "airlike"
  shaft_def.tiles       = {"fabricate_invisible.png"} -- 1px fully transparent
  shaft_def.pointable   = false
  shaft_def.walkable    = false
  shaft_def.sunlight_propagates = true
  shaft_def.use_texture_alpha   = "clip"

  min.register_node(NS.."shaft_hidden", shaft_def)
else
  min.log("warning", "[fabricate] shaft node not found when belts.lua loaded")
end

------------------------------------------------------------
-- Invisible belt carrier node (logic only; visuals are entities)
------------------------------------------------------------

min.register_node(NS.."belt_carrier", {
  description   = "Mechanical Belt (logic)",
  drawtype      = "airlike",
  tiles         = {"fabricate_invisible.png"},
  paramtype     = "light",
  paramtype2    = "facedir",
  pointable     = false,
  walkable      = false,
  diggable      = false,
  buildable_to  = false,
  sunlight_propagates = true,
  groups        = {not_in_creative_inventory = 1},
  drop          = "",
})

------------------------------------------------------------
-- Belt visual entity (uses 3 meshes: start / mid / end)
------------------------------------------------------------

local function belt_mesh_for(kind)
  if kind == "start" then
    return "belt_end.obj"
  elseif kind == "end" then
    return "belt_start.obj"
  else
    return "belt_middle.obj"
  end
end

min.register_entity(NS.."belt_visual", {
  initial_properties = {
    visual              = "mesh",
    mesh                = "belt_middle.obj",
    textures            = {"fabricate_belt.png"},
    physical            = false,
    collide_with_objects= false,
    pointable           = false,
    static_save         = true,
    visual_size         = {x=5, y=5, z=5},
    use_texture_alpha   = true,
    backface_culling    = false,
    shaded              = true,
    glow                = 0,
  },

  _kind   = "mid",  -- "start" | "mid" | "end"
  _axis   = "z",    -- "x" | "z"
  _dir    = 1,      -- 1 | -1
  _line   = nil,    -- line_id
  _index  = 1,      -- segment index

  on_activate = function(self, staticdata, dtime_s)
    if staticdata and staticdata ~= "" then
      local ok, data = pcall(min.parse_json, staticdata)
      if ok and type(data) == "table" then
        self._kind  = data.kind or "mid"
        self._axis  = data.axis or "z"
        self._dir   = data.dir or 1
        self._line  = data.line
        self._index = data.index or 1
      end
    end

    -- Ensure proper mesh and rotation
    local mesh = belt_mesh_for(self._kind)
    local yaw  = 0
    if self._axis == "x" then
      yaw = (self._dir == 1) and (math.pi/2) or (3*math.pi/2)
    else
      yaw = (self._dir == 1) and 0 or math.pi
    end
    self.object:set_properties({mesh = mesh})
    self.object:set_yaw(yaw)
  end,

  get_staticdata = function(self)
    return min.write_json({
      kind  = self._kind,
      axis  = self._axis,
      dir   = self._dir,
      line  = self._line,
      index = self._index,
    })
  end,
})

local BELT_COUNTER = 0
local function new_line_id()
  BELT_COUNTER = BELT_COUNTER + 1
  return "belt_" .. min.get_gametime() .. "_" .. BELT_COUNTER
end

------------------------------------------------------------
-- Build belt run (called from belt_linker.lua)
------------------------------------------------------------

local function build_belt_run(user, a_pos, b_pos)
  local an = min.get_node_or_nil(a_pos)
  local bn = min.get_node_or_nil(b_pos)
  if not (an and bn and is_driveline(an.name) and is_driveline(bn.name)) then
    return nil, "Anchors must be shafts, gearboxes or gantries."
  end

  local axis = axis_of(a_pos, b_pos)
  if not axis then
    return nil, "Shafts must align on X or Z (no corners)."
  end

  local dir   = dir_1d(a_pos, b_pos, axis)
  local steps = (axis == "x") and math.abs(b_pos.x - a_pos.x)
                             or math.abs(b_pos.z - a_pos.z)
  local dy    = b_pos.y - a_pos.y
  if steps == 0 and dy == 0 then
    return nil, "Anchors overlap."
  end
  local total_len = steps + math.abs(dy)
  if total_len > BELT_MAX_LEN then
    return nil, "Belt is too long (max "..BELT_MAX_LEN..")."
  end

  local line_id = new_line_id()
  local line = {
    id        = line_id,
    axis      = axis,
    dir       = dir,
    slope     = (dy == 0) and 0 or ((dy > 0) and 1 or -1),
    steps     = total_len,
    segments  = {},
    entities  = {},
    anchors   = {
      a = {pos = vector.new(a_pos)},
      b = {pos = vector.new(b_pos)},
    },
    speed     = 0,
  }
  fabricate.belts[line_id] = line

  -- Swap visible shafts to hidden variants, so the belt appears to encompass them.
  local function hide_shaft_at(pos)
    local n = min.get_node_or_nil(pos)
    if n and n.name == NS.."shaft" then
      min.set_node(pos, {name = NS.."shaft_hidden", param2 = n.param2})
    end
  end
  hide_shaft_at(a_pos)
  hide_shaft_at(b_pos)

  -- Step along X/Z starting from a_pos towards b_pos, placing belt carriers + entities.
  local cx, cy, cz = a_pos.x, a_pos.y, a_pos.z
  local horiz_step = (dir == 1) and 1 or -1
  local remaining_y = dy

  local function advance_horiz()
    if axis == "x" then
      cx = cx + horiz_step
    else
      cz = cz + horiz_step
    end
  end

  -- We place belt segments between the two anchors.
  for i = 1, steps do
    -- apply vertical adjustments gradually
    if remaining_y ~= 0 then
      if remaining_y > 0 then
        cy = cy + 1
        remaining_y = remaining_y - 1
      else
        cy = cy - 1
        remaining_y = remaining_y + 1
      end
    end

    local seg_pos = {x = cx, y = cy, z = cz}

    -- Avoid placing over something solid (except the original shafts).
    local nn = min.get_node_or_nil(seg_pos)
    if nn and nn.name ~= "air"
      and nn.name ~= NS.."shaft_hidden"
      and nn.name ~= NS.."shaft"
      and nn.name ~= NS.."belt_carrier"
    then
      fabricate.belts[line_id] = nil
      return nil, "Path blocked at "..min.pos_to_string(seg_pos)
    end

    -- logic node
    min.set_node(seg_pos, {name = NS.."belt_carrier", param2 = 0})

    -- choose segment kind
    local kind
    if i == 1 then
      kind = "start"
    elseif i == steps then
      kind = "end"
    else
      kind = "mid"
    end

    -- spawn visual entity
    local obj = min.add_entity(
      {x = seg_pos.x + 0.5, y = seg_pos.y + 0.5, z = seg_pos.z + 0.5},
      NS.."belt_visual"
    )
    if obj then
      local ent = obj:get_luaentity()
      if ent then
        ent._kind  = kind
        ent._axis  = axis
        ent._dir   = dir
        ent._line  = line_id
        ent._index = #line.segments + 1

        local mesh = belt_mesh_for(kind)
        local yaw  = 0
        if axis == "x" then
          yaw = (dir == 1) and (math.pi/2) or (3*math.pi/2)
        else
          yaw = (dir == 1) and 0 or math.pi
        end
        obj:set_properties({mesh = mesh})
        obj:set_yaw(yaw)

        line.entities[#line.entities + 1] = obj
      end
    end

    line.segments[#line.segments + 1] = vector.new(seg_pos)

    advance_horiz()
  end

  -- Any remaining pure vertical stretch after horizontal run (rare, but allowed).
  while remaining_y ~= 0 do
    if remaining_y > 0 then
      cy = cy + 1
      remaining_y = remaining_y - 1
    else
      cy = cy - 1
      remaining_y = remaining_y + 1
    end

    local seg_pos = {x = cx, y = cy, z = cz}

    local nn = min.get_node_or_nil(seg_pos)
    if nn and nn.name ~= "air"
      and nn.name ~= NS.."shaft_hidden"
      and nn.name ~= NS.."shaft"
      and nn.name ~= NS.."belt_carrier"
    then
      fabricate.belts[line_id] = nil
      return nil, "Path blocked at "..min.pos_to_string(seg_pos)
    end

    min.set_node(seg_pos, {name = NS.."belt_carrier", param2 = 0})
    local obj = min.add_entity(
      {x = seg_pos.x + 0.5, y = seg_pos.y + 0.5, z = seg_pos.z + 0.5},
      NS.."belt_visual"
    )
    if obj then
      local ent = obj:get_luaentity()
      if ent then
        ent._kind  = "mid"
        ent._axis  = axis
        ent._dir   = dir
        ent._line  = line_id
        ent._index = #line.segments + 1
      end
      line.entities[#line.entities + 1] = obj
    end

    line.segments[#line.segments + 1] = vector.new(seg_pos)
  end

  return line_id
end

fabricate.build_belt_run = build_belt_run

------------------------------------------------------------
-- Removing a belt: punch any belt carrier node
------------------------------------------------------------

local function find_line_by_pos(pos)
  for id, line in pairs(fabricate.belts or {}) do
    for _, sp in ipairs(line.segments or {}) do
      if sp.x == pos.x and sp.y == pos.y and sp.z == pos.z then
        return id, line
      end
    end
  end
  return nil, nil
end

min.register_on_punchnode(function(pos, node, puncher, pt)
  if node.name ~= NS.."belt_carrier" then
    return
  end

  local line_id, line = find_line_by_pos(pos)
  if not line then return end

  -- remove logic nodes + visual entities
  for _, p in ipairs(line.segments or {}) do
    local nn = min.get_node_or_nil(p)
    if nn and nn.name == NS.."belt_carrier" then
      min.remove_node(p)
    end
  end
  for _, obj in ipairs(line.entities or {}) do
    if obj and obj:get_luaentity() then
      obj:remove()
    end
  end

  -- restore hidden shafts at anchors
  local function restore_shaft_at(pos)
    local n = min.get_node_or_nil(pos)
    if n and n.name == NS.."shaft_hidden" then
      min.set_node(pos, {name = NS.."shaft", param2 = n.param2})
    end
  end
  if line.anchors then
    if line.anchors.a then restore_shaft_at(line.anchors.a.pos) end
    if line.anchors.b then restore_shaft_at(line.anchors.b.pos) end
  end

  fabricate.belts[line_id] = nil

  if puncher and puncher:is_player() then
    min.chat_send_player(puncher:get_player_name(), "Mechanical Belt removed.")
  end
end)

------------------------------------------------------------
-- Movement step
------------------------------------------------------------

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
      if line.anchors.a then
        local e = grid[pos_to_key(line.anchors.a.pos)]
        if e and e.power and e.power > best then best = e.power end
      end
      if line.anchors.b then
        local e = grid[pos_to_key(line.anchors.b.pos)]
        if e and e.power and e.power > best then best = e.power end
      end
    end
    line.speed = belt_speed_for_power(best)
  end

  -- move riders
  for _, line in pairs(fabricate.belts or {}) do
    local spd = line.speed or 0
    if spd <= 0 then goto continue_line end

    local dir_vec
    if line.axis == "x" then
      dir_vec = {x = line.dir, y = 0, z = 0}
    else
      dir_vec = {x = 0, y = 0, z = line.dir}
    end
    local perp = (line.axis == "x") and {x=0,y=0,z=1} or {x=1,y=0,z=0}
    local ybias = (line.slope == 0) and 0 or (line.slope * 0.5)

    for _, segpos in ipairs(line.segments or {}) do
      local center = {
        x = segpos.x + 0.5,
        y = segpos.y + BELT_PICKUP_Y,
        z = segpos.z + 0.5,
      }

      local objs = min.get_objects_inside_radius(center, 0.8)
      for oi = 1, #objs do
        local obj = objs[oi]
        local ent = obj:get_luaentity()
        -- ignore fabricate belt visuals etc.
        if ent and ent.name and ent.name:find("^"..NS.."belt_visual") then
          -- skip visual
        else
          local p = obj:get_pos()
          if p and math.abs(p.y - (segpos.y + 0.525)) < 0.35 then
            local v = obj:get_velocity() or {x=0,y=0,z=0}

            -- forward push
            v.x = v.x + dir_vec.x * spd * dt * 8
            v.z = v.z + dir_vec.z * spd * dt * 8

            -- slopes (don't fight player jump)
            if not obj:is_player() then
              v.y = math.min(v.y + ybias * dt, 1.0)
            end

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
            if not obj:is_player() and p.y < segpos.y + 0.45 then
              obj:set_pos({x=p.x, y=segpos.y + 0.46, z=p.z})
            end
          end
        end
      end
    end

    ::continue_line::
  end
end)
