-- mp_reinforce.lua - multiplayer encounter scaling: extra enemies for co-op fights.
-- Run by the host's game (src/net/mp_enemies.h) on the game thread when a fight
-- with 2 or more players starts. Fixed content: no network data is ever put
-- into a script.
--
-- For each open-world (dynamic) creature generator with creatures near the hero,
-- this asks for -1 reinforcements, which the game never asks for itself. The
-- C++ hook on CreateReinforcements turns that into a real number only for a
-- generator whose creatures are in a co-op fight (once per fight); for every
-- other generator -1 creates nothing. The new creatures join the fight the way
-- the game's own reinforcements do.
local hero = GetPlayerHero()
if not hero then return end
local ok, list = pcall(function()
  local s = SearchTools.StartNewSearch("creature")
  s = SearchTools.FilterWithinDistanceOfPos(s, hero:GetPosition(), 60)
  return SearchTools.GetSearchResults(s)
end)
if not ok or not list then return end
local done = {}
for _, c in pairs(list) do
  local okg, g = pcall(Creature.GetSpawnEntity, c)
  if okg and g and not done[g] then
    done[g] = true
    local okd, dyn = pcall(CreatureGenerator.IsDynamic, g)
    if okd and dyn then
      local okl, level = pcall(Creature.GetCreatureGeneratorLevel, c)
      if not okl or type(level) ~= "number" then level = 1 end
      local okr, made = pcall(CreatureGenerator.CreateReinforcements, g, level, -1)
      if okr and type(made) == "table" then
        for _, e in pairs(made) do
          pcall(function()
            local info = CombatRegister.GetCombatInfo(e)
            if info then info.IgnoreChaseRadius = true end
          end)
          pcall(Perception.MakeAwareOf, e, hero)
        end
      end
    end
  end
end
