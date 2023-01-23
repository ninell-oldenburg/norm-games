--[[ Copyright 2022 DeepMind Technologies Limited.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]

local args = require 'common.args'
local class = require 'common.class'
local helpers = require 'common.helpers'
local log = require 'common.log'
local random = require 'system.random'
local tensor = require 'system.tensor'
local set = require 'common.set'
local events = require 'system.events'

local meltingpot = 'meltingpot.lua.modules.'
local component = require(meltingpot .. 'component')
local component_registry = require(meltingpot .. 'component_registry')


local function concat(table1, table2)
  local resultTable = {}
  for k, v in pairs(table1) do
    table.insert(resultTable, v)
  end
  for k, v in pairs(table2) do
    table.insert(resultTable, v)
  end
  return resultTable
end

local function extractPieceIdsFromObjects(gameObjects)
  local result = {}
  for k, v in ipairs(gameObjects) do
    table.insert(result, v:getPiece())
  end
  return result
end


local Neighborhoods = class.Class(component.Component)

function Neighborhoods:__init__(kwargs)
  kwargs = args.parse(kwargs, {
      {'name', args.default('Neighborhoods')},
  })
  Neighborhoods.Base.__init__(self, kwargs)
end

function Neighborhoods:reset()
  self._variables.pieceToNumNeighbors = {}
end

function Neighborhoods:getPieceToNumNeighbors()
  -- Note: this table is frequently modified by callbacks.
  return self._variables.pieceToNumNeighbors
end

function Neighborhoods:getUpperBoundPossibleNeighbors()
  return self._config.upperBoundPossibleNeighbors
end


local DensityRegrow = class.Class(component.Component)

function DensityRegrow:__init__(kwargs)
  kwargs = args.parse(kwargs, {
      {'name', args.default('DensityRegrow')},
      {'liveState', args.stringType},
      {'waitState', args.stringType},
      {'radius', args.numberType},
      {'regrowthProbabilities', args.tableType},
      {'canRegrowIfOccupied', args.default(true)},
  })
  DensityRegrow.Base.__init__(self, kwargs)

  self._config.liveState = kwargs.liveState
  self._config.waitState = kwargs.waitState

  self._config.radius = kwargs.radius
  self._config.regrowthProbabilities = kwargs.regrowthProbabilities

  if self._config.radius >= 0 then
    self._config.upperBoundPossibleNeighbors = math.floor(
        math.pi * self._config.radius ^ 2 + 1) + 1
  else
    self._config.upperBoundPossibleNeighbors = 0
  end
  self._config.canRegrowIfOccupied = kwargs.canRegrowIfOccupied

  self._started = false
end

function DensityRegrow:reset()
  self._started = false
end

function DensityRegrow:registerUpdaters(updaterRegistry)
  local function sprout()
    if self._config.canRegrowIfOccupied then
      self.gameObject:setState(self._config.liveState)
    else
      -- Only setState if no player is at the same position.
      local transform = self.gameObject:getComponent('Transform')
      local players = transform:queryDiamond('upperPhysical', 0)
      if #players == 0 then
        self.gameObject:setState(self._config.liveState)
      end
    end
  end
  -- Add an updater for each `wait` regrowth rate category.
  for numNear = 0, self._config.upperBoundPossibleNeighbors - 1 do
    -- Cannot directly index the table with numNear since Lua is 1-indexed.
    local idx = numNear + 1
    -- If more nearby than probabilities declared then use the last declared
    -- probability in the table (normally the high probability).
    local idx = math.min(idx, #self._config.regrowthProbabilities)
    -- Using the `group` kwarg here creates global initiation conditions for
    -- events. On each step, all objects in `group` have the given `probability`
    -- of being selected to call their `updateFn`.
    -- Set updater for each neighborhood category.
    updaterRegistry:registerUpdater{
        updateFn = sprout,
        priority = 10,
        group = 'waits_' .. tostring(numNear),
        state = 'appleWait_' .. tostring(numNear),
        probability = self._config.regrowthProbabilities[idx],
    }
  end
end

function DensityRegrow:start()
  local sceneObject = self.gameObject.simulation:getSceneObject()
  local neighborhoods = sceneObject:getComponent('Neighborhoods')
  self._variables.pieceToNumNeighbors = neighborhoods:getPieceToNumNeighbors()
  self._variables.pieceToNumNeighbors[self.gameObject:getPiece()] = 0
end

function DensityRegrow:postStart()
  self:_beginLive()
  self._started = true
  self._underlyingGrass = self.gameObject:getComponent(
      'Transform'):queryPosition('background')
end

function DensityRegrow:update()
  if self.gameObject:getLayer() == 'logic' then
    self:_updateWaitState()
  end
end

function DensityRegrow:onStateChange(oldState)
  if self._started then
    local newState = self.gameObject:getState()
    local aliveState = self:getAliveState()
    if newState == aliveState then
      self:_beginLive()
    elseif oldState == aliveState then
      self:_endLive()
    end
  end
end

function DensityRegrow:getAliveState()
  return self._config.liveState
end

function DensityRegrow:getWaitState()
  return self._config.waitState
end

--[[ This function updates the state of a potential (wait) apple to correspond
to the correct regrowth probability for its number of neighbors.]]
function DensityRegrow:_updateWaitState()
  if self.gameObject:getState() ~= self._config.liveState then
    local piece = self.gameObject:getPiece()
    local numClose = self._variables.pieceToNumNeighbors[piece]
    local newState = self._config.waitState .. '_' .. tostring(numClose)
    self.gameObject:setState(newState)
    if newState == self._config.waitState .. '_' .. tostring(0) then
      self._underlyingGrass:setState('dessicated')
    else
      self._underlyingGrass:setState('grass')
    end
  end
end

function DensityRegrow:_getNeighbors()
  local transformComponent = self.gameObject:getComponent('Transform')
  local waitNeighbors = extractPieceIdsFromObjects(
      transformComponent:queryDisc('logic', self._config.radius))
  local liveNeighbors = extractPieceIdsFromObjects(
      transformComponent:queryDisc('lowerPhysical', self._config.radius))
  local neighbors = concat(waitNeighbors, liveNeighbors)
  return neighbors, liveNeighbors, waitNeighbors
end

--[[ Function that executes when state gets set to the `live` state.]]
function DensityRegrow:_beginLive()
  -- Increment respawn group assignment for all nearby waits.
  local neighbors, liveNeighbors, waitNeighbors = self:_getNeighbors()
  for _, neighborPiece in ipairs(waitNeighbors) do
    if neighborPiece ~= self.gameObject:getPiece() then
      local closeBy = self._variables.pieceToNumNeighbors[neighborPiece]
      if not closeBy then
        assert(false, 'Neighbors not found when they should exist.')
      end
      self._variables.pieceToNumNeighbors[neighborPiece] =
          self._variables.pieceToNumNeighbors[neighborPiece] + 1
    end
  end
end

--[[ Function that executes when state changed to no longer be `live`.]]
function DensityRegrow:_endLive()
  -- Decrement respawn group assignment for all nearby waits.
  local neighbors, liveNeighbors, waitNeighbors = self:_getNeighbors()
  for _, neighborPiece in ipairs(waitNeighbors) do
    if neighborPiece ~= self.gameObject:getPiece() then
      local closeBy = self._variables.pieceToNumNeighbors[neighborPiece]
      if not closeBy then
        assert(false, 'Neighbors not found when they should exist.')
      end
      self._variables.pieceToNumNeighbors[neighborPiece] =
          self._variables.pieceToNumNeighbors[neighborPiece] - 1
    else
      -- Case where neighbor piece is self.
      self._variables.pieceToNumNeighbors[neighborPiece] = #liveNeighbors
    end
    assert(self._variables.pieceToNumNeighbors[neighborPiece] >= 0,
             'Less than zero neighbors: Something has gone wrong.')
  end
end


--[[ The DirtTracker is a component on each river object that notifies scene
components when it has been spawned or cleaned.

Arguments:
`activeState` (string): Name of the active state, typically = 'dirt'.
`inactiveState` (string): Name of the inactive state, typically = 'dirtWait'.
]]
local DirtTracker = class.Class(component.Component)

function DirtTracker:__init__(kwargs)
  kwargs = args.parse(kwargs, {
      {'name', args.default('DirtTracker')},
      {'activeState', args.default('dirt'), args.stringType},
      {'inactiveState', args.default('dirtWait'), args.stringType},
  })
  DirtTracker.Base.__init__(self, kwargs)
  self._activeState = kwargs.activeState
  self._inactiveState = kwargs.inactiveState
end

function DirtTracker:postStart()
  local sceneObject = self.gameObject.simulation:getSceneObject()
  self._riverMonitor = sceneObject:getComponent('RiverMonitor')
  self._dirtSpawner = sceneObject:getComponent('DirtSpawner')

  -- If starting in inactive state, must register with the dirt spawner and
  -- river monitor.
  if self.gameObject:getState() == self._inactiveState then
    self._dirtSpawner:addPieceToPotential(self.gameObject:getPiece())
    self._riverMonitor:incrementCleanCount()
  elseif self.gameObject:getState() == self._activeState then
    self._riverMonitor:incrementDirtCount()
  end
end

function DirtTracker:onStateChange(oldState)
  local newState = self.gameObject:getState()
  if oldState == self._inactiveState and newState == self._activeState then
    self._riverMonitor:incrementDirtCount()
    self._riverMonitor:decrementCleanCount()
    self._dirtSpawner:removePieceFromPotential(self.gameObject:getPiece())
  elseif oldState == self._activeState and newState == self._inactiveState then
    self._riverMonitor:decrementDirtCount()
    self._riverMonitor:incrementCleanCount()
    self._dirtSpawner:addPieceToPotential(self.gameObject:getPiece())
  end
end


local DirtCleaning = class.Class(component.Component)

function DirtCleaning:__init__(kwargs)
  kwargs = args.parse(kwargs, {
      {'name', args.default('DirtCleaning')},
  })
  DirtCleaning.Base.__init__(self, kwargs)
end

function DirtCleaning:onHit(hittingGameObject, hitName)
  if self.gameObject:getState() == 'dirt' and hitName == 'cleanHit' then
    self.gameObject:setState('dirtWait')
    -- Trigger role-specific logic if applicable.
    if hittingGameObject:hasComponent('Taste') then
      hittingGameObject:getComponent('Taste'):cleaned()
    end
    if hittingGameObject:hasComponent('Cleaner') then
      hittingGameObject:getComponent('Cleaner'):setCumulant()
    end
    local avatar = hittingGameObject:getComponent('Avatar')
    events:add('player_cleaned', 'dict',
               'player_index', avatar:getIndex()) -- int
    -- return `true` to prevent the beam from passing through a hit dirt.
    return true
  end
end


--[[ The Cleaner component provides a beam that can be used to clean dirt.

Arguments:
`cooldownTime` (int): Minimum time (frames) between cleaning beam shots.
`beamLength` (int): Max length of the cleaning beam.
`beamRadius` (int): Maximum distance from center to left/right of the cleaning
beam. The maximum width is 2*beamRadius+1.
]]
local Cleaner = class.Class(component.Component)

function Cleaner:__init__(kwargs)
  kwargs = args.parse(kwargs, {
      {'name', args.default('Cleaner')},
      {'cooldownTime', args.positive},
      {'beamLength', args.positive},
      {'beamRadius', args.positive},
  })
  Cleaner.Base.__init__(self, kwargs)

  self._config.cooldownTime = kwargs.cooldownTime
  self._config.beamLength = kwargs.beamLength
  self._config.beamRadius = kwargs.beamRadius
end

function Cleaner:addHits(worldConfig)
  worldConfig.hits['cleanHit'] = {
      layer = 'beamClean',
      sprite = 'BeamClean',
  }
  component.insertIfNotPresent(worldConfig.renderOrder, 'beamClean')
end

function Cleaner:addSprites(tileSet)
  -- This color is light blue.
  tileSet:addColor('BeamClean', {99, 223, 242, 175})
end

function Cleaner:registerUpdaters(updaterRegistry)
  local aliveState = self:getAliveState()
  local waitState = self:getWaitState()

  local clean = function()
    local playerVolatileVariables = (
        self.gameObject:getComponent('Avatar'):getVolatileData())
    local actions = playerVolatileVariables.actions
    -- Execute the beam if applicable.
    if self.gameObject:getState() == aliveState then
      if self._config.cooldownTime >= 0 then
        if self._coolingTimer > 0 then
          self._coolingTimer = self._coolingTimer - 1
        else
          if actions['fireClean'] == 1 then
            self._coolingTimer = self._config.cooldownTime
            self.gameObject:hitBeam(
                'cleanHit', self._config.beamLength, self._config.beamRadius)
          end
        end
      end
    end
  end

  updaterRegistry:registerUpdater{
      updateFn = clean,
      priority = 140,
  }

  local function resetCumulant()
    self.player_cleaned = 0
  end
  updaterRegistry:registerUpdater{
      updateFn = resetCumulant,
      priority = 400,
  }
end

function Cleaner:reset()
  -- Set the beam cooldown timer to its `ready` state (i.e. coolingTimer = 0).
  self._coolingTimer = 0
end

function Cleaner:getAliveState()
  return self.gameObject:getComponent('Avatar'):getAliveState()
end

function Cleaner:getWaitState()
  return self.gameObject:getComponent('Avatar'):getWaitState()
end

function Cleaner:setCumulant()
  self.player_cleaned = self.player_cleaned + 1

  local globalData = self.gameObject.simulation:getSceneObject():getComponent(
      'GlobalData')
  local playerIndex = self.gameObject:getComponent('Avatar'):getIndex()
  globalData:setCleanedThisStep(playerIndex)
end


--[[ The RiverMonitor is a scene component that tracks the state of the river.

Other components such as dirt spawners and loggers can pull data from it.
]]
local RiverMonitor = class.Class(component.Component)

function RiverMonitor:__init__(kwargs)
  kwargs = args.parse(kwargs, {
      {'name', args.default('RiverMonitor')},
  })
  RiverMonitor.Base.__init__(self, kwargs)
end

function RiverMonitor:reset()
  self._dirtCount = 0
  self._cleanCount = 0
end

function RiverMonitor:incrementDirtCount()
  self._dirtCount = self._dirtCount + 1
end

function RiverMonitor:decrementDirtCount()
  self._dirtCount = self._dirtCount - 1
end

function RiverMonitor:incrementCleanCount()
  self._cleanCount = self._cleanCount + 1
end

function RiverMonitor:decrementCleanCount()
  self._cleanCount = self._cleanCount - 1
end

function RiverMonitor:getDirtCount()
  return self._dirtCount
end

function RiverMonitor:getCleanCount()
  return self._cleanCount
end

--[[ The DirtSpawner is a scene component that spawns dirt at a fixed rate.

Arguments:
`dirtSpawnProbability` (float in [0, 1]): Probability of spawning one dirt on
each frame.
]]
local DirtSpawner = class.Class(component.Component)

function DirtSpawner:__init__(kwargs)
  kwargs = args.parse(kwargs, {
      {'name', args.default('DirtSpawner')},
      -- Probability per step of one dirt cell spawning in the river.
      {'dirtSpawnProbability', args.ge(0.0), args.le(1.0)},
      -- Number of steps to wait after the start of each episode before spawning
      -- dirt in the river.
      {'delayStartOfDirtSpawning', args.default(0), args.numberType},
  })
  DirtSpawner.Base.__init__(self, kwargs)
  self._config.delayStartOfDirtSpawning = kwargs.delayStartOfDirtSpawning
  self._dirtSpawnProbability = kwargs.dirtSpawnProbability
  self._potentialDirts = set.Set{}
end

function DirtSpawner:reset()
  self._potentialDirts = set.Set{}
  self._timeStep = 1
end

function DirtSpawner:update()
  if self._timeStep > self._config.delayStartOfDirtSpawning then
    if random:uniformReal(0.0, 1.0) < self._dirtSpawnProbability then
      local piece = random:choice(set.toSortedList(self._potentialDirts))
      if piece then
        self.gameObject.simulation:getGameObjectFromPiece(piece):setState(
          'dirt')
      end
    end
  end
  self._timeStep = self._timeStep + 1
end

function DirtSpawner:removePieceFromPotential(piece)
  self._potentialDirts[piece] = nil
end

function DirtSpawner:addPieceToPotential(piece)
  self._potentialDirts[piece] = true
end

local GlobalData = class.Class(component.Component)

function GlobalData:__init__(kwargs)
  kwargs = args.parse(kwargs, {
      {'name', args.default('GlobalData')},
  })
  GlobalData.Base.__init__(self, kwargs)
end

function GlobalData:reset()
  local numPlayers = self.gameObject.simulation:getNumPlayers()

  self.playersWhoCleanedThisStep = tensor.Tensor(numPlayers):fill(0)
  self.playersWhoAteThisStep = tensor.Tensor(numPlayers):fill(0)
end

function GlobalData:registerUpdaters(updaterRegistry)
  local function resetCumulants()
    self.playersWhoCleanedThisStep:fill(0)
    self.playersWhoAteThisStep:fill(0)
  end
  updaterRegistry:registerUpdater{
      updateFn = resetCumulants,
      priority = 2,
  }
end

function GlobalData:setCleanedThisStep(playerIndex)
  self.playersWhoCleanedThisStep(playerIndex):val(1)
end

function GlobalData:setAteThisStep(playerIndex)
  self.playersWhoAteThisStep(playerIndex):val(1)
end

local allComponents = {
    Neighborhoods = Neighborhoods,
    DensityRegrow = DensityRegrow,

    -- Scene components.
    RiverMonitor = RiverMonitor,
    DirtSpawner = DirtSpawner,
    GlobalData = GlobalData,
}

component_registry.registerAllComponents(allComponents)

return allComponents
