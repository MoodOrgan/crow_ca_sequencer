--- crow cellular automaton percussion sequencer (v2)
-- in1: clock (rising edges)   in2: binary data (sampled on each clock)
-- out1-4: held voltages = five-cell population (0-5 V) under four read heads
--         on a radius-2 totalistic {2,4} ring
-- input bits are held pending and only enter the ring at the next generation,
-- so nothing is heard until it has been evolved
-- identical script for every crow; no randomness

---------------------------------------------------------------------------
-- parameters
---------------------------------------------------------------------------
L            = 17        -- ring length (alternatives: 24, 19, 16)
RADIUS       = 2         -- neighborhood radius (5 cells)
BIRTH        = {[2] = true, [4] = true}  -- neighborhood sums that yield 1
NUM_READ     = 4         -- read heads / outputs
GENS_PER_REV = 4         -- CA generations per ring revolution

CLOCK_THRESH = 1.0       -- in1 rising-edge threshold (V)
CLOCK_HYST   = 0.1       -- in1 hysteresis (V)
DATA_THRESH  = 1.0       -- in2 threshold (V)
DATA_HYST    = 0.2       -- in2 hysteresis (V), applied between clock samples

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------
cells       = {}   -- cells[0..L-1], current generation
buf         = {}   -- next-generation buffer
pending     = {}   -- pending[0..L-1], input bits awaiting the next generation
offsets     = {}   -- offsets[1..NUM_READ], relative to write head
boundaries  = {}   -- boundaries[1..GENS_PER_REV], clock counts within a revolution
wpos        = 0    -- write head (== read head 1)
clock_count = 0    -- clocks completed in current revolution
gen_idx     = 1    -- next boundary to reach
data_bit    = 0    -- last sampled data bit (for hysteresis)

-- Split L clocks into GENS_PER_REV segments. Each gets floor(L/n); the
-- remainder adds one clock to segments in priority order last, first,
-- second, ... This reproduces 17 -> 4,4,4,5 and 19 -> 5,5,4,5.
function compute_schedule(len)
  local n = GENS_PER_REV
  local seg = {}
  for i = 1, n do seg[i] = len // n end
  local order = {n}
  for i = 1, n - 1 do order[#order + 1] = i end
  for k = 1, len % n do seg[order[k]] = seg[order[k]] + 1 end

  local starts, ends = {}, {}
  local acc = 0
  for i = 1, n do
    starts[i] = acc
    acc = acc + seg[i]
    ends[i] = acc
  end
  return seg, starts, ends
end

-- Read head offsets: start of each segment. Only valid when NUM_READ equals
-- GENS_PER_REV (both 4 in v1), which keeps heads aligned with quadrants.
function compute_offsets(len)
  local _, starts = compute_schedule(len)
  local offs = {}
  for i = 1, NUM_READ do offs[i] = starts[i] end
  return offs
end

function reset_state()
  for i = 0, L - 1 do
    cells[i] = 0
    buf[i] = 0
    pending[i] = 0
  end
  for i = L, #cells do cells[i] = nil; buf[i] = nil; pending[i] = nil end
  offsets = compute_offsets(L)
  local _, _, ends = compute_schedule(L)
  boundaries = ends
  wpos = 0
  clock_count = 0
  gen_idx = 1
  data_bit = 0
end

-- one synchronous generation of the radius-2 totalistic rule
function ca_step()
  for x = 0, L - 1 do
    local sum = 0
    for d = -RADIUS, RADIUS do
      sum = sum + cells[(x + d) % L]
    end
    buf[x] = BIRTH[sum] and 1 or 0
  end
  cells, buf = buf, cells
end

-- OR pending input bits into the ring and clear them
function merge_pending()
  for x = 0, L - 1 do
    if pending[x] == 1 then
      cells[x] = 1
      pending[x] = 0
    end
  end
end

-- number of active cells in the five-cell window centred on p
function population_at(p)
  local sum = 0
  for d = -RADIUS, RADIUS do
    sum = sum + cells[(p + d) % L]
  end
  return sum
end

local function sample_data()
  local v = input[2].volts
  if data_bit == 1 then
    if v < DATA_THRESH - DATA_HYST then data_bit = 0 end
  else
    if v >= DATA_THRESH then data_bit = 1 end
  end
  return data_bit
end

function on_clock()
  -- 1-2. snapshot all four populations, then set outputs (volts = population)
  local pop = {}
  for i = 1, NUM_READ do
    pop[i] = population_at((wpos + offsets[i]) % L)
  end
  for i = 1, NUM_READ do
    output[i].volts = pop[i]
  end

  -- 3-4. sample data, OR into the pending cell under the write head
  if sample_data() == 1 then pending[wpos] = 1 end

  -- 5. advance all heads together
  wpos = (wpos + 1) % L
  clock_count = clock_count + 1

  -- 6. at generation boundaries, admit pending bits and evolve (outputs untouched)
  if clock_count == boundaries[gen_idx] then
    merge_pending()
    ca_step()
    gen_idx = gen_idx + 1
  end
  if clock_count >= L then
    clock_count = 0
    gen_idx = 1
  end
end

function init()
  reset_state()
  for i = 1, NUM_READ do
    output[i].slew = 0
    output[i].volts = 0
  end
  input[2].mode('none')
  input[1].mode('change', CLOCK_THRESH, CLOCK_HYST, 'rising')
  input[1].change = function() on_clock() end
end
