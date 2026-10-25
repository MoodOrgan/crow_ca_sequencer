-- Hardware-free test harness for ca_seq.lua.
-- Run from the repo root:  lua test/test_ca_seq.lua

---------------------------------------------------------------------------
-- crow stubs
---------------------------------------------------------------------------
local log = {}  -- every output voltage write: {out = i, v = volts, clock = n}
local clock_n = 0

local function make_output(i)
  local o = {slew = 0, _v = 0}
  return setmetatable({}, {
    __index = function(_, k) if k == 'volts' then return o._v end return o[k] end,
    __newindex = function(_, k, v)
      if k == 'volts' then
        o._v = v
        log[#log + 1] = {out = i, v = v, clock = clock_n}
      else
        o[k] = v
      end
    end,
  })
end

output = {}
for i = 1, 4 do output[i] = make_output(i) end
input = {}
for i = 1, 2 do
  input[i] = {volts = 0, mode = function(...) end}
end

local script = arg and arg[0] and arg[0]:match('^(.*)test/') or ''
dofile(script .. 'ca_seq.lua')

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function start(len)
  L = len or 17
  log = {}
  clock_n = 0
  init()
  log = {}
end

local function clock(bit)
  input[2].volts = (bit == 1) and 5 or 0
  clock_n = clock_n + 1
  input[1].change(true)
end

-- outputs read back as populations (volts / VOLTS_PER_CELL)
local function out(i) return output[i].volts / VOLTS_PER_CELL end

local function set_cells(t)
  for i = 0, L - 1 do cells[i] = t[i + 1] or 0 end
end

local function eq_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function fmt(t)
  local s = {}
  for i = 1, #t do s[i] = tostring(t[i]) end
  return '{' .. table.concat(s, ',') .. '}'
end

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('ok   ' .. name)
  else
    failed = failed + 1
    print('FAIL ' .. name .. '\n     ' .. tostring(err))
  end
end

-- deterministic pseudo-random bits (test input only; the script has none)
local seed = 12345
local function lcg_bit()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return (seed >> 16) & 1
end

---------------------------------------------------------------------------
-- CA rule
---------------------------------------------------------------------------
test('neighborhood sums 0..5: only 2 and 4 are born', function()
  local patterns = {
    [0] = {0, 0, 0, 0, 0},
    [1] = {0, 0, 1, 0, 0},
    [2] = {1, 0, 0, 0, 1},
    [3] = {1, 0, 1, 0, 1},
    [4] = {1, 1, 0, 1, 1},
    [5] = {1, 1, 1, 1, 1},
  }
  for sum = 0, 5 do
    start(17)
    -- centre cell 8, neighborhood cells 6..10; rest zero
    local t = {}
    for k = 1, 5 do t[6 + k] = patterns[sum][k] end
    set_cells(t)
    ca_step()
    local expect = (sum == 2 or sum == 4) and 1 or 0
    assert(cells[8] == expect,
      ('sum %d -> %d, expected %d'):format(sum, cells[8], expect))
  end
end)

test('isolated cell dies', function()
  start(17)
  cells[5] = 1
  ca_step()
  for i = 0, L - 1 do assert(cells[i] == 0) end
end)

test('synchronous update matches reference computed from old generation', function()
  start(17)
  local init_t = {1,1,0,1,0,0,1,1,1,0,0,0,1,0,1,1,0}
  set_cells(init_t)
  local old = {}
  for i = 0, L - 1 do old[i] = cells[i] end
  local expect = {}
  for x = 0, L - 1 do
    local s = 0
    for d = -2, 2 do s = s + old[(x + d) % L] end
    expect[x] = (s == 2 or s == 4) and 1 or 0
  end
  ca_step()
  for x = 0, L - 1 do
    assert(cells[x] == expect[x], 'cell ' .. x)
  end
end)

test('wraparound: neighborhood spans ring seam', function()
  start(17)
  -- cells 16 and 1 active: cell 0 sees sum 2 via wrap (15,16,0,1,2)
  cells[16] = 1; cells[1] = 1
  ca_step()
  assert(cells[0] == 1, 'cell 0 should be born across seam')
  -- cell 15: neighbors 13,14,15,16,0 -> sum 1 -> 0
  assert(cells[15] == 0)
  -- cell 2: 0,1,2,3,4 -> sum 1 -> 0
  assert(cells[2] == 0)
  -- cell 16: 14,15,16,0,1 -> sum 2 -> 1
  assert(cells[16] == 1)
  -- cell 1: 16,0,1,2,3 -> sum 2 -> 1
  assert(cells[1] == 1)
end)
---------------------------------------------------------------------------
-- population mapping
---------------------------------------------------------------------------
-- reference population, computed independently of the script
local function ref_pop(p)
  local s = 0
  for d = -2, 2 do s = s + cells[(p + d) % L] end
  return s
end

local function freeze() boundaries = {} end  -- disable evolution

test('populations 0..5 produce exactly 0..5 V', function()
  local windows = {
    [0] = {0, 0, 0, 0, 0},
    [1] = {0, 0, 0, 1, 0},
    [2] = {1, 0, 0, 0, 1},
    [3] = {0, 1, 1, 1, 0},
    [4] = {1, 1, 0, 1, 1},
    [5] = {1, 1, 1, 1, 1},
  }
  for pop = 0, 5 do
    start(17)
    freeze()
    -- read head 1 at cell 0: window is cells 15,16,0,1,2
    local idx = {15, 16, 0, 1, 2}
    for k = 1, 5 do cells[idx[k]] = windows[pop][k] end
    clock(0)
    assert(out(1) == pop, ('population %d -> %s V'):format(pop, tostring(out(1))))
  end
end)

test('output volts = population x VOLTS_PER_CELL, max within crow range', function()
  assert(VOLTS_PER_CELL == 2.0, 'default scale changed')
  assert(5 * VOLTS_PER_CELL <= 10, 'full population exceeds crow 10 V')
  start(17)
  freeze()
  for x = 0, L - 1 do cells[x] = 0 end
  cells[16] = 1; cells[0] = 1; cells[1] = 1
  clock(0)
  assert(output[1].volts == 3 * VOLTS_PER_CELL, 'got ' .. output[1].volts)
end)

test('population window wraps at cells 0 and L-1', function()
  start(17)
  freeze()
  cells[16] = 1; cells[15] = 1; cells[1] = 1
  assert(population_at(0) == 3, 'p=0: ' .. population_at(0))
  assert(population_at(16) == 3, 'p=16: ' .. population_at(16)) -- 14,15,16,0,1
  assert(population_at(1) == 2, 'p=1: ' .. population_at(1))   -- 16,0,1,2,3
end)

test('centre cell 0 can still produce nonzero output', function()
  start(17)
  freeze()
  cells[16] = 1; cells[1] = 1  -- centre cell 0 stays 0
  clock(0)
  assert(cells[0] == 0)
  assert(out(1) == 2, 'expected 2 V, got ' .. out(1))
end)

---------------------------------------------------------------------------
-- head movement
---------------------------------------------------------------------------
test('L=17 offsets [0,4,8,12] fixed relative to write head across wraps', function()
  start(17)
  assert(eq_list(offsets, {0, 4, 8, 12}), fmt(offsets))
  for n = 1, 17 * 3 + 5 do
    clock(0)
    assert(wpos == n % 17, 'write head position after ' .. n .. ' clocks')
    assert(eq_list(offsets, {0, 4, 8, 12}), 'offsets drifted: ' .. fmt(offsets))
  end
end)

test('read head 1 is coincident with write head', function()
  start(17)
  assert(offsets[1] == 0)
  freeze()
  for _ = 1, 40 do
    local w = wpos
    clock(1)
    assert(pending[w] == 1, 'write landed at ' .. w)
  end
end)

test('each output reads the population at its own head (all lengths)', function()
  for _, len in ipairs({17, 24, 19, 16}) do
    start(len)
    seed = 5 + len
    for x = 0, L - 1 do cells[x] = lcg_bit() end
    for _ = 1, 3 * len do
      local exp = {}
      for i = 1, 4 do exp[i] = ref_pop((wpos + offsets[i]) % L) end
      clock(lcg_bit())
      for i = 1, 4 do
        assert(out(i) == exp[i], ('L=%d clock %d out %d: %s ~= %d')
          :format(len, clock_n, i, tostring(out(i)), exp[i]))
      end
    end
  end
end)

---------------------------------------------------------------------------
-- generation boundaries
---------------------------------------------------------------------------
local function observed_gen_clocks(len, revs)
  start(len)
  local real_step = ca_step
  local hits = {}
  ca_step = function() hits[#hits + 1] = clock_n; real_step() end
  for _ = 1, len * revs do clock(0) end
  ca_step = real_step
  -- convert to intervals
  local iv, prev = {}, 0
  for k = 1, #hits do iv[k] = hits[k] - prev; prev = hits[k] end
  return iv, hits
end

local specs = {
  [17] = {offs = {0, 4, 8, 12},  seg = {4, 4, 4, 5}},
  [24] = {offs = {0, 6, 12, 18}, seg = {6, 6, 6, 6}},
  [19] = {offs = {0, 5, 10, 14}, seg = {5, 5, 4, 5}},
  [16] = {offs = {0, 4, 8, 12},  seg = {4, 4, 4, 4}},
}

for _, len in ipairs({17, 24, 19, 16}) do
  test(('L=%d schedule %s, offsets %s'):format(len, fmt(specs[len].seg),
      fmt(specs[len].offs)), function()
    local seg = compute_schedule(len)
    assert(eq_list(seg, specs[len].seg), fmt(seg))
    assert(eq_list(compute_offsets(len), specs[len].offs))
    local revs = 5
    local iv = observed_gen_clocks(len, revs)
    assert(#iv == 4 * revs, 'generations: ' .. #iv)
    for k = 1, #iv do
      assert(iv[k] == specs[len].seg[(k - 1) % 4 + 1],
        'interval ' .. k .. ' = ' .. iv[k])
    end
  end)
end

test('L=17 evolves after clocks 4,8,12,17 of each revolution', function()
  local _, hits = observed_gen_clocks(17, 3)
  local expect = {4, 8, 12, 17, 21, 25, 29, 34, 38, 42, 46, 51}
  assert(eq_list(hits, expect), fmt(hits))
end)

---------------------------------------------------------------------------
-- read before write
---------------------------------------------------------------------------
test('injected bit: all heads read pre-write state, bit stored after read', function()
  start(17)
  clock(1)  -- write position 0
  for i = 1, 4 do assert(out(i) == 0, 'out ' .. i .. ' = ' .. out(i)) end
  assert(pending[0] == 1, 'bit not stored')
  assert(cells[0] == 0, 'bit entered ring before a generation')
end)

test('unevolved input is never heard', function()
  -- inputs written during the first segment (clocks 1-4) must not reach any
  -- output until the generation at the end of clock 4
  start(17)
  for n = 1, 4 do
    clock(1)
    for i = 1, 4 do assert(out(i) == 0, ('clock %d out %d'):format(n, i)) end
  end
end)

test('ring changes only at generation boundaries', function()
  for _, len in ipairs({17, 24, 19, 16}) do
    start(len)
    seed = 77 + len
    local bset = {}
    for _, b in ipairs(boundaries) do bset[b] = true end
    for _ = 1, 10 * len do
      local before = {}
      for x = 0, L - 1 do before[x] = cells[x] end
      local count_before = clock_count
      clock(lcg_bit())
      if not bset[count_before + 1] then
        for x = 0, L - 1 do
          assert(cells[x] == before[x], ('L=%d ring changed off-boundary'):format(len))
        end
      end
    end
  end
end)

test('evolved descendants of input reach the outputs', function()
  start(17)
  -- bits at cells 0 and 2 (clocks 1 and 3) merge at clock 4 and evolve to
  -- {0,1,2}; with {2,4} a lone bit would simply die
  clock(1); clock(0); clock(1); clock(0)
  assert(eq_list({cells[0], cells[1], cells[2], cells[3], cells[4]}, {1, 1, 1, 0, 0}),
    'unexpected generation')
  local heard = false
  for _ = 1, 17 do
    clock(0)
    for i = 1, 4 do if out(i) > 0 then heard = true end end
  end
  assert(heard, 'descendants never reached an output')
end)

test('low input never erases a cell', function()
  start(17)
  set_cells({1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1})
  freeze()
  for _ = 1, 17 * 2 do clock(0) end
  for x = 0, L - 1 do assert(cells[x] == 1, 'cell ' .. x .. ' erased') end
end)

test('pending bits OR into ring (do not clear existing cells)', function()
  start(17)
  cells[5] = 1
  pending[6] = 1
  merge_pending()
  assert(cells[5] == 1 and cells[6] == 1 and pending[6] == 0)
end)

test('data hysteresis: value inside band holds previous bit', function()
  start(17)
  freeze()
  input[2].volts = DATA_THRESH - DATA_HYST / 2
  input[1].change(true)
  assert(pending[0] == 0, 'band from low stays low')
  input[2].volts = 5
  input[1].change(true)
  assert(pending[1] == 1)
  input[2].volts = DATA_THRESH - DATA_HYST / 2
  input[1].change(true)
  assert(pending[2] == 1, 'band from high stays high')
end)

---------------------------------------------------------------------------
-- snapshot consistency and timing
---------------------------------------------------------------------------
test('all four populations come from one snapshot (incl. boundary clocks)', function()
  start(17)
  seed = 3
  for x = 0, L - 1 do cells[x] = lcg_bit() end
  for _ = 1, 17 * 4 do
    local exp = {}
    for i = 1, 4 do exp[i] = ref_pop((wpos + offsets[i]) % L) end
    -- make every write high, so any read-after-write would show up
    clock(1)
    for i = 1, 4 do assert(out(i) == exp[i], 'clock ' .. clock_n .. ' out ' .. i) end
  end
end)

test('every clock writes each output exactly once', function()
  start(17)
  seed = 31
  local n = 17 * 20
  for _ = 1, n do clock(lcg_bit()) end
  local per = {}
  for _, e in ipairs(log) do
    local k = e.clock * 10 + e.out
    per[k] = (per[k] or 0) + 1
  end
  for c = 1, n do
    for i = 1, 4 do
      assert(per[c * 10 + i] == 1, ('clock %d out %d writes: %s'):format(c, i,
        tostring(per[c * 10 + i])))
    end
  end
end)

test('evolution and merging write no outputs', function()
  start(17)
  seed = 7
  for _ = 1, 17 * 4 do clock(lcg_bit()) end
  log = {}
  for _ = 1, 10 do merge_pending(); ca_step() end
  assert(#log == 0, 'outputs written outside on_clock')
end)

test('outputs are integer volts 0..5 with no zero inserted between steps', function()
  start(17)
  seed = 11
  for x = 0, L - 1 do cells[x] = lcg_bit() end
  for _ = 1, 17 * 10 do clock(lcg_bit()) end
  for _, e in ipairs(log) do
    local p = e.v / VOLTS_PER_CELL
    assert(p >= 0 and p <= 5 and p == math.floor(p), "bad volts " .. e.v)
  end
  -- one write per output per clock (above) means a held level between
  -- clocks; check a nonzero run stays nonzero when populations are nonzero
  start(17)
  freeze()
  for x = 0, L - 1 do cells[x] = 1 end
  for _ = 1, 17 do clock(0) end
  for _, e in ipairs(log) do assert(e.v == 5 * VOLTS_PER_CELL) end
end)

test('all heads share one CA state', function()
  start(17)
  freeze()
  cells[0] = 1
  local seen = {false, false, false, false}
  for _ = 1, 17 do
    local w = wpos
    clock(0)
    for i = 1, 4 do
      local p = (w + offsets[i]) % L
      local d = (p - 0) % L
      if d <= 2 or d >= L - 2 then
        assert(out(i) == 1, 'head ' .. i .. ' did not see cell 0')
        seen[i] = true
      end
    end
  end
  assert(seen[1] and seen[2] and seen[3] and seen[4])
end)

---------------------------------------------------------------------------
-- reset / regression
---------------------------------------------------------------------------
test('reset leaves all outputs 0 V and state cleared', function()
  start(17)
  for _ = 1, 30 do clock(1) end
  init()
  for i = 1, 4 do assert(out(i) == 0) end
  for i = 0, L - 1 do assert(cells[i] == 0 and pending[i] == 0) end
  assert(wpos == 0 and clock_count == 0 and gen_idx == 1)
end)

test('switching L resizes ring cleanly', function()
  start(24)
  for _ = 1, 30 do clock(1) end
  start(16)
  local n, m = 0, 0
  for _ in pairs(cells) do n = n + 1 end
  for _ in pairs(pending) do m = m + 1 end
  assert(n == 16 and m == 16, ('cells %d, pending %d entries'):format(n, m))
end)

test('two independent instances run identical code deterministically', function()
  local function run(clock_bits)
    start(17)
    local trace = {}
    for _, b in ipairs(clock_bits) do
      clock(b)
      trace[#trace + 1] = out(1) .. out(2) .. out(3) .. out(4)
    end
    return table.concat(trace, ' ')
  end
  seed = 2024
  local bits = {}
  for k = 1, 500 do bits[k] = lcg_bit() end
  assert(run(bits) == run(bits), 'same input gave different output')
end)

test('default ring length is 17', function()
  local src = io.open(script .. 'ca_seq.lua'):read('a')
  assert(src:match('\nL%s*=%s*17%s'), 'L = 17 not the default')
end)

print(('\n%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
