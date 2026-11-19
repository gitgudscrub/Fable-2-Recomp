-- Console slot 2 (--console_slot=2): installs console_pump.lua reading
-- console_run_2.lua, so games sharing one game data root don't run each
-- other's console lines.
rawset(_G, "__f2_run_file", "scripts/recomp/console_run_2.lua")
local f = loadfile("scripts/recomp/console_pump.lua")
if f then return f() end
