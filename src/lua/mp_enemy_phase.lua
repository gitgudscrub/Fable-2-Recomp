-- mp_enemy_phase.lua - multiplayer: run by the game (src/net/mp_enemies.h) on the
-- game thread when enemy copies must be created or removed. Fixed content: no
-- network data is ever put into a script. The SetPosition with x = -7779 is
-- caught by the C++ side (it does not move the hero) and does the queued work
-- natively while the game is inside a script, where creating entities is safe.
local ok, h = pcall(GetPlayerHero)
if ok and h then h:SetPosition(CVector3(-7779, 0, 0)) end
