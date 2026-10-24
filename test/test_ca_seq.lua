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

local function out(i) return output[i].volts end

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
  for _ = 1, 40 do
    -- input high writes under write head; out1 must see that same cell
    local w = wpos
    clock(1)
    assert(out(1) == GATE_HIGH_V)
    assert(cells ~= nil and offsets[1] == 0)
    assert((w + offsets[1]) % L == w)
  end
end)

test('read heads observe cells at their offsets', function()
  start(17)
  for step = 0, 40 do
    -- fresh ring each time with markers only at the four head positions
    -- for head i -> cell value 1 if i is odd. Cells cleared on next set.
    local w = wpos
    local t = {}
    for i = 1, 4 do t[((w + offsets[i]) % L) + 1] = (i % 2) end
    set_cells(t)
    local saved_boundary = boundaries
    boundaries = {} -- disable evolution for this check
    clock(0)
    boundaries = saved_boundary
    gen_idx = 1
    for i = 1, 4 do
      local exp = (i % 2 == 1) and GATE_HIGH_V or GATE_LOW_V
      assert(out(i) == exp, ('step %d head %d'):format(step, i))
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
-- writing
---------------------------------------------------------------------------
test('high input injects before reading (out1 high same clock)', function()
  start(17)
  assert(cells[0] == 0)
  clock(1)
  assert(out(1) == GATE_HIGH_V)
end)

test('low input never erases a cell', function()
  start(17)
  set_cells({1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1})
  boundaries = {}  -- no evolution: isolate the write operation
  for _ = 1, 17 * 2 do
    local w = wpos
    clock(0)
    assert(cells[w] == 1, 'cell ' .. w .. ' erased')
  end
end)

test('output 1 is a superset of data input over long run (all lengths)', function()
  for _, len in ipairs({17, 24, 19, 16}) do
    start(len)
    seed = 99 + len
    local extra = 0
    for _ = 1, 2000 do
      local b = lcg_bit()
      clock(b)
      if b == 1 then
        assert(out(1) == GATE_HIGH_V, 'L=' .. len .. ' clock ' .. clock_n)
      elseif out(1) == GATE_HIGH_V then
        extra = extra + 1
      end
    end
  end
end)

test('data hysteresis: value inside band holds previous bit', function()
  start(17)
  input[2].volts = DATA_THRESH - DATA_HYST / 2
  input[1].change(true)
  assert(out(1) == GATE_LOW_V, 'band from low stays low')
  input[2].volts = 5
  input[1].change(true)
  assert(out(1) == GATE_HIGH_V)
  input[2].volts = DATA_THRESH - DATA_HYST / 2
  input[1].change(true)
  assert(out(1) == GATE_HIGH_V, 'band from high stays high')
end)

---------------------------------------------------------------------------
-- output behavior
---------------------------------------------------------------------------
test('consecutive active cells give one continuous gate (no low writes)', function()
  start(17)
  for _ = 1, 10 do clock(1) end
  local o1 = {}
  for _, e in ipairs(log) do if e.out == 1 then o1[#o1 + 1] = e end end
  assert(#o1 == 1 and o1[1].v == GATE_HIGH_V,
    'out1 should be written high exactly once, got ' .. #o1 .. ' writes')
end)

test('outputs only change inside on_clock step 4; evolution writes nothing', function()
  start(17)
  seed = 7
  for _ = 1, 17 * 4 do clock(lcg_bit()) end
  log = {}
  -- running ca_step directly must not touch outputs
  for _ = 1, 10 do ca_step() end
  assert(#log == 0, 'ca_step wrote outputs')
end)

test('no extra transitions at generation boundaries', function()
  -- Each clock produces at most one write per output, and only when the
  -- read value changed: so writes per clock <= 4 and never a high->low->high
  -- blip within one clock.
  start(17)
  seed = 31
  for _ = 1, 17 * 20 do clock(lcg_bit()) end
  local per = {}
  for _, e in ipairs(log) do
    local k = e.clock * 10 + e.out
    per[k] = (per[k] or 0) + 1
    assert(per[k] == 1, 'output ' .. e.out .. ' written twice on clock ' .. e.clock)
  end
  -- and consecutive writes to an output always alternate level
  local last = {}
  for _, e in ipairs(log) do
    assert(last[e.out] ~= e.v, 'redundant write on out ' .. e.out)
    last[e.out] = e.v
  end
end)

test('all heads share one CA state', function()
  start(17)
  boundaries = {}  -- freeze evolution
  clock(1)         -- writes cell 0
  -- head i reaches cell 0 when wpos + offset[i] == 0 (mod L)
  local seen = {false, false, false, false}
  for _ = 1, 16 do
    local w = wpos
    clock(0)
    for i = 2, 4 do
      if (w + offsets[i]) % L == 0 then
        assert(out(i) == GATE_HIGH_V, 'head ' .. i .. ' did not see cell 0')
        seen[i] = true
      end
    end
  end
  assert(seen[2] and seen[3] and seen[4])
end)

test('reset leaves all outputs low and state cleared', function()
  start(17)
  for _ = 1, 30 do clock(1) end
  init()
  for i = 1, 4 do assert(out(i) == GATE_LOW_V) end
  for i = 0, L - 1 do assert(cells[i] == 0) end
  assert(wpos == 0 and clock_count == 0 and gen_idx == 1)
end)

test('switching L resizes ring cleanly', function()
  start(24)
  for _ = 1, 30 do clock(1) end
  start(16)
  local n = 0
  for _ in pairs(cells) do n = n + 1 end
  assert(n == 16, 'cells has ' .. n .. ' entries')
end)

print(('\n%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
