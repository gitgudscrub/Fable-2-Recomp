-- mp_puppet_cleanup.lua - multiplayer: remove puppet bodies whose player has left.
-- Run by the game (src/net/mp_puppets.h) on the game thread. Fixed content: no
-- network data is ever put into a script. The C++ side first moves a body it no
-- longer needs far out of the world (x below -8000); this removes every puppet
-- body found out there.
for k = 1, (MP_PUPPET_SERIAL or 0) do
  local ok, e = pcall(Debug.GetEntityWithName, "mp_puppet_" .. k)
  if ok and e then
    local okp, x = pcall(function() return e:GetPosition():GetX() end)
    if okp and type(x) == "number" and x < -8000 then
      pcall(function() e:Destroy() end)
    end
  end
end
