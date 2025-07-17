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
local NEUTRAL_CONFIRMATION_TIME = 0.25  -- 100 ms

-- Variables para bloqueo
local lastBlockTime = 0
local BLOCK_COOLDOWN = 4  -- 4 segundos para seguimiento post-bloqueo

-- Definición de redes
local NETS = {
    {
        Position = Vector3.new(-100, 5.6, 0),
        Size = Vector3.new(52, 10.2, 0.3)
    },
    {
        Position = Vector3.new(0, 5.6, 0),
        Size = Vector3.new(52, 10.2, 0.3)
    },
    {
        Position = Vector3.new(100, 5.6, 0),
        Size = Vector3.new(52, 10.2, 0.3)
    }
}

-- Definición de courts (canchas)
local COURTS = {
    {
        Position = Vector3.new(-100, 0.5, 0),
        Size = Vector3.new(48, 0.2, 95)
    },
    {
        Position = Vector3.new(0, 0.5, 0),
        Size = Vector3.new(48, 0.2, 95)
    },
    {
        Position = Vector3.new(100, 0.5, 0),
        Size = Vector3.new(48, 0.2, 95)
    }
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
    
    local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
    if not humanoidRootPart then return nil end
    
    local playerZ = humanoidRootPart.Position.Z
    
    if playerZ >= 0.1 then
        return 1  -- Lado positivo
    elseif playerZ <= -0.1 then
        return -1 -- Lado negativo
    else
        return nil
    end
end

-- Función para encontrar la court del jugador
local function GetPlayerCourt()
    local character = PLAYER.Character
    if not character then return nil end
    
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return nil end
    
    local playerPos = rootPart.Position
    local closestCourt = nil
    local minDistance = math.huge
    
    for _, court in ipairs(COURTS) do
        local distance = (playerPos - court.Position).Magnitude
        if distance < minDistance then
            minDistance = distance
            closestCourt = court
        end
    end
    
    return closestCourt
end

-- Función para verificar si un punto está en la court
local function IsPointInCourt(court, point)
    local halfSize = court.Size / 2
    local minX = court.Position.X - halfSize.X
    local maxX = court.Position.X + halfSize.X
    local minZ = court.Position.Z - halfSize.Z
    local maxZ = court.Position.Z + halfSize.Z
    
    return point.X >= minX and point.X <= maxX and point.Z >= minZ and point.Z <= maxZ
end

-- Función para verificar bloqueos recientes
local function IsBlockActive()
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        if character then
            local blockHitbox = character:FindFirstChild("BlockHitbox")
            if blockHitbox and blockHitbox:FindFirstChild("Block") then
                lastBlockTime = tick()
                return true
            end
        end
    end
    return (tick() - lastBlockTime) < BLOCK_COOLDOWN
end

-- Física de redes MEJORADA
local function CheckNetCollision(startPos, velocity, initialLandingPos, timeToLand)
    local gravity = Workspace.Gravity
    local acceleration = Vector3.new(0, -gravity, 0)
    local earliestHit = {
        time = timeToLand,
        position = initialLandingPos
    }
    
    for _, net in ipairs(NETS) do
        local halfSize = net.Size / 2
        local minBounds = net.Position - halfSize
        local maxBounds = net.Position + halfSize
        
        if velocity.X ~= 0 or velocity.Z ~= 0 then
            local t_x1 = (minBounds.X - startPos.X) / velocity.X
            local t_x2 = (maxBounds.X - startPos.X) / velocity.X
            local t_z1 = (minBounds.Z - startPos.Z) / velocity.Z
            local t_z2 = (maxBounds.Z - startPos.Z) / velocity.Z
            
            local t_x_min = math.min(t_x1, t_x2)
            local t_x_max = math.max(t_x1, t_x2)
            local t_z_min = math.min(t_z1, t_z2)
            local t_z_max = math.max(t_z1, t_z2)
            
            local t_start = math.max(t_x_min, t_z_min, 0)
            local t_end = math.min(t_x_max, t_z_max, timeToLand)
            
            if t_start <= t_end then
                local t_mid = (t_start + t_end) / 2
                local y_pos = startPos.Y + velocity.Y * t_mid + 0.5 * acceleration.Y * t_mid^2
                
                if y_pos >= minBounds.Y and y_pos <= maxBounds.Y then
                    local hitPos = Vector3.new(
                        startPos.X + velocity.X * t_mid,
                        y_pos,
                        startPos.Z + velocity.Z * t_mid
                    )
                    
                    if t_mid < earliestHit.time then
                        earliestHit.time = t_mid
                        earliestHit.position = hitPos
                    end
                end
            end
        end
    end
    
    return earliestHit.position
end

-- Física de impacto CORREGIDA
local function CalculateLanding(velocity, position)
    local gravity = Workspace.Gravity
    local acceleration = Vector3.new(0, -gravity, 0)
    
    -- Ecuación: 0 = position.Y + velocity.Y * t + 0.5 * acceleration.Y * t^2
    local a = 0.5 * acceleration.Y
    local b = velocity.Y
    local c = position.Y
    
    local discriminant = b^2 - 4*a*c
    if discriminant < 0 then
        return position -- No hay solución real, devolvemos la posición actual
    end
    
    local t1 = (-b + math.sqrt(discriminant)) / (2*a)
    local t2 = (-b - math.sqrt(discriminant)) / (2*a)
    local timeToLand = math.max(t1, t2)  -- Tomamos el tiempo positivo más grande
    
    -- Calculamos la posición de aterrizaje en el plano horizontal
    local landingPos = Vector3.new(
        position.X + velocity.X * timeToLand,
        0,  -- Asumimos que el suelo está en Y=0
        position.Z + velocity.Z * timeToLand
    )
    
    -- Verificamos colisión con redes
    landingPos = CheckNetCollision(position, velocity, landingPos, timeToLand)
    
    return landingPos
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
    local character = PLAYER.Character
    if not character then return end
    
    local humanoid = character:FindFirstChild("Humanoid")
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not rootPart then return end
    
    -- Calcular dirección hacia el objetivo
    local worldDirection = (targetPosition - rootPart.Position)
    local flatDirection = Vector3.new(worldDirection.X, 0, worldDirection.Z).Unit
    
    -- Calcular ángulo (0-360 grados)
    local angle = math.deg(math.atan2(flatDirection.Z, flatDirection.X))
    if angle < 0 then angle = angle + 360 end
    
    -- Seleccionar ángulo fijo más cercano (múltiplo de 45°)
    local fixedAngles = {0, 45, 90, 135, 180, 225, 270, 315}
    local closestAngle = fixedAngles[1]
    local minDiff = math.abs(angle - closestAngle)
    
    for _, fixedAngle in ipairs(fixedAngles) do
        local diff = math.abs(angle - fixedAngle)
        if diff < minDiff then
            minDiff = diff
            closestAngle = fixedAngle
        end
    end
    
    -- Convertir ángulo a vector de movimiento
    local angleRad = math.rad(closestAngle)
    local moveDirection = Vector3.new(math.cos(angleRad), 0, math.sin(angleRad)).Unit
    
    -- Aplicar movimiento
    humanoid:Move(moveDirection * 2, false)
end

local function TriggerDive()
    if tick() - lastDiveTime < DIVE_COOLDOWN then return end
    lastDiveTime = tick()
    
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.three, false, game)
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.three, false, game)
end

local function ExecuteDiveAction(targetPosition)
    local character = PLAYER.Character
    if not character then return end
    
    local humanoid = character:FindFirstChild("Humanoid")
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not rootPart then return end
    
    local distance = (targetPosition - rootPart.Position).Magnitude
    
    -- Movimiento solo dentro del radio de seguimiento
    if distance <= DIVE_TRACKING_RADIUS then
        MoveToPosition(targetPosition)
    end
    
    -- Buceo solo dentro del radio de acción
    if distance <= DIVE_ACTION_RADIUS then
        TriggerDive()
    end
end

-- =====================================================================
-- LÓGICA PRINCIPAL (CON DETECCIÓN DE MANIPULACIÓN Y FILTRO DE BALONES)
-- =====================================================================
RunService:BindToRenderStep("CombinedSystem", Enum.RenderPriority.Camera.Value, function()
    local courtSide = GetCourtSide()
    if not courtSide then return end
    
    -- Obtener la court del jugador
    local playerCourt = GetPlayerCourt()
    if not playerCourt then return end
    
    -- Verificar si hay un bloqueo activo o reciente (4 segundos)
    local blockActive = IsBlockActive()
    
    for _, ballModel in ipairs(Workspace:GetChildren()) do
        if ballModel:IsA("Model") and ballModel.Name == "Ball" then
            -- Ignorar balones con Marker
            if ballModel:FindFirstChild("Marker") then
                continue
            end
            
            local ball = ballModel:FindFirstChild("BallPart")
            local velocityObj = ballModel:FindFirstChild("Velocity")
            
            if ball and velocityObj then
                local ballPosition = ball.Position
                local velocity = velocityObj.Value
                
                -- Calcular posición de impacto con detección de redes
                local landingPos = CalculateLanding(velocity, ballPosition)
                
                -- 1. Detectar manipulación (cambio brusco en el Marker)
                local lastPos = lastMarkerPositions[ballModel]
                local isManipulated = false
                
                if lastPos then
                    -- Calcular distancia entre la última posición del Marker y la nueva
                    local distance = (landingPos - lastPos).Magnitude
                    
                    -- Si el cambio es mayor al umbral, detectamos manipulación
                    if distance > manipulationThreshold then
                        isManipulated = true
                        
                        -- Registrar la posición del balón JUSTO ANTES del cambio como origen
                        hitOrigins[ballModel] = ballPosition
                    end
                else
                    -- Primera detección: inicializar con posición actual
                    lastMarkerPositions[ballModel] = landingPos
                end
                
                -- Guardar posición actual para la próxima comparación
                lastMarkerPositions[ballModel] = landingPos
                
                -- 2. Determinar territorio de caída
                local isLandingOnOurSide = false
                if courtSide == 1 then
                    isLandingOnOurSide = landingPos.Z >= 0.35
                else
                    isLandingOnOurSide = landingPos.Z <= -0.35
                end
                
                -- 3. Determinar origen territorial
                local isFromOpponent = false
                local originZ = ballPosition.Z -- Valor por defecto
                
                -- Usar origen registrado si está disponible
                if hitOrigins[ballModel] then
                    originZ = hitOrigins[ballModel].Z
                end
                
                -- 4. Sistema de confirmación para zona neutral
                local ballId = tostring(ballModel:GetDebugId())
                if not neutralZoneTimers[ballId] then
                    neutralZoneTimers[ballId] = {
                        inNeutral = false,
                        startTime = nil,
                        confirmed = false
                    }
                end
                
                local currentIsNeutral = (ballPosition.Z > -0.35) and (ballPosition.Z < 0.35)
                
                -- Lógica de confirmación
                if currentIsNeutral then
                    if not neutralZoneTimers[ballId].inNeutral then
                        neutralZoneTimers[ballId].inNeutral = true
                        neutralZoneTimers[ballId].startTime = tick()
                        neutralZoneTimers[ballId].confirmed = false
                    elseif not neutralZoneTimers[ballId].confirmed then
                        if tick() - neutralZoneTimers[ballId].startTime > NEUTRAL_CONFIRMATION_TIME then
                            neutralZoneTimers[ballId].confirmed = true
                        end
                    end
                else
                    neutralZoneTimers[ballId].inNeutral = false
                    neutralZoneTimers[ballId].confirmed = false
                end
                
                local isNeutralZone = neutralZoneTimers[ballId].confirmed
                
                -- 5. Lógica para determinar si viene del oponente
                if isNeutralZone then
                    -- Si es zona neutral, considerar como oponente si cae en nuestro lado
                    isFromOpponent = isLandingOnOurSide
                else
                    -- Lógica para zonas definidas
                    if courtSide == 1 then
                        isFromOpponent = originZ < -0.01
                    else
                        isFromOpponent = originZ > 0.01
                    end
                end
                
                -- 6. Verificar si el balón cae dentro de la court
                local isInCourt = IsPointInCourt(playerCourt, landingPos)
                
                -- 7. Combinar condiciones con prioridad de bloqueo
                local shouldProcess = false
                
                -- Prioridad 1: Si hay bloqueo reciente y cae en nuestro lado
                if blockActive and isLandingOnOurSide then
                    shouldProcess = true
                -- Prioridad 2: Lógica normal (viene del oponente y cae en nuestro lado dentro de la court)
                else
                    shouldProcess = isFromOpponent and isLandingOnOurSide and isInCourt
                end
                
                Marker.CFrame = CFrame.new(landingPos)
                
                -- AutoRec
                if autoRecEnabled and shouldProcess then
                    local rootPart = PLAYER.Character and PLAYER.Character.PrimaryPart
                    if rootPart and (landingPos - rootPart.Position).Magnitude <= MARKER_RADIUS then
                        if tick() - lastMoveTime >= MOVE_COOLDOWN then
                            PLAYER.Character.Humanoid:MoveTo(landingPos)
                            lastMoveTime = tick()
                        end
                    end
                end
                
                -- AutoDive
                if autoDiveEnabled and shouldProcess then
                    local rootPart = PLAYER.Character and PLAYER.Character.PrimaryPart
                    if rootPart and (landingPos - rootPart.Position).Magnitude <= DIVE_TRACKING_RADIUS then
                        ExecuteDiveAction(landingPos)
                    end
                end
            end
        else
            -- Limpiar datos si el balón fue removido
            lastMarkerPositions[ballModel] = nil
            hitOrigins[ballModel] = nil
            neutralZoneTimers[tostring(ballModel:GetDebugId())] = nil
        end
    end
end)

-- Controles
Hitbox.MouseButton1Click:Connect(function()
    autoRecEnabled = not autoRecEnabled
    Indicator.BackgroundColor3 = autoRecEnabled and Color3.fromRGB(50, 220, 90) or Color3.new(0, 0, 0)
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if not processed then
        if input.KeyCode == Enum.KeyCode.P then
            autoRecEnabled = not autoRecEnabled
            Indicator.BackgroundColor3 = autoRecEnabled and Color3.fromRGB(50, 220, 90) or Color3.new(0, 0, 0)
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
