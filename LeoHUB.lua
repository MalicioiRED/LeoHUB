--[[
=====================================================================
 LeoHUB - Interface do sistema de troca
=====================================================================
 Instalação:
   1) Use o TradeSystem.lua ATUALIZADO (Parte 1 -> Script em
      ServerScriptService). Ele agora cria o RemoteFunction
      "GetInventory", que a interface usa para mostrar seus itens.
   2) Cole ESTE arquivo em um LocalScript chamado "LeoHUB"
      dentro de StarterPlayer > StarterPlayerScripts.
   3) Remova o LocalScript "TradeTest" (os atalhos T/Y/U/K/X dele
      conflitam com a interface).
   4) Test > Clients and Servers > 2 Players > Start.

 Uso: botão "LeoHUB" (ou tecla G) abre a lista de jogadores > Convidar.
      Quem recebe clica em Aceitar. Na janela de troca, clique nos
      itens do inventário para adicionar e no "-" para remover.

 Segurança: esta interface é só visual. Todas as regras (quantidade,
 distância, itens válidos, confirmação dupla) são aplicadas no servidor.
=====================================================================
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local me = Players.LocalPlayer
local playerGui = me:WaitForChild("PlayerGui")
local R = ReplicatedStorage:WaitForChild("TradeRemotes")
local getInventory = R:WaitForChild("GetInventory", 10)
if not getInventory then
	warn("[LeoHUB] GetInventory não encontrado. Atualize o script TradeServer com a versão nova.")
end

--------------------------------------------------------------------
-- Configuração (mantenha igual ao servidor)
--------------------------------------------------------------------
local ITEMS = { "Sword", "Shield", "Potion" } -- mesmos itens da lista TRADABLE
local ICONS = { Sword = "⚔️", Shield = "🛡️", Potion = "🧪" }
local LOCK_DELAY = 2   -- igual a CONFIG.LOCK_DELAY
local MAX_QTY = 99     -- igual a CONFIG.MAX_QTY_PER_ITEM
local INVITE_TIMEOUT = 20

local C = {
	bg = Color3.fromRGB(20, 22, 30),
	panel = Color3.fromRGB(30, 33, 45),
	panel2 = Color3.fromRGB(42, 46, 63),
	accent = Color3.fromRGB(88, 130, 255),
	good = Color3.fromRGB(52, 180, 112),
	bad = Color3.fromRGB(214, 78, 78),
	off = Color3.fromRGB(70, 74, 92),
	text = Color3.fromRGB(235, 238, 250),
	mute = Color3.fromRGB(150, 156, 180),
}

--------------------------------------------------------------------
-- Helpers de UI
--------------------------------------------------------------------
local function new(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function round(obj, r)
	new("UICorner", { CornerRadius = UDim.new(0, r) }, obj)
end

local function label(parent, str, size, pos, opts)
	opts = opts or {}
	return new("TextLabel", {
		BackgroundTransparency = 1,
		Text = str,
		TextColor3 = opts.color or C.text,
		Font = opts.font or Enum.Font.Gotham,
		TextSize = opts.size or 14,
		TextXAlignment = opts.align or Enum.TextXAlignment.Left,
		TextWrapped = opts.wrap or false,
		Size = size,
		Position = pos or UDim2.new(),
	}, parent)
end

local function button(parent, str, color, size, pos)
	local b = new("TextButton", {
		Text = str,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = C.text,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Size = size,
		Position = pos or UDim2.new(),
	}, parent)
	round(b, 8)
	return b
end

local function clear(container)
	for _, c in ipairs(container:GetChildren()) do
		if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
			c:Destroy()
		end
	end
end

local function copy(t)
	local c = {}
	for k, v in pairs(t) do
		c[k] = v
	end
	return c
end

local function offerKey(t)
	local keys = {}
	for id in pairs(t) do
		table.insert(keys, id)
	end
	table.sort(keys)
	local parts = {}
	for _, id in ipairs(keys) do
		parts[#parts + 1] = id .. "=" .. tostring(t[id])
	end
	return table.concat(parts, ";")
end

--------------------------------------------------------------------
-- Estado
--------------------------------------------------------------------
local inventory = {}   -- itens que eu possuo (vindo do servidor)
local myOffer = {}     -- rascunho local da minha oferta
local snap = nil       -- último estado enviado pelo servidor
local lockedUntil = 0
local lastKey = nil
local sending, dirty = false, false
local inviteFromId = nil
local nextInvite = 0

local render -- declarada aqui, definida mais abaixo

--------------------------------------------------------------------
-- Estrutura da interface
--------------------------------------------------------------------
local oldGui = playerGui:FindFirstChild("LeoHUB")
if oldGui then
	oldGui:Destroy()
end

local gui = new("ScreenGui", {
	Name = "LeoHUB",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 50,
}, playerGui)

-- Botão flutuante
local toggleBtn = button(gui, "🔁 LeoHUB", C.accent, UDim2.new(0, 120, 0, 44), UDim2.new(0, 16, 1, -64))

-- Lista de jogadores
local playersPanel = new("Frame", {
	Name = "Players",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 16, 1, -72),
	Size = UDim2.new(0, 260, 0, 270),
	BackgroundColor3 = C.bg,
	BorderSizePixel = 0,
	Visible = false,
}, gui)
round(playersPanel, 12)
new("UIStroke", { Color = C.accent, Thickness = 1.5, Transparency = 0.4 }, playersPanel)
label(playersPanel, "Jogadores", UDim2.new(1, -20, 0, 28), UDim2.new(0, 12, 0, 6), { font = Enum.Font.GothamBold, size = 16 })
local playersList = new("ScrollingFrame", {
	Position = UDim2.new(0, 8, 0, 38),
	Size = UDim2.new(1, -16, 1, -46),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, playersPanel)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, playersList)

-- Aviso (toast)
local toastFrame = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 16),
	Size = UDim2.new(0, 340, 0, 40),
	BackgroundColor3 = C.panel2,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 20,
}, gui)
round(toastFrame, 10)
local toastLabel = label(toastFrame, "", UDim2.new(1, -16, 1, 0), UDim2.new(0, 8, 0, 0), {
	align = Enum.TextXAlignment.Center, font = Enum.Font.GothamMedium, wrap = true,
})
toastLabel.ZIndex = 21

-- Convite recebido
local invitePopup = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -90),
	Size = UDim2.new(0, 340, 0, 100),
	BackgroundColor3 = C.bg,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 15,
}, gui)
round(invitePopup, 12)
new("UIStroke", { Color = C.accent, Thickness = 1.5, Transparency = 0.3 }, invitePopup)
local inviteLabel = label(invitePopup, "", UDim2.new(1, -20, 0, 40), UDim2.new(0, 10, 0, 8), {
	font = Enum.Font.GothamMedium, size = 15, wrap = true, align = Enum.TextXAlignment.Center,
})
local inviteAccept = button(invitePopup, "✔ Aceitar", C.good, UDim2.new(0.5, -15, 0, 34), UDim2.new(0, 10, 1, -44))
local inviteDecline = button(invitePopup, "✖ Recusar", C.bad, UDim2.new(0.5, -15, 0, 34), UDim2.new(0.5, 5, 1, -44))

-- Janela de troca
local tradeFrame = new("Frame", {
	Name = "Trade",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.64, 0.78),
	BackgroundColor3 = C.bg,
	BorderSizePixel = 0,
	Visible = false,
}, gui)
round(tradeFrame, 14)
new("UISizeConstraint", { MinSize = Vector2.new(400, 360), MaxSize = Vector2.new(700, 460) }, tradeFrame)
new("UIStroke", { Color = C.accent, Thickness = 1.5, Transparency = 0.4 }, tradeFrame)

local title = label(tradeFrame, "Troca", UDim2.new(1, -20, 0, 32), UDim2.new(0, 10, 0, 8), {
	font = Enum.Font.GothamBold, size = 20,
})

local function makePanel(pos)
	local f = new("Frame", {
		Position = pos,
		Size = UDim2.new(0.5, -15, 0.36, 0),
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
	}, tradeFrame)
	round(f, 10)
	local header = label(f, "", UDim2.new(1, -96, 0, 24), UDim2.new(0, 10, 0, 4), { font = Enum.Font.GothamBold, size = 14 })
	local chip = label(f, "", UDim2.new(0, 86, 0, 24), UDim2.new(1, -92, 0, 4), { size = 12, align = Enum.TextXAlignment.Right })
	local list = new("ScrollingFrame", {
		Position = UDim2.new(0, 6, 0, 32),
		Size = UDim2.new(1, -12, 1, -38),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, f)
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	return header, chip, list
end

local myHeader, myChip, myList = makePanel(UDim2.new(0, 10, 0, 44))
local thHeader, thChip, thList = makePanel(UDim2.new(0.5, 5, 0, 44))

label(tradeFrame, "Seu inventário (clique para adicionar)", UDim2.new(1, -20, 0, 20), UDim2.new(0, 10, 0.36, 50), {
	color = C.mute, size = 12,
})
local invStrip = new("Frame", {
	Position = UDim2.new(0, 10, 0.36, 72),
	Size = UDim2.new(1, -20, 0, 56),
	BackgroundTransparency = 1,
}, tradeFrame)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, invStrip)

local statusLabel = label(tradeFrame, "", UDim2.new(1, -20, 0, 20), UDim2.new(0, 10, 1, -92), {
	color = C.mute, size = 13, align = Enum.TextXAlignment.Center,
})
local confirmBtn = button(tradeFrame, "✔ Confirmar troca", C.good, UDim2.new(0.6, -15, 0, 44), UDim2.new(0, 10, 1, -58))
local cancelBtn = button(tradeFrame, "✖ Cancelar", C.bad, UDim2.new(0.4, -15, 0, 44), UDim2.new(0.6, 5, 1, -58))

--------------------------------------------------------------------
-- Avisos
--------------------------------------------------------------------
local toastToken = 0
local function toast(msg, color)
	toastToken += 1
	local mine = toastToken
	toastFrame.BackgroundColor3 = color or C.panel2
	toastLabel.Text = msg
	toastFrame.Visible = true
	task.delay(3, function()
		if mine == toastToken then
			toastFrame.Visible = false
		end
	end)
end

--------------------------------------------------------------------
-- Comunicação com o servidor
--------------------------------------------------------------------
local function sendOffer()
	dirty = true
	if sending then
		return
	end
	sending = true
	task.spawn(function()
		while dirty do
			dirty = false
			R.UpdateOffer:FireServer(copy(myOffer))
			task.wait(0.3) -- agrupa cliques rápidos (servidor limita a 4/s)
		end
		sending = false
	end)
end

local function refreshInventory()
	if not getInventory then
		return
	end
	task.spawn(function()
		local ok, inv = pcall(function()
			return getInventory:InvokeServer()
		end)
		if ok and type(inv) == "table" then
			inventory = inv
			render()
		end
	end)
end

local function addItem(id)
	local current = myOffer[id] or 0
	if (inventory[id] or 0) - current <= 0 or current >= MAX_QTY then
		return
	end
	myOffer[id] = current + 1
	lockedUntil = os.clock() + LOCK_DELAY + 0.4
	sendOffer()
	render()
end

local function removeItem(id)
	local q = myOffer[id]
	if not q then
		return
	end
	myOffer[id] = (q > 1) and (q - 1) or nil
	lockedUntil = os.clock() + LOCK_DELAY + 0.4
	sendOffer()
	render()
end

--------------------------------------------------------------------
-- Renderização
--------------------------------------------------------------------
local function fillOffer(list, offer, removable)
	clear(list)
	local any = false
	for _, id in ipairs(ITEMS) do
		local q = offer[id]
		if q then
			any = true
			local row = new("Frame", {
				Size = UDim2.new(1, -6, 0, 30),
				BackgroundColor3 = C.panel2,
				BorderSizePixel = 0,
			}, list)
			round(row, 6)
			label(row, (ICONS[id] or "") .. " " .. id .. "   x" .. q, UDim2.new(1, -44, 1, 0), UDim2.new(0, 8, 0, 0))
			if removable then
				local b = button(row, "−", C.bad, UDim2.new(0, 26, 0, 22), UDim2.new(1, -32, 0.5, -11))
				b.MouseButton1Click:Connect(function()
					removeItem(id)
				end)
			end
		end
	end
	if not any then
		label(list, "(vazio)", UDim2.new(1, 0, 0, 26), nil, { color = C.mute })
	end
end

local function updateConfirmButton()
	if not snap then
		return
	end
	if snap.myAccepted then
		confirmBtn.Text = "↩ Desfazer confirmação"
		confirmBtn.BackgroundColor3 = C.accent
		return
	end
	local remain = lockedUntil - os.clock()
	if remain > 0 then
		confirmBtn.Text = string.format("Aguarde %.1fs", remain)
		confirmBtn.BackgroundColor3 = C.off
	else
		confirmBtn.Text = "✔ Confirmar troca"
		confirmBtn.BackgroundColor3 = C.good
	end
end

render = function()
	if not snap then
		return
	end
	title.Text = "Troca com " .. snap.partner
	myHeader.Text = "Sua oferta"
	thHeader.Text = "Oferta de " .. snap.partner

	fillOffer(myList, myOffer, true)
	fillOffer(thList, snap.theirs, false)

	myChip.Text = snap.myAccepted and "✔ confirmou" or ""
	myChip.TextColor3 = C.good
	thChip.Text = snap.theirAccepted and "✔ confirmou" or ""
	thChip.TextColor3 = C.good

	-- inventário
	clear(invStrip)
	for _, id in ipairs(ITEMS) do
		local avail = (inventory[id] or 0) - (myOffer[id] or 0)
		local b = button(invStrip, (ICONS[id] or "") .. " " .. id .. "\nx" .. avail, avail > 0 and C.panel2 or C.off, UDim2.new(0, 100, 1, 0))
		b.TextSize = 13
		b.TextTransparency = avail > 0 and 0 or 0.5
		b.MouseButton1Click:Connect(function()
			addItem(id)
		end)
	end

	if snap.myAccepted and snap.theirAccepted then
		statusLabel.Text = "Finalizando..."
	elseif snap.myAccepted then
		statusLabel.Text = "Você confirmou. Aguardando " .. snap.partner .. "..."
	elseif snap.theirAccepted then
		statusLabel.Text = snap.partner .. " confirmou. Sua vez!"
	else
		statusLabel.Text = "Monte a oferta e confirme quando estiver pronto."
	end
	updateConfirmButton()
end

--------------------------------------------------------------------
-- Lista de jogadores
--------------------------------------------------------------------
local function refreshPlayers()
	clear(playersList)
	local count = 0
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= me then
			count += 1
			local row = new("Frame", {
				Size = UDim2.new(1, -6, 0, 38),
				BackgroundColor3 = C.panel,
				BorderSizePixel = 0,
			}, playersList)
			round(row, 8)
			label(row, p.DisplayName, UDim2.new(1, -96, 1, 0), UDim2.new(0, 10, 0, 0), { font = Enum.Font.GothamMedium })
			local b = button(row, "Convidar", C.accent, UDim2.new(0, 76, 0, 28), UDim2.new(1, -82, 0.5, -14))
			b.TextSize = 13
			b.MouseButton1Click:Connect(function()
				if snap then
					toast("Você já está em uma troca", C.bad)
					return
				end
				if os.clock() < nextInvite then
					toast("Aguarde um pouco antes de convidar de novo", C.bad)
					return
				end
				nextInvite = os.clock() + 3
				R.Request:FireServer(p.UserId)
				toast("Convite enviado para " .. p.DisplayName)
			end)
		end
	end
	if count == 0 then
		label(playersList, "Nenhum outro jogador no servidor.", UDim2.new(1, 0, 0, 40), nil, { color = C.mute, wrap = true })
	end
end

local function togglePlayers()
	playersPanel.Visible = not playersPanel.Visible
	if playersPanel.Visible then
		refreshPlayers()
	end
end

toggleBtn.MouseButton1Click:Connect(togglePlayers)
UserInputService.InputBegan:Connect(function(input, gpe)
	if not gpe and input.KeyCode == Enum.KeyCode.G then
		togglePlayers()
	end
end)
Players.PlayerAdded:Connect(function()
	if playersPanel.Visible then refreshPlayers() end
end)
Players.PlayerRemoving:Connect(function()
	task.defer(function()
		if playersPanel.Visible then refreshPlayers() end
	end)
end)

--------------------------------------------------------------------
-- Convites
--------------------------------------------------------------------
local inviteToken = 0
local function hideInvite()
	inviteToken += 1
	invitePopup.Visible = false
	inviteFromId = nil
end

inviteAccept.MouseButton1Click:Connect(function()
	if inviteFromId then
		R.Respond:FireServer(inviteFromId, true)
	end
	hideInvite()
end)
inviteDecline.MouseButton1Click:Connect(hideInvite) -- o convite expira sozinho no servidor

--------------------------------------------------------------------
-- Botões da janela de troca
--------------------------------------------------------------------
confirmBtn.MouseButton1Click:Connect(function()
	if not snap then
		return
	end
	if not snap.myAccepted and os.clock() < lockedUntil then
		toast("Aguarde alguns segundos antes de confirmar", C.bad)
		return
	end
	R.Accept:FireServer(not snap.myAccepted)
end)

cancelBtn.MouseButton1Click:Connect(function()
	R.Cancel:FireServer()
end)

RunService.Heartbeat:Connect(function()
	if tradeFrame.Visible then
		updateConfirmButton()
	end
end)

--------------------------------------------------------------------
-- Eventos vindos do servidor
--------------------------------------------------------------------
R.Notify.OnClientEvent:Connect(function(kind, data)
	if kind == "Incoming" then
		if type(data) ~= "table" or type(data.userId) ~= "number" or type(data.name) ~= "string" then
			return
		end
		inviteToken += 1
		local mine = inviteToken
		inviteFromId = data.userId
		inviteLabel.Text = data.name .. " quer trocar itens com você"
		invitePopup.Visible = true
		task.delay(INVITE_TIMEOUT, function()
			if mine == inviteToken then
				hideInvite()
			end
		end)

	elseif kind == "Started" then
		hideInvite()
		playersPanel.Visible = false
		myOffer = {}
		lockedUntil = os.clock() + LOCK_DELAY
		tradeFrame.Visible = true
		refreshInventory()
		render()

	elseif kind == "Ended" then
		tradeFrame.Visible = false
		snap = nil
		myOffer = {}
		lastKey = nil
		toast(type(data) == "string" and data or "Troca encerrada", C.panel2)
		refreshInventory()

	elseif kind == "Error" then
		toast(type(data) == "string" and data or "Erro", C.bad)
		if data == "Oferta inválida" and snap then
			myOffer = copy(snap.mine) -- volta ao último estado aceito pelo servidor
			render()
		end
	end
end)

R.State.OnClientEvent:Connect(function(s)
	if type(s) ~= "table" or type(s.mine) ~= "table" or type(s.theirs) ~= "table" then
		return
	end
	local key = offerKey(s.mine) .. "|" .. offerKey(s.theirs)
	if key ~= lastKey then
		lastKey = key
		lockedUntil = os.clock() + LOCK_DELAY + 0.2
	end
	snap = s
	if not sending then
		myOffer = copy(s.mine) -- servidor é a fonte da verdade
	end
	render()
end)

refreshInventory()
