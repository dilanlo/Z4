--==================================================
-- Z4 FULL | ACTIVE TIMELINE
-- Delta Executor | Android | R6 + R15
--==================================================

if _G.Z4_RUNNING then
    warn("Z4 sudah aktif!")
    return
end
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local Player = Players.LocalPlayer
local FILE = "Z4_Recording.json"

-- SETTINGS
local SAMPLE_INTERVAL = 0.05
local MOVE_THRESHOLD = 0.12
local DEFAULT_SPEED = 1

-- STATE
local Character, Humanoid, Root, Animator
local Frames = {}
local Recording = false
local Playing = false
local Paused = false
local PlaybackSpeed = DEFAULT_SPEED
local ActiveTime = 0
local PlaybackTime = 0
local LastSample = 0
local LastTickTime = 0
local LastState = ""
local LastAnimSignature = ""
local LastMoving = false
local LastPosition
local SelectedFrame = 1
local BeforeFallFrame = 1
local CurrentAnimSignature = ""
local PlaybackTracks = {}
local PlaybackTrackSpeeds = {}
local Loop = false

local function CharacterSetup()
    Character = Player.Character or Player.CharacterAdded:Wait()
    Humanoid = Character:WaitForChild("Humanoid")
    Root = Character:WaitForChild("HumanoidRootPart")

    Animator = Humanoid:FindFirstChildOfClass("Animator")
    if not Animator then
        Animator = Instance.new("Animator")
        Animator.Parent = Humanoid
    end
end

CharacterSetup()

Player.CharacterAdded:Connect(function()
    task.wait(1)
    CharacterSetup()
end)

local function GetState()
    return Humanoid:GetState().Name
end

local function GetAnimations()
    local result = {}

    if not Animator then
        return result
    end

    for _, track in ipairs(Animator:GetPlayingAnimationTracks()) do
        local animation = track.Animation

        if animation and animation.AnimationId ~= "" then
            table.insert(result, {
                id = animation.AnimationId,
                time = track.TimePosition,
                speed = track.Speed,
                weight = track.WeightCurrent,
                looped = track.Looped
            })
        end
    end

    return result
end

local function GetAnimSignature(anims)
    local ids = {}

    for _, anim in ipairs(anims) do
        table.insert(ids, anim.id)
    end

    table.sort(ids)
    return table.concat(ids, "|")
end

local function IsMoving()
    if not Humanoid or not Root then
        return false
    end

    local state = Humanoid:GetState()

    if state == Enum.HumanoidStateType.Jumping
        or state == Enum.HumanoidStateType.Freefall
        or state == Enum.HumanoidStateType.FallingDown then
        return true
    end

    return Humanoid.MoveDirection.Magnitude > 0.03
        or Root.AssemblyLinearVelocity.Magnitude > MOVE_THRESHOLD
end

local function IsFalling()
    local state = Humanoid:GetState()

    return state == Enum.HumanoidStateType.Freefall
        or state == Enum.HumanoidStateType.FallingDown
end

local function Capture(force)
    if not Recording or not Root or not Humanoid then
        return
    end

    local now = os.clock()
    local deltaTime = math.max(0, now - (LastTickTime > 0 and LastTickTime or now))
    LastTickTime = now

    local moving = IsMoving()
    local state = GetState()
    local cf = Root.CFrame
    local anims = GetAnimations()
    local animSignature = GetAnimSignature(anims)

    local stateChanged = state ~= LastState
    local animChanged = animSignature ~= LastAnimSignature

    -- Simpan frame sebelum memasuki kondisi jatuh.
    if IsFalling() and not LastMoving and #Frames > 0 then
        BeforeFallFrame = #Frames
    elseif not IsFalling() and #Frames > 0 then
        BeforeFallFrame = #Frames
    end

    -- Waktu aktif hanya berjalan ketika karakter bergerak.
    -- Waktu diam tidak masuk timeline playback.
    if moving then
        ActiveTime += math.min(deltaTime, 0.1)
    end

    local shouldCapture = force
        or stateChanged
        or animChanged
        or (moving and now - LastSample >= SAMPLE_INTERVAL)

    if not shouldCapture then
        LastState = state
        LastAnimSignature = animSignature
        LastMoving = moving
        return
    end

    local frame = {
        t = ActiveTime,
        cf = {cf:GetComponents()},
        state = state,
        moving = moving,
        animations = anims
    }

    -- Hindari frame identik yang tidak diperlukan.
    local previous = Frames[#Frames]

    if previous then
        local oldCF = CFrame.new(table.unpack(previous.cf))
        local distance = (oldCF.Position - cf.Position).Magnitude

        if distance < 0.001
            and previous.state == state
            and GetAnimSignature(previous.animations) == animSignature
            and not force then

            LastSample = now
            LastState = state
            LastAnimSignature = animSignature
            LastMoving = moving
            return
        end
    end

    table.insert(Frames, frame)
    SelectedFrame = #Frames

    LastSample = now
    LastState = state
    LastAnimSignature = animSignature
    LastMoving = moving
    LastPosition = cf.Position
end

local function StartRecord()
    if Playing then
        warn("Stop playback terlebih dahulu.")
        return
    end

    table.clear(Frames)

    Recording = true
    ActiveTime = 0
    LastSample = os.clock()
    LastTickTime = LastSample
    LastState = ""
    LastAnimSignature = ""
    LastMoving = false
    BeforeFallFrame = 1
    SelectedFrame = 1

    Capture(true)
    print("Z4: Recording started")
end

local function StopRecord()
    if not Recording then
        return
    end

    Capture(true)
    Recording = false

    print("Z4: Recording stopped")
    print("Frames:", #Frames, "Active time:", ActiveTime)
end

local function GetCF(frame)
    return CFrame.new(table.unpack(frame.cf))
end

local function FindFrames(time)
    local left = 1
    local right = #Frames

    while left < right do
        local middle = math.floor((left + right) / 2)

        if Frames[middle].t <= time then
            left = middle + 1
        else
            right = middle
        end
    end

    local b = math.clamp(left, 1, #Frames)
    local a = math.max(1, b - 1)

    if Frames[b].t <= time then
        a = b
    end

    return a, b
end

local function StopTracks()
    for _, track in ipairs(PlaybackTracks) do
        pcall(function()
            track:Stop(0.1)
            track:Destroy()
        end)
    end

    table.clear(PlaybackTracks)
    table.clear(PlaybackTrackSpeeds)
    CurrentAnimSignature = ""
end

local function ApplyAnimations(frame)
    if not Animator or not frame then
        return
    end

    local anims = frame.animations or {}
    local signature = GetAnimSignature(anims)

    if signature == CurrentAnimSignature then
        return
    end

    StopTracks()
    CurrentAnimSignature = signature

    for _, data in ipairs(anims) do
        pcall(function()
            local animation = Instance.new("Animation")
            animation.AnimationId = data.id

            local track = Animator:LoadAnimation(animation)

            track.Looped = data.looped
            track:Play(0.1, data.weight or 1, data.speed or 1)

            pcall(function()
                track.TimePosition = data.time or 0
            end)

            table.insert(PlaybackTracks, track)
            PlaybackTrackSpeeds[track] = data.speed or 1
        end)
    end
end

local function StopPlay()
    Playing = false
    Paused = false
    StopTracks()
end

local function PlayFrom(index)
    if Recording then
        StopRecord()
    end

    if #Frames < 2 then
        warn("Rekaman belum cukup.")
        return
    end

    index = math.clamp(
        math.floor(tonumber(index) or 1),
        1,
        #Frames
    )

    SelectedFrame = index
    PlaybackTime = Frames[index].t

    StopTracks()

    Playing = true
    Paused = false
    ApplyAnimations(Frames[index])

    print("Z4: Playing from frame", index)
end

local function ReturnBeforeFall()
    if #Frames == 0 or not Root then
        return
    end

    local index = math.clamp(BeforeFallFrame, 1, #Frames)

    SelectedFrame = index
    Root.CFrame = GetCF(Frames[index])
    Root.AssemblyLinearVelocity = Vector3.zero
    Root.AssemblyAngularVelocity = Vector3.zero

    print("Z4: Returned to frame", index)
end

-- PLAYBACK
RunService.Heartbeat:Connect(function(dt)
    if Recording then
        Capture(false)
        return
    end

    if not Playing or Paused or #Frames < 2 then
        return
    end

    -- Speed 1 = kecepatan timeline aktif asli.
    PlaybackTime += dt * PlaybackSpeed

    local firstTime = Frames[1].t
    local lastTime = Frames[#Frames].t

    if PlaybackTime >= lastTime then
        if Loop then
            PlaybackTime = firstTime
            StopTracks()
            SelectedFrame = 0
        else
            Root.CFrame = GetCF(Frames[#Frames])
            StopPlay()
            print("Z4: Playback finished")
            return
        end
    end

    local a, b = FindFrames(PlaybackTime)
    local fa = Frames[a]
    local fb = Frames[b]

    local alpha = 0

    if a ~= b then
        local span = fb.t - fa.t

        if span > 0 then
            alpha = math.clamp(
                (PlaybackTime - fa.t) / span,
                0,
                1
            )
        end
    end

    Root.CFrame = GetCF(fa):Lerp(GetCF(fb), alpha)

    if SelectedFrame ~= a then
        SelectedFrame = a
        ApplyAnimations(fa)
    end
end)

-- SAVE
local function SaveData()
    if #Frames == 0 then
        warn("Tidak ada rekaman.")
        return
    end

    local data = {
        version = 1,
        rig = Humanoid.RigType.Name,
        activeTime = ActiveTime,
        beforeFallFrame = BeforeFallFrame,
        frames = Frames
    }

    local ok, err = pcall(function()
        assert(writefile, "writefile tidak tersedia")
        writefile(FILE, HttpService:JSONEncode(data))
    end)

    if ok then
        print("Z4: Saved", FILE)
    else
        warn("Z4 Save error:", err)
    end
end

-- LOAD
local function LoadData()
    local ok, data = pcall(function()
        assert(readfile and isfile, "File API tidak tersedia")
        assert(isfile(FILE), "File tidak ditemukan")
        return HttpService:JSONDecode(readfile(FILE))
    end)

    if not ok or type(data) ~= "table"
        or type(data.frames) ~= "table" then
        warn("Z4: Gagal memuat rekaman:", data)
        return
    end

    StopPlay()
    Recording = false

    Frames = data.frames
    ActiveTime = data.activeTime or 0
    BeforeFallFrame = data.beforeFallFrame or 1
    SelectedFrame = 1

    print("Z4: Loaded", #Frames, "frames")
end

--==================================================
-- GUI
--==================================================

local GuiParent = nil
if type(gethui) == "function" then
    local ok, hiddenGui = pcall(gethui)
    if ok then
        GuiParent = hiddenGui
    end
end
GuiParent = GuiParent or Player:WaitForChild("PlayerGui")

local oldGui = GuiParent:FindFirstChild("Z4_GUI")
if oldGui then
    oldGui:Destroy()
end

local Gui = Instance.new("ScreenGui")
Gui.Name = "Z4_GUI"
Gui.ResetOnSpawn = false
Gui.Parent = GuiParent

local Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(250, 285)
Main.Position = UDim2.new(0, 18, 0.35, 0)
Main.BackgroundColor3 = Color3.fromRGB(20, 23, 31)
Main.BorderSizePixel = 0
Main.Parent = Gui

local function Corner(obj, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 9)
    c.Parent = obj
end

Corner(Main, 12)

local Stroke = Instance.new("UIStroke")
Stroke.Color = Color3.fromRGB(55, 65, 85)
Stroke.Transparency = 0.3
Stroke.Parent = Main

local function Label(parent, text, size, pos, color)
    local obj = Instance.new("TextLabel")
    obj.Size = size
    obj.Position = pos
    obj.BackgroundTransparency = 1
    obj.Text = text
    obj.TextColor3 = color or Color3.fromRGB(235, 238, 245)
    obj.TextSize = 12
    obj.Font = Enum.Font.Gotham
    obj.Parent = parent
    return obj
end

local function Button(parent, text, size, pos, callback, color)
    local obj = Instance.new("TextButton")
    obj.Size = size
    obj.Position = pos
    obj.BackgroundColor3 = color or Color3.fromRGB(43, 50, 65)
    obj.TextColor3 = Color3.fromRGB(245, 247, 255)
    obj.Text = text
    obj.TextSize = 11
    obj.Font = Enum.Font.GothamSemibold
    obj.BorderSizePixel = 0
    obj.AutoButtonColor = true
    obj.Parent = parent

    Corner(obj, 7)
    obj.MouseButton1Click:Connect(callback)

    return obj
end

-- HEADER
local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 42)
Header.BackgroundColor3 = Color3.fromRGB(29, 35, 48)
Header.BorderSizePixel = 0
Header.Parent = Main
Corner(Header, 12)

Label(
    Header,
    "Z4",
    UDim2.fromOffset(35, 32),
    UDim2.fromOffset(12, 4),
    Color3.fromRGB(90, 160, 255)
).Font = Enum.Font.GothamBlack

Label(
    Header,
    "FULL RECORDER",
    UDim2.fromOffset(130, 30),
    UDim2.fromOffset(48, 5),
    Color3.fromRGB(220, 225, 238)
).Font = Enum.Font.GothamBold

local Dock
Dock = Button(
    Gui,
    "Z4",
    UDim2.fromOffset(44, 44),
    UDim2.new(0, 12, 0.45, 0),
    function()
        Main.Visible = true
        Dock.Visible = false
    end,
    Color3.fromRGB(35, 105, 205)
)
Dock.Visible = false
Dock.TextSize = 14

Button(
    Header,
    "—",
    UDim2.fromOffset(28, 25),
    UDim2.new(1, -34, 0, 8),
    function()
        Main.Visible = false
        Dock.Visible = true
    end
)

-- STATUS
local Status = Label(
    Main,
    "● READY",
    UDim2.new(1, -20, 0, 20),
    UDim2.fromOffset(10, 48),
    Color3.fromRGB(100, 190, 130)
)

local Info = Label(
    Main,
    "Frames: 0 | Active: 0.00s",
    UDim2.new(1, -20, 0, 18),
    UDim2.fromOffset(10, 68),
    Color3.fromRGB(155, 165, 185)
)

-- RECORD
Button(
    Main,
    "● RECORD",
    UDim2.new(0.48, -5, 0, 31),
    UDim2.fromOffset(10, 94),
    StartRecord,
    Color3.fromRGB(155, 49, 64)
)

Button(
    Main,
    "■ STOP",
    UDim2.new(0.48, -5, 0, 31),
    UDim2.new(0.52, 0, 0, 94),
    StopRecord
)

-- PLAYBACK
Button(
    Main,
    "▶ PLAY",
    UDim2.new(0.48, -5, 0, 31),
    UDim2.fromOffset(10, 132),
    function()
        PlayFrom(1)
    end,
    Color3.fromRGB(38, 100, 185)
)

Button(
    Main,
    "Ⅱ PAUSE",
    UDim2.new(0.48, -5, 0, 31),
    UDim2.new(0.52, 0, 0, 132),
    function()
        if Playing then
            Paused = not Paused
            for _, track in ipairs(PlaybackTracks) do
                pcall(function()
                    track:AdjustSpeed(Paused and 0 or (PlaybackTrackSpeeds[track] or 1))
                end)
            end
        end
    end
)

-- FRAME INPUT
Label(
    Main,
    "PLAY FROM FRAME",
    UDim2.new(1, -20, 0, 17),
    UDim2.fromOffset(10, 172),
    Color3.fromRGB(155, 165, 185)
)

local FrameInput = Instance.new("TextBox")
FrameInput.Size = UDim2.new(1, -20, 0, 28)
FrameInput.Position = UDim2.fromOffset(10, 190)
FrameInput.BackgroundColor3 = Color3.fromRGB(36, 42, 55)
FrameInput.TextColor3 = Color3.new(1, 1, 1)
FrameInput.PlaceholderText = "Nomor frame"
FrameInput.Text = "1"
FrameInput.ClearTextOnFocus = false
FrameInput.Font = Enum.Font.Gotham
FrameInput.TextSize = 12
FrameInput.Parent = Main
Corner(FrameInput, 7)

Button(
    Main,
    "REPEAT FRAME",
    UDim2.new(0.48, -5, 0, 29),
    UDim2.fromOffset(10, 224),
    function()
        PlayFrom(tonumber(FrameInput.Text) or 1)
    end,
    Color3.fromRGB(38, 100, 185)
)

Button(
    Main,
    "BEFORE FALL",
    UDim2.new(0.48, -5, 0, 29),
    UDim2.new(0.52, 0, 0, 224),
    function()
        FrameInput.Text = tostring(BeforeFallFrame)
        ReturnBeforeFall()
    end
)

-- SAVE / LOAD
Button(
    Main,
    "SAVE",
    UDim2.new(0.48, -5, 0, 25),
    UDim2.fromOffset(10, 258),
    SaveData
)

Button(
    Main,
    "LOAD",
    UDim2.new(0.48, -5, 0, 25),
    UDim2.new(0.52, 0, 0, 258),
    LoadData
)

-- DRAG HEADER
local dragging = false
local dragStart
local startPosition

Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        dragging = true
        dragStart = input.Position
        startPosition = Main.Position
    end
end)

UIS.InputChanged:Connect(function(input)
    if dragging and (
        input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
    ) then

        local delta = input.Position - dragStart

        Main.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- GUI UPDATE
RunService.RenderStepped:Connect(function()
    if not Gui.Parent then
        return
    end

    Info.Text = string.format(
        "Frames: %d | Active: %.2fs",
        #Frames,
        ActiveTime
    )

    if Recording then
        Status.Text = "● RECORDING"
        Status.TextColor3 = Color3.fromRGB(255, 100, 115)
    elseif Playing and Paused then
        Status.Text = "Ⅱ PAUSED"
        Status.TextColor3 = Color3.fromRGB(255, 190, 90)
    elseif Playing then
        Status.Text = "▶ PLAYING"
        Status.TextColor3 = Color3.fromRGB(90, 160, 255)
    else
        Status.Text = "● READY"
        Status.TextColor3 = Color3.fromRGB(100, 190, 130)
    end
end)

_G.Z4_RUNNING = true

print("================================")
print("Z4 FULL ACTIVE TIMELINE READY")
print("Rig:", Humanoid.RigType.Name)
print("Default playback speed:", PlaybackSpeed)
print("================================")
