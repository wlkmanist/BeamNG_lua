-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This file contains several filters. Please refer to the documentation created by BeamNG

local max, min, abs, cos, sqrt = math.max, math.min, math.abs, math.cos, math.sqrt
local pi2 = 2 * math.pi

--MARK: Freq

function freqGenC(period, ampl, t)
  return cos(t * pi2/(period + 1e-30)) * ampl
end

-- 1st order filters
local freqFilter1 = {}
freqFilter1.__index = freqFilter1

function newFreqFilter1()
  local data = {
    state = 0, state2 = 0, x = 0
  }
  return setmetatable(data, freqFilter1)
end

function freqFilter1:getLowPassFreq(sample, dt, cutOffFreq)
  local pfc, state = pi2 * dt * cutOffFreq, self.state
  state = state + pfc * (sample - state) / (pfc + 1)
  self.state = state
  return state
end

function freqFilter1:getLowPassPeriod(sample, dt, cutOffPeriod)
  local pdt, state = pi2 * dt, self.state
  state = state + pdt * (sample - state) / (pdt + cutOffPeriod)
  self.state = state
  return state
end

function freqFilter1:getHighPassFreq(sample, dt, cutOffFreq)
  local state = (self.state + sample - self.x) / (pi2 * dt * cutOffFreq + 1)
  self.state, self.x = state, sample
  return state
end

function freqFilter1:getHighPassPeriod(sample, dt, cutOffPeriod)
  local state = (self.state + sample - self.x) * cutOffPeriod / (pi2 * dt + cutOffPeriod)
  self.state, self.x = state, sample
  return state
end

function freqFilter1:getBandPassFreq(sample, dt, lowFreq, highFreq)
  local pdt = pi2 * dt
  local state = (self.state + sample - self.x) / (pdt * lowFreq + 1)
  local state2, pfc = self.state2, pdt * highFreq
  state2 = state2 + pfc * (state - state2) / (pfc + 1)
  self.state, self.state2, self.x = state, state2, sample
  return state2
end

function freqFilter1:getBandPassPeriod(sample, dt, lowPeriod, highPeriod)
  local pdt, state2 = pi2 * dt, self.state2
  local state = (self.state + sample - self.x) * lowPeriod / (pdt + lowPeriod)
  local state2 = state2 + pdt * (state - state2) / (pdt + highPeriod)
  self.state, self.state2, self.x = state, state2, sample
  return state2
end

function freqFilter1:getBandStopFreq(sample, dt, lowFreq, highFreq)
  local pdt = pi2 * dt
  local state = (self.state + sample - self.x) / (pdt * highFreq + 1)
  local state2, pfc = self.state2, pdt * lowFreq
  state2 = state2 + pfc * (sample - state2) / (pfc + 1)
  self.state, self.state2, self.x = state, state2, sample
  return state + state2
end

function freqFilter1:getBandStopPeriod(sample, dt, lowPeriod, highPeriod)
  local pdt, state2 = pi2 * dt, self.state2
  local state = (self.state + sample - self.x) * highPeriod/ (pdt + highPeriod)
  state2 = state2 + pdt * (sample - state2) / (pdt + lowPeriod)
  self.state, self.state2, self.x = state, state2, sample
  return state + state2
end

-- Frequency detector
local freqDetector = {}
freqDetector.__index = freqDetector

function newFreqDetector()
  local data = {
    peak = 0, bottom = 0, prevPeak = 0, prevBottom = 0,
    peakDt = 0, bottomDt = 0, prevPeakDt = 0, prevBottomDt = 0,
    peakL = 0, bottomL = 0, period = 0, ampl = 0, state = 0, bias = 0
  }
  return setmetatable(data, freqDetector)
end

-- returns period, peak amplitude, previous peakDt, DC bias: cos(peakDt*2*pi/(period+1e-30)) * ampl + bias
function freqDetector:get(sample, dt)
  self.peakDt, self.prevPeakDt = self.peakDt + dt, self.prevPeakDt + dt
  self.bottomDt, self.prevBottomDt = self.bottomDt + dt, self.prevBottomDt + dt
  local scoef = min(1, max(self.peakL - self.bottomL, 0) * 0.01)

  if sample > self.peakL then
    if self.state ~= -1 and self.prevBottomDt > self.peakDt and self.peakDt > self.bottomDt then
      self.period = self.prevBottomDt - self.bottomDt
      local midPeak = 0.5 * (self.peak + self.prevPeak)
      self.ampl = max(0, midPeak - self.prevBottom) * 0.5
      self.bias = (midPeak + self.prevBottom) * 0.5
      self.prevPeak = self.peak
      self.prevPeakDt = (self.peakDt + self.prevBottomDt + self.bottomDt) / 3
      self.state = -1
    end
    self.peakDt, self.peakL, self.peak = 0, sample, sample
  else
    self.peakL = self.peakL + scoef * (sample - self.peakL)
  end

  if sample < self.bottomL then
    if self.state ~= 1 and self.prevPeakDt > self.bottomDt and self.bottomDt > self.peakDt then
      self.period = self.prevPeakDt - self.peakDt
      local midBottom = 0.5 * (self.bottom + self.prevBottom)
      self.ampl = max(0, self.prevPeak - midBottom) * 0.5
      self.bias = (self.prevPeak + midBottom) * 0.5
      self.prevBottom = self.bottom
      self.prevBottomDt = (self.bottomDt + self.prevPeakDt + self.peakDt) / 3
      self.state = 1
    end
    self.bottomDt, self.bottomL, self.bottom = 0, sample, sample
  else
    self.bottomL = min(self.peakL, self.bottomL + scoef * (sample - self.bottomL))
  end

  local period = max(self.period, self.prevPeakDt - self.period)
  local pcoef = self.period / (period + 1e-30)
  return period, pcoef * self.ampl, self.prevPeakDt, pcoef * self.bias
end

function freqDetector:reset()
  self.peak, self.bottom, self.peakL, self.bottomL, self.state = 0, 0, 0, 0, 0
  self.period, self.ampl, self.bias = 0, 0, 0
end

function freqDetector:value(dt)
  dt = dt or 0
  self.peakDt, self.bottomDt = self.peakDt + dt, self.bottomDt + dt
  self.prevPeakDt, self.prevBottomDt = self.prevPeakDt + dt, self.prevBottomDt + dt
  return self.period, self.ampl, self.prevPeakDt, self.bias
end

-- Frequency existence: https://en.wikipedia.org/wiki/Goertzel_algorithm
local freqExists = {}
freqExists.__index = freqExists

function newFreqExists()
  local data = { s_prev = 0, s_prev2 = 0, cycleDt = 0, lastAmpl = 0, N = 0 }
  return setmetatable(data, freqExists)
end

-- returns amplitude of freq, larger cycleCount increases accuracy and latency
function freqExists:get(sample, dt, freq, cycleCount)
  local coeff, s_prev, cycleDt = 2*cos(pi2 * freq * dt), self.s_prev, self.cycleDt + dt
  local s = coeff * s_prev + (sample - self.s_prev2)
  self.N = self.N + 0.5
  if cycleDt * freq >= (cycleCount or 1) then
    self.lastAmpl = math.sqrt(max(0, s_prev*(s_prev - coeff*s) + s*s)) / self.N
    self.s_prev, self.s_prev2, self.cycleDt, self.N = 0, 0, 0, 0
  else
    self.s_prev2, self.s_prev, self.cycleDt = s_prev, s, cycleDt
  end
  return self.lastAmpl
end

-- returns per sample sliding amplitude of freq, larger winCoef increases accuracy and latency
function freqExists:getS(sample, dt, freq, winCoef)
  local fdt = freq * dt
  if fdt >= 0.5 then return 0 end
  winCoef = winCoef or 10
  local pfd = pi2 * fdt
  local coeff, s_prev = 2*cos(pfd), self.s_prev
  local s = (coeff * s_prev + (sample - self.s_prev2)) * (winCoef / (pfd + winCoef))
  self.s_prev2, self.s_prev = s_prev, s
  return sqrt(max(0, s_prev*(s_prev - coeff*s) + s*s)) * 0.48 / (winCoef*(0.5 - fdt))
end

function freqExists:bufferStart(dt, freq)
  self.s_prev, self.s_prev2, self.N, self.cycleDt = 0, 0, 0, 2*cos(pi2 * freq * dt)
end

function freqExists:bufferAdd(sample)
  local s_prev = self.s_prev
  local s = self.cycleDt * s_prev + (sample - self.s_prev2)
  self.s_prev2, self.s_prev, self.N = s_prev, s, self.N + 0.5
end

function freqExists:bufferEnd()
  local ampl = math.sqrt(max(0, self.s_prev2*(self.s_prev2 - self.cycleDt*self.s_prev) + self.s_prev*self.s_prev)) / self.N
  self.s_prev, self.s_prev2, self.N = 0, 0, 0
  return ampl
end

function freqExists:reset()
  self.s_prev, self.s_prev2, self.cycleDt, self.N, self.lastAmpl = 0, 0, 0, 0, 0
end

--MARK: Temporal

-- Spring based temporal
local temporalSpring = {}
temporalSpring.__index = temporalSpring

function newTemporalSpring(spring, damp, startingValue)
  local data = {spring = spring or 10, damp = damp or 2, state = startingValue or 0, vel = 0}
  return setmetatable(data, temporalSpring)
end

function temporalSpring:get(sample, dt)
  self.vel = self.vel * max(1 - self.damp * dt, 0) + (sample - self.state) * min(self.spring * dt, 1/dt)
  self.state = self.state + self.vel * dt
  return self.state
end

function temporalSpring:getWithSpringDamp(sample, dt, spring, damp)
  self.vel = self.vel * max(1 - damp * dt, 0) + (sample - self.state) * min(spring * dt, 1/dt)
  self.state = self.state + self.vel * dt
  return self.state
end

function temporalSpring:set(sample)
  self.state = sample
  self.vel = 0
end

function temporalSpring:value()
  return self.state
end

-- S-curve temporal
local temporalSigmoidSmoothing = {}
temporalSigmoidSmoothing.__index = temporalSigmoidSmoothing

function newTemporalSigmoidSmoothing(inRate, startAccel, stopAccel, outRate, startingValue)
  local rate = inRate or 1
  local startaccel = startAccel or math.huge
  local data = {[false] = rate, [true] = outRate or rate, startAccel = startaccel, stopAccel = stopAccel or startaccel, state = startingValue or 0, prevvel = 0}
  return setmetatable(data, temporalSigmoidSmoothing)
end

function temporalSigmoidSmoothing:get(sample, dt)
  local dif = sample - self.state

  local prevvel = self.prevvel * max(sign(self.prevvel * dif), 0)
  local vsq = prevvel * prevvel
  local absdif = abs(dif)
  local difsign = sign(dif)
  local acceldt

  local absdif2 = absdif * 2
  if vsq > absdif2 * self.stopAccel then
    acceldt = -difsign * min((vsq / absdif2) * dt, abs(prevvel))
  else
    acceldt = difsign * self.startAccel * dt
  end

  local ratelimit = self[dif * self.state >= 0]
  self.state = self.state + difsign * min(min(abs(prevvel + 0.5 * acceldt), ratelimit) * dt, absdif)
  self.prevvel = difsign * min(abs(prevvel + acceldt), ratelimit)
  return self.state
end

function temporalSigmoidSmoothing:getWithRateAccel(sample, dt, ratelimit, startAccel, stopAccel)
  local dif = sample - self.state
  local prevvel = self.prevvel * max(sign(self.prevvel * dif), 0)
  local vsq = prevvel * prevvel
  local absdif = abs(dif)
  local difsign = sign(dif)
  local acceldt

  local absdif2 = absdif * 2
  if vsq > absdif2 * (stopAccel or startAccel) then
    acceldt = -difsign * min((vsq / absdif2) * dt, abs(prevvel))
  else
    acceldt = difsign * startAccel * dt
  end

  self.state = self.state + difsign * min(min(abs(prevvel + 0.5 * acceldt), ratelimit) * dt, absdif)
  self.prevvel = difsign * min(abs(prevvel + acceldt), ratelimit)
  return self.state
end

function temporalSigmoidSmoothing:set(sample)
  self.state = sample
  self.prevvel = 0
end

function temporalSigmoidSmoothing:reset()
  self.state = 0
  self.prevvel = 0
end

function temporalSigmoidSmoothing:value()
  return self.state
end

-- Exponential/Non Linear temporal with minimum movement limit
local temporalSmoothingHybrid = {}
temporalSmoothingHybrid.__index = temporalSmoothingHybrid

function newTemporalSmoothingHybrid(inRate, outRate, startingValue, linearRate)
  local rate = min(inRate or 1, 1e+30)
  local data = {[false] = rate, [true] = min(outRate or rate, 1e+30), state = startingValue or 0, linearRate = linearRate or 0}
  return setmetatable(data, temporalSmoothingHybrid)
end

function temporalSmoothingHybrid:get(sample, dt)
  local st = self.state
  local dif = sample - st
  local ratedt = self[dif * st >= 0] * dt
  st = st + dif * max(ratedt / (1 + ratedt), min(self.linearRate * dt / abs(dif), 1))
  self.state = st
  return st
end

function temporalSmoothingHybrid:getWithRate(sample, dt, rate, linearRate)
  local st = self.state
  local dif = sample - st
  local ratedt = rate * dt
  st = st + dif * max(ratedt / (1 + ratedt), min((linearRate or 0) * dt / abs(dif), 1))
  self.state = st
  return st
end

function temporalSmoothingHybrid:set(sample)
  self.state = sample
end

function temporalSmoothingHybrid:value()
  return self.state
end

function temporalSmoothingHybrid:reset()
  self.state = 0
end

-- Exponential/Non Linear temporal
local temporalSmoothingNonLinear = {}
temporalSmoothingNonLinear.__index = temporalSmoothingNonLinear

function newTemporalSmoothingNonLinear(inRate, outRate, startingValue)
  local rate = min(inRate or 1, 1e+30)
  local data = {[false] = rate, [true] = min(outRate or rate, 1e+30), state = startingValue or 0}
  return setmetatable(data, temporalSmoothingNonLinear)
end

function temporalSmoothingNonLinear:get(sample, dt)
  local st = self.state
  local dif = sample - st
  local ratedt = self[dif * st >= 0] * dt
  st = st + dif * (ratedt / (1 + ratedt))
  self.state = st
  return st
end

function temporalSmoothingNonLinear:getWithRate(sample, dt, rate)
  local st = self.state
  local ratedt = rate * dt
  st = st + (sample - st) * (ratedt / (1 + ratedt))
  self.state = st
  return st
end

function temporalSmoothingNonLinear:set(sample)
  self.state = sample
end

function temporalSmoothingNonLinear:value()
  return self.state
end

function temporalSmoothingNonLinear:reset()
  self.state = 0
end

-- Linear temporal
local temporalSmoothing = {}
temporalSmoothing.__index = temporalSmoothing

function newTemporalSmoothing(inRate, outRate, autoCenterRate, startingValue)
  inRate = max(inRate or 1, 1e-307)
  startingValue = startingValue or 0

  local data = {[false] = inRate, [true] = max(outRate or inRate, 1e-307), autoCenterRate = max(autoCenterRate or inRate, 1e-307), _startingValue = startingValue, state = startingValue}
  setmetatable(data, temporalSmoothing)

  if data.autoCenterRate ~= inRate then
    data.getUncapped = data.getUncappedAutoCenter
  end
  return data
end

function temporalSmoothing:getUncappedAutoCenter(sample, dt)
  local st = self.state
  local dif = (sample - st)
  local rate

  if sample == 0 then
    rate = self.autoCenterRate  -- autocentering
  else
    rate = self[dif * st >= 0]
  end
  st = st + dif * min(rate * dt / abs(dif), 1)
  self.state = st
  return st
end

function temporalSmoothing:get(sample, dt)
  local st = self.state
  local dif = sample - st
  st = st + dif * min(self[dif * st >= 0] * dt / abs(dif), 1)
  self.state = st
  return st
end

function temporalSmoothing:getCapped(sample, dt)
  return max(min(self:getUncapped(sample, dt), 1), -1)
end

function temporalSmoothing:getWithRate(sample, dt, rate)
  local st = self.state
  local dif = (sample - st)
  st = st + dif * min(rate * dt / (abs(dif) + 1e-307), 1)
  self.state = st
  return st
end

function temporalSmoothing:getWithRateCapped(sample, dt, rate)
  return max(min(self:getWithRate(sample, dt, rate), 1), -1)
end

temporalSmoothing.getUncapped = temporalSmoothing.get
temporalSmoothing.getWithRateUncapped = temporalSmoothing.getWithRate

function temporalSmoothing:reset()
  self.state = self._startingValue
end

function temporalSmoothing:value()
  return self.state
end

function temporalSmoothing:set(v)
  self.state = v
end

--MARK: Fixed dt

-- Linear
local linearSmoothing = {}
linearSmoothing.__index = linearSmoothing

function newLinearSmoothing(dt, inRate, outRate)
  inRate = max(inRate or 1, 1e-307)
  local data = {[false] = inRate * dt, [true] = max(outRate or inRate, 1e-307) * dt, state = 0}
  return setmetatable(data, linearSmoothing)
end

function linearSmoothing:get(sample) -- no autocenter
  local st = self.state
  local dif = (sample - st)
  st = st + dif * min(self[dif * st >= 0] / abs(dif), 1)
  self.state = st
  return st
end

function linearSmoothing:set(v)
  self.state = v
end

function linearSmoothing:reset()
  self.state = 0
end

-- bypass filter
local nopSmoothing = {}
nopSmoothing.__index = nopSmoothing

function newNopSmoothing()
  return setmetatable({}, nopSmoothing)
end

function nopSmoothing:get(sample)
  return sample
end

function nopSmoothing:set()
end

function nopSmoothing:reset()
end

local exponentialSmoothing = {}
exponentialSmoothing.__index = exponentialSmoothing

function newExponentialSmoothing(window, startingValue, fixedDt)
  local data = {a = 2 / max(window, 2), _startingValue = startingValue or 0, st = startingValue or 0}
  local adt = data.a * (fixedDt or 0.0005)
  data.a = (2000 + data.a) * (adt / (1 + adt))
  return setmetatable(data, exponentialSmoothing)
end

function exponentialSmoothing:get(sample)
  local st = self.st
  st = st + self.a * (sample - st)
  self.st = st
  return st
end

function exponentialSmoothing:getWindow(sample, window)
  local st = self.st
  st = st + 2 * (sample - st) / max(window, 2)
  self.st = st
  return st
end

function exponentialSmoothing:value()
  return self.st
end

function exponentialSmoothing:set(value)
  self.st = value
end

function exponentialSmoothing:reset(value)
  self.st = value or self._startingValue
end

-- Exponential + Trend
local exponentialSmoothingT = {}
exponentialSmoothingT.__index = exponentialSmoothingT

function newExponentialSmoothingT(window, window2, startingValue)
  startingValue = startingValue or 0
  local data = {a = 2 / max(window, 2), a2 = 2 / max(window2 or math.huge, 2), startingValue = startingValue, st = startingValue, [true] = 0, [false] = 0}
  return setmetatable(data, exponentialSmoothingT)
end

function exponentialSmoothingT:get(sample)
  local a, a2, st, st1, st2 = self.a, self.a2, self.st, self[true], self[false]
  local samplst2 = sample - self[sample >= st]
  if (samplst2 - st) * (sample - st) < 0 then samplst2 = sample end
  st = st + a * (samplst2 - st)
  local dif = samplst2 - st
  local a2dif = a2 * dif
  if dif >= 0 then
    st1, st2 = min(dif, st1 + a2dif), min(0, st2 + a2dif)
    st = st + st1
  else
    st1, st2 = max(0, st1 + a2dif), max(dif, st2 + a2dif)
    st = st + st2
  end
  self.st, self[true], self[false] = st, st1, st2
  return st
end

function exponentialSmoothingT:getWindow(sample, window, window2)
  local st, st1, st2 = self.st, self[true], self[false]
  local samplst2 = sample - self[sample >= st]
  if (samplst2 - st) * (sample - st) < 0 then samplst2 = sample end
  st = st + (samplst2 - st) * 2 / max(window, 2)
  local dif = samplst2 - st
  local a2dif = dif * 2 / max(window2 or math.huge, 2)
  if dif >= 0 then
    st1, st2 = min(dif, st1 + a2dif), min(0, st2 + a2dif)
    st = st + st1
  else
    st1, st2 = max(0, st1 + a2dif), max(dif, st2 + a2dif)
    st = st + st2
  end
  self.st, self[true], self[false] = st, st1, st2
  return st
end

function exponentialSmoothingT:value()
  return self.st
end

function exponentialSmoothingT:set(value)
  self.st = value
end

function exponentialSmoothingT:reset(value)
  self.st, self[true], self[false] = value or self.startingValue, 0, 0
end

-- exponentialy weighted least squares linear regression
local lineFitting = {}
lineFitting.__index = lineFitting

-- Note: window can be sample-based or time-based; use getS or get, respectively.
-- Note: To improve numerical stability, scale the input variables to be in the range of [0, 1] or [-1, 1].
function newLineFitting(window, weight, bias, scale, weightMin, weightMax, biasMin, biasMax)
  if not scale or scale <= 0 then scale = 1000 end
  weight, weightMin, weightMax = weight or 0, weightMin or -math.huge, weightMax or math.huge
  bias, biasMin, biasMax = bias or 0, biasMin or -math.huge, biasMax or math.huge
  local decay = 1 - 2 / (window + 1)
  local data = {
    weight = weight, weightStartingValue = weight, weightMin = weightMin, weightMax = weightMax,
    bias = bias, biasStartingValue = bias, biasMin = biasMin, biasMax = biasMax,
    decay = decay, decayStartingValue = decay, scale = scale,
    det = 1,
    window = window,
    [1] = 1 / scale, [2] = 0, [3] = 0, [4] = 0, [5] = 0
  }
  return setmetatable(data, lineFitting)
end

-- getS: sample-based get method
function lineFitting:getS(x, y)
  local decay = self.decay
  --Stability check
  local R12Sq = square(self[2])
  decay = square(self.det) < 1e-6 * (self[1] * self[1] + R12Sq) * (R12Sq + self[3] * self[3]) and 0.99998 or decay
  --Update covariance matrix
  -- R: 2*2 covariance matrix, r: 2*1 cross covariance vector
  local R11 = decay * self[1] + x * x
  local R12 = decay * self[2] + x -- R12 and R21 are equal
  local R22 = decay * self[3] + 1
  local r1 = decay * self[4] + x * y
  local r2 = decay * self[5] + y
  self[1], self[2], self[3], self[4], self[5] = R11, R12, R22, r1, r2
  -- [w, b]^T = R^-1 * r
  --Regressor update
  local det = R11 * R22 - R12 * R12
  local detInv = max(min(1 / det, 1e300), -1e300) -- R matrix determinant inverse
  self.det = det
  self.weight = clamp((r1 - clamp((R11 * r2 - R12 * r1) * detInv, self.biasMin, self.biasMax) * R12) / R11, self.weightMin, self.weightMax)
  self.bias = clamp((r2 - clamp((R22 * r1 - R12 * r2) * detInv, self.weightMin, self.weightMax) * R12) / R22, self.biasMin, self.biasMax)
  return self.weight, self.bias
end

-- get: time-based get method
function lineFitting:get(x, y, dt)
  --Decay
  self.decay = 1 - 2 * dt / (self.window + dt)
  local decay = self.decay
  --Stability check
  local R12Sq = square(self[2])
  decay = square(self.det) < 1e-6 * (self[1] * self[1] + R12Sq) * (R12Sq + self[3] * self[3]) and 0.99998 or decay
  --Update covariance matrix
  -- R: 2*2 covariance matrix, r: 2*1 cross covariance vector
  local R11 = decay * self[1] + x * x
  local R12 = decay * self[2] + x -- R12 and R21 are equal
  local R22 = decay * self[3] + 1
  local r1 = decay * self[4] + x * y
  local r2 = decay * self[5] + y
  self[1], self[2], self[3], self[4], self[5] = R11, R12, R22, r1, r2
  -- [w, b]^T = R^-1 * r
  --Regressor update
  local det = R11 * R22 - R12 * R12
  local detInv = max(min(1 / det, 1e300), -1e300) -- R matrix determinant inverse
  self.det = det
  self.weight = clamp((r1 - clamp((R11 * r2 - R12 * r1) * detInv, self.biasMin, self.biasMax) * R12) / R11, self.weightMin, self.weightMax)
  self.bias = clamp((r2 - clamp((R22 * r1 - R12 * r2) * detInv, self.weightMin, self.weightMax) * R12) / R22, self.biasMin, self.biasMax)
  return self.weight, self.bias
end

function lineFitting:value()
  return self.weight, self.bias
end

function lineFitting:getY(x)
  return self.weight * x + self.bias
end

function lineFitting:getX(y)
  return sign2(self.weight) * (y - self.bias) / (abs(self.weight) + 1e-30)
end

function lineFitting:set(window, weight, bias, weightMin, weightMax, biasMin, biasMax)
  self.weight, self.weightMin, self.weightMax = weight or self.weight, weightMin or self.weightMin, weightMax or self.weightMax
  self.bias, self.biasMin, self.biasMax = bias or self.bias, biasMin or self.biasMin, biasMax or self.biasMax
  if window then self.decay = 1 - 2 / (window + 1) end
end

function lineFitting:reset()
  self.weight = self.weightStartingValue
  self.bias = self.biasStartingValue
  self[1], self[2], self[3], self[4], self[5] = 1 / self.scale, 0, 0, 0, 0
end