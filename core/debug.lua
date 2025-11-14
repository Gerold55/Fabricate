-- core/debug.lua
local min     = fabricate.min
local vector  = vector
local NS      = fabricate.NS
local helpers = fabricate.helpers
local pos_to_key = helpers.pos_to_key

min.register_chatcommand("fab_debug", {
  description = "List powered Fabricate nodes near you",
  func = function(name)
    local player = min.get_player_by_name(name)
    if not player then return false, "No player." end
    local p = vector.round(player:get_pos())
    local r = 12
    local out = {}
    for _, data in pairs(fabricate.power_grid) do
      local pos = data.pos
      if math.abs(pos.x-p.x)<=r
          and math.abs(pos.y-p.y)<=r
          and math.abs(pos.z-p.z)<=r then
        local n = min.get_node_or_nil(pos)
        out[#out+1] = ("%s @ %d,%d,%d = %d")
          :format(n and n.name or "?", pos.x, pos.y, pos.z, data.power)
      end
    end
    if #out==0 then
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

min.register_chatcommand("fab_probe", {
  description = "Show Fabricate power at the pointed node",
  func = function(name)
    local pl = min.get_player_by_name(name)
    if not pl then return false,"no player" end
    local eye = pl:get_pos(); eye.y = eye.y + 1.5
    local look = pl:get_look_dir()
    local ray = min.raycast(
      eye,
      {x=eye.x+look.x*6,y=eye.y+look.y*6,z=eye.z+look.z*6},
      true, false
    )
    local target
    for hit in ray do
      if hit.type=="node" then target = hit.under; break end
    end
    if not target then return true, "No node targeted." end
    local k = pos_to_key(target)
    local e = fabricate.power_grid[k]
    local n = min.get_node_or_nil(target)
    local name_str = n and n.name or "?"
    if e then
      return true, ("%s at %s has power %d")
        :format(name_str, min.pos_to_string(target), e.power)
    else
      return true, ("%s at %s has NO power")
        :format(name_str, min.pos_to_string(target))
    end
  end
})

min.register_chatcommand("fab_rescan", {
  description = "Rescan a radius around you and (re)track Fabricate parts",
  params = "[radius]",
  func = function(name, param)
    local player = min.get_player_by_name(name)
    if not player then return false, "No player." end
    local r = tonumber(param) or 16
    local pmin = vector.subtract(vector.round(player:get_pos()), r)
    local pmax = vector.add(vector.round(player:get_pos()), r)
    local count = 0
    for x = pmin.x, pmax.x do
      for y = pmin.y, pmax.y do
        for z = pmin.z, pmax.z do
          local pos = {x=x,y=y,z=z}
          local n = min.get_node_or_nil(pos)
          if n and helpers.is_mech(n.name) then
            helpers.track_mech(pos); count = count + 1
          end
        end
      end
    end
    return true,
      ("Tracked %d mechanical nodes within r=%d."):format(count, r)
  end
})

min.register_chatcommand("fab_belts", {
  description = "List all active belts",
  func = function(name)
    for id, line in pairs(fabricate.belts or {}) do
      min.chat_send_player(
        name,
        ("%s: %d segments, speed %.2f")
          :format(id, #line.segments, line.speed or 0)
      )
    end
    return true, "Done."
  end
})
