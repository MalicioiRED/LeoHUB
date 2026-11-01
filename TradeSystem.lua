--[[
=====================================================================
 SISTEMA DE TROCA ENTRE JOGADORES - ROBLOX STUDIO
=====================================================================
 Princípio de segurança: o CLIENTE só PEDE, o SERVIDOR decide.
 Nunca confie em nada que vem do cliente (tipos, quantidades, quem é
 o parceiro, se o item existe, se o jogador tem o item).

 Como instalar:
   1) Script  "TradeServer"  -> ServerScriptService   (PARTE 1)
   2) LocalScript "TradeTest" -> StarterPlayerScripts  (PARTE 2)
   3) Studio > Test > Clients and Servers > 2 Players > Start
      (assim você nem precisa logar na conta secundária)
=====================================================================
]]

--=====================================================================
-- PARTE 1: SERVER SCRIPT  (ServerScriptService/TradeServer)
--=====================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CONFIG = {
	REQUEST_COOLDOWN = 3,    -- segundos entre pedidos de troca
	REQUEST_TIMEOUT = 20,    -- tempo para o alvo aceitar o convite
	MAX_DISTANCE = 30,       -- studs (nil para desativar)
	MAX_ITEMS_PER_SIDE = 8,  -- tipos de item diferentes por lado
	MAX_QTY_PER_ITEM = 99,
	LOCK_DELAY = 2,          -- segundos após qualquer mudança até poder aceitar
}

-- Lista branca de itens negociáveis (qualquer outra chave é rejeitada)
local TRADABLE = {
	Sword = true,
	Shield = true,
	Potion = true,
}

-- Remotes criados pelo próprio script
local remotes = Instance.new("Folder")
remotes.Name = "TradeRemotes"
for _, name in ipairs({ "Request", "Respond", "UpdateOffer", "Accept", "Cancel", "Notify", "State" }) do
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
end
local getInv = Instance.new("RemoteFunction")
getInv.Name = "GetInventory" -- usado pela interface LeoHUB para mostrar seus itens
getInv.Parent = remotes

remotes.Parent = ReplicatedStorage

-- Estado (somente no servidor)
local inventories = {} -- [Player] = { [itemId] = qty }  (troque por DataStore no jogo real)
local sessions = {}    -- [Player] = session
local pending = {}     -- [alvo] = { from = Player, expires = número }
local lastCall = {}    -- [Player] = { [chave] = os.clock() }

--------------------------------------------------------------------
-- Utilidades
--------------------------------------------------------------------
local function notify(player, kind, data)
	if player.Parent == Players then
		remotes.Notify:FireClient(player, kind, data)
	end
end

local function throttle(player, key, interval)
	lastCall[player] = lastCall[player] or {}
	local now = os.clock()
	local last = lastCall[player][key]
	if last and now - last < interval then
		return false
	end
	lastCall[player][key] = now
	return true
end

local function closeEnough(a, b)
	if not CONFIG.MAX_DISTANCE then
		return true
	end
	local ra = a.Character and a.Character:FindFirstChild("HumanoidRootPart")
	local rb = b.Character and b.Character:FindFirstChild("HumanoidRootPart")
	if ra and rb then
		return (ra.Position - rb.Position).Magnitude <= CONFIG.MAX_DISTANCE
	end
	return false
end

local function hasItems(player, offer)
	local inv = inventories[player]
	if not inv then
		return false
	end
	for id, qty in pairs(offer) do
		if (inv[id] or 0) < qty then
			return false
		end
	end
	return true
end

-- Valida e copia a oferta vinda do cliente. Retorna nil se qualquer coisa estiver errada.
local function sanitizeOffer(player, raw)
	if type(raw) ~= "table" then
		return nil
	end
	local clean, count = {}, 0
	for id, qty in pairs(raw) do
		if type(id) ~= "string" or not TRADABLE[id] then
			return nil
		end
		-- rejeita NaN, inf, negativos, decimais e valores absurdos
		if type(qty) ~= "number" or qty ~= math.floor(qty) or qty < 1 or qty > CONFIG.MAX_QTY_PER_ITEM then
			return nil
		end
		count += 1
		if count > CONFIG.MAX_ITEMS_PER_SIDE then
			return nil
		end
		clean[id] = qty
	end
	if not hasItems(player, clean) then
		return nil
	end
	return clean
end

local function push(s)
	for _, p in ipairs({ s.a, s.b }) do
		local other = (p == s.a) and s.b or s.a
		if p.Parent == Players then
			remotes.State:FireClient(p, {
				partner = other.Name,
				mine = s.offers[p],
				theirs = s.offers[other],
				myAccepted = s.accepted[p],
				theirAccepted = s.accepted[other],
			})
		end
	end
end

local function endSession(s, reason)
	sessions[s.a] = nil
	sessions[s.b] = nil
	notify(s.a, "Ended", reason)
	notify(s.b, "Ended", reason)
end

-- Troca atômica: revalida tudo no último instante e só então move os itens
local function execute(s)
	if s.executing then
		return
	end
	s.executing = true -- trava contra execução dupla / corrida de eventos

	local a, b = s.a, s.b
	local offA, offB = s.offers[a], s.offers[b]

	if not (hasItems(a, offA) and hasItems(b, offB)) then
		endSession(s, "Troca cancelada: itens indisponíveis")
		return
	end

	local invA, invB = inventories[a], inventories[b]
	for id, qty in pairs(offA) do
		invA[id] -= qty
		invB[id] = (invB[id] or 0) + qty
	end
	for id, qty in pairs(offB) do
		invB[id] -= qty
		invA[id] = (invA[id] or 0) + qty
	end

	print("[Trade] Concluída:", a.Name, "<->", b.Name)
	endSession(s, "Troca concluída!")
end

--------------------------------------------------------------------
-- Handlers dos remotes
--------------------------------------------------------------------
remotes.Request.OnServerEvent:Connect(function(player, targetUserId)
	if not throttle(player, "Request", CONFIG.REQUEST_COOLDOWN) then
		return
	end
	if type(targetUserId) ~= "number" then
		return
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == player then
		return
	end
	if sessions[player] or sessions[target] then
		notify(player, "Error", "Alguém já está em uma troca")
		return
	end
	if not closeEnough(player, target) then
		notify(player, "Error", "Jogador muito longe")
		return
	end
	pending[target] = { from = player, expires = os.clock() + CONFIG.REQUEST_TIMEOUT }
	notify(target, "Incoming", { userId = player.UserId, name = player.Name })
end)

remotes.Respond.OnServerEvent:Connect(function(player, fromUserId, accept)
	if not throttle(player, "Respond", 0.5) then
		return
	end
	local p = pending[player]
	pending[player] = nil
	if not p or os.clock() > p.expires then
		return
	end
	if type(fromUserId) ~= "number" or p.from.UserId ~= fromUserId or accept ~= true then
		return
	end
	local a = p.from
	if a.Parent ~= Players or sessions[a] or sessions[player] then
		return
	end
	if not closeEnough(a, player) then
		return
	end

	local s = {
		a = a,
		b = player,
		offers = { [a] = {}, [player] = {} },
		accepted = { [a] = false, [player] = false },
		lastChange = os.clock(),
		executing = false,
	}
	sessions[a] = s
	sessions[player] = s
	notify(a, "Started")
	notify(player, "Started")
	push(s)
end)

remotes.UpdateOffer.OnServerEvent:Connect(function(player, rawOffer)
	if not throttle(player, "Update", 0.25) then
		return
	end
	local s = sessions[player]
	if not s or s.executing then
		return
	end
	local clean = sanitizeOffer(player, rawOffer)
	if not clean then
		notify(player, "Error", "Oferta inválida")
		return
	end
	s.offers[player] = clean
	-- qualquer mudança invalida as duas confirmações (evita "bait and switch")
	s.accepted[s.a] = false
	s.accepted[s.b] = false
	s.lastChange = os.clock()
	push(s)
end)

remotes.Accept.OnServerEvent:Connect(function(player, value)
	if not throttle(player, "Accept", 0.25) then
		return
	end
	local s = sessions[player]
	if not s or s.executing or type(value) ~= "boolean" then
		return
	end
	if value and os.clock() - s.lastChange < CONFIG.LOCK_DELAY then
		notify(player, "Error", "Aguarde alguns segundos antes de confirmar")
		return
	end
	s.accepted[player] = value
	push(s)
	if s.accepted[s.a] and s.accepted[s.b] then
		execute(s)
	end
end)

remotes.Cancel.OnServerEvent:Connect(function(player)
	local s = sessions[player]
	if s and not s.executing then
		endSession(s, "Troca cancelada por " .. player.Name)
	end
end)

--------------------------------------------------------------------
-- Ciclo de vida dos jogadores
--------------------------------------------------------------------
-- Devolve uma CÓPIA do inventário (somente leitura; o cliente nunca altera nada por aqui)
getInv.OnServerInvoke = function(player)
	local copy = {}
	if not throttle(player, "GetInv", 0.25) then
		return copy
	end
	for id, qty in pairs(inventories[player] or {}) do
		copy[id] = qty
	end
	return copy
end

local function onPlayerAdded(player)
	-- INVENTÁRIO DE TESTE: no jogo real, carregue do DataStore
	inventories[player] = { Sword = 3, Shield = 2, Potion = 10 }
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	onPlayerAdded(p)
end

Players.PlayerRemoving:Connect(function(player)
	local s = sessions[player]
	if s then
		endSession(s, "O outro jogador saiu")
	end
	pending[player] = nil
	for target, req in pairs(pending) do
		if req.from == player then
			pending[target] = nil
		end
	end
	-- (jogo real: salvar inventário aqui)
	inventories[player] = nil
	lastCall[player] = nil
end)


--=====================================================================
-- PARTE 2: LOCAL SCRIPT DE TESTE  (StarterPlayerScripts/TradeTest)
-- Cole em um LocalScript separado. Só tem atalhos de teclado e prints;
-- a UI de verdade você monta depois sobre os mesmos remotes.
--=====================================================================
--[[

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local R = ReplicatedStorage:WaitForChild("TradeRemotes")
local me = Players.LocalPlayer
local lastInviteUserId

R.Notify.OnClientEvent:Connect(function(kind, data)
	print("[Trade]", kind, data and HttpService:JSONEncode(data) or "")
	if kind == "Incoming" then
		lastInviteUserId = data.userId
	end
end)

R.State.OnClientEvent:Connect(function(snap)
	print("[Trade] Estado:", HttpService:JSONEncode(snap))
end)

local function nearestPlayer()
	local root = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local best, bestDist
	for _, p in ipairs(Players:GetPlayers()) do
		local r = p ~= me and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if r then
			local d = (r.Position - root.Position).Magnitude
			if not bestDist or d < bestDist then best, bestDist = p, d end
		end
	end
	return best
end

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	local k = input.KeyCode
	if k == Enum.KeyCode.T then          -- convidar o jogador mais próximo
		local p = nearestPlayer()
		if p then R.Request:FireServer(p.UserId) end
	elseif k == Enum.KeyCode.Y then      -- aceitar convite recebido
		R.Respond:FireServer(lastInviteUserId, true)
	elseif k == Enum.KeyCode.U then      -- oferecer 1 Sword + 2 Potion
		R.UpdateOffer:FireServer({ Sword = 1, Potion = 2 })
	elseif k == Enum.KeyCode.K then      -- confirmar
		R.Accept:FireServer(true)
	elseif k == Enum.KeyCode.X then      -- cancelar
		R.Cancel:FireServer()
	elseif k == Enum.KeyCode.P then      -- TESTE DE SEGURANÇA (veja abaixo)
		-- Cada linha abaixo DEVE ser rejeitada pelo servidor:
		R.UpdateOffer:FireServer({ Sword = -5 })               -- quantidade negativa
		R.UpdateOffer:FireServer({ Sword = 999999 })           -- mais do que possui
		R.UpdateOffer:FireServer({ Sword = 0/0 })              -- NaN
		R.UpdateOffer:FireServer({ Sword = math.huge })        -- infinito
		R.UpdateOffer:FireServer({ Sword = 1.5 })              -- decimal
		R.UpdateOffer:FireServer({ ItemQueNaoExiste = 1 })     -- item fora da lista branca
		R.UpdateOffer:FireServer("string")                     -- tipo errado
		R.UpdateOffer:FireServer({ [1] = 1 })                  -- chave não-string
		R.Request:FireServer("abc")                            -- tipo errado
		R.Request:FireServer(me.UserId)                        -- trocar consigo mesmo
		R.Respond:FireServer(12345, true)                      -- aceitar convite inexistente
		R.Accept:FireServer("sim")                             -- tipo errado
		for i = 1, 50 do R.Accept:FireServer(true) end         -- spam (throttle)
	end
end)

]]


--=====================================================================
-- CHECKLIST DE TESTE DE SEGURANÇA
--=====================================================================
--[[
 1. Fluxo normal: T (jogador A) > Y (jogador B) > U nos dois > esperar
    2s > K nos dois. Confira os inventários no Output do servidor.
 2. Tecla P: nenhuma das chamadas inválidas pode alterar nada nem dar
    erro no servidor (apenas "Oferta inválida" ou silêncio).
 3. Bait and switch: A e B confirmam, A muda a oferta DEPOIS -> as duas
    confirmações precisam ser resetadas.
 4. Confirmar antes de LOCK_DELAY -> deve ser recusado.
 5. Gastar o item durante a troca (vender, dropar, usar em outro lugar)
    e depois confirmar -> a revalidação em execute() deve cancelar.
 6. Um jogador sai no meio da troca -> sessão encerrada, sem itens
    perdidos nem duplicados.
 7. Troca simultânea: A convida B e C ao mesmo tempo; B e C aceitam ->
    só uma sessão pode existir por jogador.
 8. Convite expirado (esperar > REQUEST_TIMEOUT) -> não deve abrir sessão.
 9. Distância: afaste os jogadores além de MAX_DISTANCE e tente convidar.
10. Soma dos itens de todos os inventários antes e depois = igual
    (nenhuma duplicação, nenhuma perda).

 Para o jogo real:
  - Troque a tabela `inventories` por DataStore (ProfileService/ProfileStore)
    e salve as duas pontas da troca de forma consistente (UpdateAsync ou
    MessagingService/transação) para evitar duplicação em crash/rejoin.
  - Registre as trocas em log (quem, o quê, quando) para moderação.
  - Se houver moeda (Robux/dev products), NUNCA processe isso por remote;
    use MarketplaceService.ProcessReceipt.
]]
