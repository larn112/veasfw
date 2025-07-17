-- Servicios compartidos
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local BadgeService = game:GetService("BadgeService")

-- =====================================================================
-- SISTEMA AUTOREC/AUTODIVE (MEJORADO)
-- =====================================================================
-- Variables
local PLAYER = Players.LocalPlayer
local MARKER_RADIUS = 20
local DIVE_TRACKING_RADIUS = 21
local DIVE_ACTION_RADIUS = 18
local MOVE_COOLDOWN = 0.1
local lastMoveTime = 0
local autoRecEnabled = false
local autoDiveEnabled = false
local lastDiveTime = 0
local DIVE_COOLDOWN = 0.5

-- Variables para detección de manipulación
local lastMarkerPositions = {}
local hitOrigins = {}
local manipulationThreshold = 1.35

-- Variables para zona neutral
local neutralZoneTimers = {}
local NEUTRAL_CONFIRMATION_TIME = 0.25  -- 250 ms

-- Variables para bloqueo
local lastBlockTime = 0
local BLOCK_COOLDOWN = 4  -- 4 segundos para seguimiento post-bloqueo

-- Definición de redes
local NETS = {
    { Position = Vector3.new(-100, 5.6, 0), Size = Vector3.new(52, 10.2, 0.3) },
    { Position = Vector3.new(0,    5.6, 0), Size = Vector3.new(52, 10.2, 0.3) },
    { Position = Vector3.new(100,  5.6, 0), Size = Vector3.new(52, 10.2, 0.3) },
}

-- Definición de courts (canchas)
local COURTS = {
    { Position = Vector3.new(-100, 0.5, 0), Size = Vector3.new(48, 0.2, 95) },
    { Position = Vector3.new(0,    0.5, 0), Size = Vector3.new(48, 0.2, 95) },
    { Position = Vector3.new(100,  0.5, 0), Size = Vector3.new(48, 0.2, 95) },
}

-- Marcador compartido
local Marker = Instance.new("Part")
Marker.Name = "Marker"
Marker.Size = Vector3.new(2, 2, 2)
Marker.Shape = Enum.PartType.Ball
Marker.BrickColor = BrickColor.new("Bright violet")
Marker.CanCollide = false
Marker.Anchored = true
Marker.Transparency = 1
Marker.Material = Enum.Material.Neon
Marker.Parent = BadgeService

-- Función para determinar el lado de la cancha
local function GetCourtSide()
    local character = PLAYER.Character
    if not character then return nil end
    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    if root.Position.Z >= 0.1 then return 1
    elseif root.Position.Z <= -0.1 then return -1
    else return nil end
end

-- Encuentra la cancha más cercana
local function GetPlayerCourt()
    local character = PLAYER.Character
    if not character then return nil end
    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local best, bestDist = nil, math.huge
    for _, court in ipairs(COURTS) do
        local d = (root.Position - court.Position).Magnitude
        if d < bestDist then bestDist, best = d, court end
    end
    return best
end

-- Revisa si un punto está dentro de la cancha
local function IsPointInCourt(court, point)
    local half = court.Size / 2
    return  point.X >= court.Position.X - half.X and
            point.X <= court.Position.X + half.X and
            point.Z >= court.Position.Z - half.Z and
            point.Z <= court.Position.Z + half.Z
end

-- Chequea bloqueos recientes
local function IsBlockActive()
    for _, p in ipairs(Players:GetPlayers()) do
        local char = p.Character
        if char then
            local hb = char:FindFirstChild("BlockHitbox")
            if hb and hb:FindFirstChild("Block") then
                lastBlockTime = tick()
                return true
            end
        end
    end
    return (tick() - lastBlockTime) < BLOCK_COOLDOWN
end

-- Detección de colisión con la red
local function CheckNetCollision(startPos, vel, landingPos, tLand)
    local grav = Workspace.Gravity
    local accel = Vector3.new(0, -grav, 0)
    local earliest = { time = tLand, position = landingPos }
    for _, net in ipairs(NETS) do
        local half = net.Size / 2
        local minB = net.Position - half
        local maxB = net.Position + half
        if vel.X ~= 0 or vel.Z ~= 0 then
            local tx1 = (minB.X - startPos.X) / vel.X
            local tx2 = (maxB.X - startPos.X) / vel.X
            local tz1 = (minB.Z - startPos.Z) / vel.Z
            local tz2 = (maxB.Z - startPos.Z) / vel.Z
            local t0 = math.max(math.min(tx1, tx2), math.min(tz1, tz2), 0)
            local t1 = math.min(math.max(tx1, tx2), math.max(tz1, tz2), tLand)
            if t0 <= t1 then
                local tMid = (t0 + t1) / 2
                local yPos = startPos.Y + vel.Y*tMid + 0.5*accel.Y*tMid^2
                if yPos >= minB.Y and yPos <= maxB.Y then
                    local hit = Vector3.new(
                        startPos.X + vel.X*tMid,
                        yPos,
                        startPos.Z + vel.Z*tMid
                    )
                    if tMid < earliest.time then
                        earliest = { time = tMid, position = hit }
                    end
                end
            end
        end
    end
    return earliest.position
end

-- Cálculo de la posición de caída
local function CalculateLanding(vel, pos)
    local grav = Workspace.Gravity
    local accel = Vector3.new(0, -grav, 0)
    local a = 0.5 * accel.Y
    local b = vel.Y
    local c = pos.Y
    local disc = b*b - 4*a*c
    if disc < 0 then return pos end
    local t1 = (-b + math.sqrt(disc)) / (2*a)
    local t2 = (-b - math.sqrt(disc)) / (2*a)
    local tLand = math.max(t1, t2)
    local land = Vector3.new(
        pos.X + vel.X * tLand,
        0,
        pos.Z + vel.Z * tLand
    )
    return CheckNetCollision(pos, vel, land, tLand)
end

-- UI AutoRec
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AutoRecUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = PLAYER:WaitForChild("PlayerGui")

local Indicator = Instance.new("Frame")
Indicator.Name = "StatusIndicator"
Indicator.Size = UDim2.new(0, 4, 0, 50)
Indicator.Position = UDim2.new(0, 2, 0.5, -25)
Indicator.BackgroundColor3 = Color3.new(0, 0, 0)
Indicator.BorderSizePixel = 0
Indicator.ZIndex = 10
Indicator.Parent = ScreenGui

local Hitbox = Instance.new("TextButton")
Hitbox.Name = "ToggleHitbox"
Hitbox.Size = UDim2.new(0, 20, 0, 70)
Hitbox.Position = UDim2.new(0, 0, 0.5, -35)
Hitbox.BackgroundTransparency = 1
Hitbox.Text = ""
Hitbox.ZIndex = 11
Hitbox.Parent = ScreenGui

-- =====================================================================
-- NÚCLEO DEL AUTODIVE
-- =====================================================================
local function MoveToPosition(targetPosition)
    local char = PLAYER.Character
    if not char then return end
    local humanoid = char:FindFirstChild("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return end

    local dir = (targetPosition - root.Position)
    dir = Vector3.new(dir.X, 0, dir.Z).Unit
    local angle = math.deg(math.atan2(dir.Z, dir.X))
    if angle < 0 then angle += 360 end

    local fixed = {0,45,90,135,180,225,270,315}
    local bestA, bestDiff = fixed[1], math.abs(angle - fixed[1])
    for _, a in ipairs(fixed) do
        local d = math.abs(angle - a)
        if d < bestDiff then bestDiff, bestA = d, a end
    end

    local rad = math.rad(bestA)
    local moveDir = Vector3.new(math.cos(rad),0,math.sin(rad)).Unit
    humanoid:Move(moveDir*2, false)
end

local function TriggerDive()
    if tick() - lastDiveTime < DIVE_COOLDOWN then return end
    lastDiveTime = tick()
    -- CORRECCIÓN: KeyCode.Three en mayúscula
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Three, false, game)
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Three, false, game)
end

local function ExecuteDiveAction(targetPosition)
    local char = PLAYER.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local dist = (targetPosition - root.Position).Magnitude
    if dist <= DIVE_TRACKING_RADIUS then
        MoveToPosition(targetPosition)
    end
    if dist <= DIVE_ACTION_RADIUS then
        TriggerDive()
    end
end

-- =====================================================================
-- LÓGICA PRINCIPAL
-- =====================================================================
RunService:BindToRenderStep("CombinedSystem", Enum.RenderPriority.Camera.Value, function()
    local side = GetCourtSide()
    if not side then return end
    local court = GetPlayerCourt()
    if not court then return end
    local block = IsBlockActive()

    for _, m in ipairs(Workspace:GetChildren()) do
        if m:IsA("Model") and m.Name == "Ball" then
            if m:FindFirstChild("Marker") then continue end
            local ball = m:FindFirstChild("BallPart")
            local velObj = m:FindFirstChild("Velocity")
            if ball and velObj then
                local pos = ball.Position
                local vel = velObj.Value
                local landingPos = CalculateLanding(vel, pos)

                -- Detección de manipulación
                local last = lastMarkerPositions[m]
                if last then
                    if (landingPos - last).Magnitude > manipulationThreshold then
                        hitOrigins[m] = pos
                    end
                end
                lastMarkerPositions[m] = landingPos

                -- Neutral zone
                local id = tostring(m:GetDebugId())
                local inNeut = (pos.Z > -0.35 and pos.Z < 0.35)
                local nt = neutralZoneTimers[id]
                if not nt then
                    neutralZoneTimers[id] = { inNeutral=false, startTime=nil, confirmed=false }
                    nt = neutralZoneTimers[id]
                end
                if inNeut then
                    if not nt.inNeutral then
                        nt.inNeutral = true; nt.startTime = tick(); nt.confirmed = false
                    elseif not nt.confirmed and tick() - nt.startTime > NEUTRAL_CONFIRMATION_TIME then
                        nt.confirmed = true
                    end
                else
                    nt.inNeutral = false; nt.confirmed = false
                end
                local isNeutral = nt.confirmed

                -- Territorio y origen
                local originZ = hitOrigins[m] and hitOrigins[m].Z or pos.Z
                local fromOpp
                if isNeutral then
                    fromOpp = (landingPos.Z >= 0.35 and side == 1) or (landingPos.Z <= -0.35 and side == -1)
                else
                    fromOpp = side == 1 and originZ < -0.01 or side == -1 and originZ > 0.01
                end
                local onOurSide = side == 1 and landingPos.Z >= 0.35 or side == -1 and landingPos.Z <= -0.35
                local inCourt = IsPointInCourt(court, landingPos)

                -- Decisión final
                local should = (block and onOurSide) or (fromOpp and onOurSide and inCourt)
                Marker.CFrame = CFrame.new(landingPos)

                -- AutoRec
                if autoRecEnabled and should then
                    local rootPart = PLAYER.Character and PLAYER.Character.PrimaryPart
                    if rootPart and (landingPos - rootPart.Position).Magnitude <= MARKER_RADIUS then
                        if tick() - lastMoveTime >= MOVE_COOLDOWN then
                            PLAYER.Character.Humanoid:MoveTo(landingPos)
                            lastMoveTime = tick()
                        end
                    end
                end

                -- AutoDive
                if autoDiveEnabled and should then
                    ExecuteDiveAction(landingPos)
                end
            end
        else
            lastMarkerPositions[m] = nil
            hitOrigins[m] = nil
            neutralZoneTimers[tostring(m:GetDebugId())] = nil
        end
    end
end)

-- Controles
Hitbox.MouseButton1Click:Connect(function()
    autoRecEnabled = not autoRecEnabled
    Indicator.BackgroundColor3 = autoRecEnabled and Color3.fromRGB(50,220,90) or Color3.new(0,0,0)
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if not processed then
        if input.KeyCode == Enum.KeyCode.P then
            autoRecEnabled = not autoRecEnabled
            Indicator.BackgroundColor3 = autoRecEnabled and Color3.fromRGB(50,220,90) or Color3.new(0,0,0)
        elseif input.KeyCode == Enum.KeyCode.L then
            autoDiveEnabled = true
        end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.L then
        autoDiveEnabled = false
    end
end)
