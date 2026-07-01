-- schook append to /lua/sim/Projectile.lua (mounted via /schook, runs after the
-- base module so the global Projectile class already exists).
--
-- Headless-env combat fix. In our mounted FAF gamedata a few projectiles reach
-- Projectile:DoDamage with DamageData.DamageType == nil -- notably the UEF ACU
-- Overcharge (tdfovercharge01) and the Cybran tactical-missile split
-- (cifmissiletacticalsplit01), whose damage is computed dynamically and whose
-- DamageType is expected to already be on the projectile's DamageData from weapon
-- creation. When it is nil the engine Damage()/DamageArea() call throws
-- "string expected but got nil", the OnImpact aborts (no damage dealt), and each
-- impact dumps a stack trace -- ~350 error tracebacks per 24s that (a) flood the
-- sim log and dominate riched20 in a perf profile, and (b) suppress attrition so
-- battles do not resolve. Default a nil DamageType to 'Normal' so the impact
-- resolves. Damage AMOUNT is still computed correctly upstream; only the type
-- label is defaulted (special Overcharge one-shot interactions won't trigger, an
-- acceptable fidelity trade for a non-erroring, damage-dealing sim to profile).
do
    local baseDoDamage = Projectile.DoDamage
    Projectile.DoDamage = function(self, instigator, DamageData, targetEntity, cachedPosition)
        if DamageData and DamageData.DamageType == nil then
            DamageData.DamageType = 'Normal'
        end
        return baseDoDamage(self, instigator, DamageData, targetEntity, cachedPosition)
    end
end
