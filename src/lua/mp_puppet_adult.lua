-- mp_puppet_adult.lua - multiplayer: create one puppet body (CreatureHero) for a remote player.
-- Run by the game (src/net/mp_puppets.h) on the game thread. Fixed content: no
-- network data is ever put into a script. SetPosition with x = -7777 is the
-- marker the C++ side catches to learn which entity is the new puppet.
MP_PUPPET_SERIAL = (MP_PUPPET_SERIAL or 0) + 1
local ok, e = pcall(Debug.CreateEntityByHero, "CreatureHero", "mp_puppet_" .. MP_PUPPET_SERIAL)
if ok and e then e:SetPosition(CVector3(-7777, 0, 0)) end
