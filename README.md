# crow CA percussion sequencer

A four-channel voltage sequencer for [monome crow](https://monome.org/docs/crow/), built to drive four voices of a Landscape Noon.

A one-dimensional binary cellular automaton runs on a ring of `L` cells. Four read heads move around the ring. Each one outputs a voltage set by the number of live cells in the five-cell window around it. An empty window gives 0 V, and 1–5 live cells are spread evenly from 3 V to 5 V. A write head, coincident with read head 1, ORs an external binary signal into the ring. The script has no randomness and no presets. It starts silent, and the data you feed it is the only thing that brings it to life.

Input is never heard directly. Incoming bits wait in a pending buffer and only enter the ring at the next generation, where they are evolved straight away. The automaton therefore sets both the timing and the voltage of every output.

Both crows run the same script. Give them different clocks (for example 2:3) and different data to get two related, independently evolving parts.

The original v1 spec is in [`CLAUDE.md`](CLAUDE.md).

## Wiring

| Jack | Function |
|---|---|
| in 1 | Clock. Each rising edge through 1.0 V (0.1 V hysteresis) advances the sequencer one step. |
| in 2 | Binary data. It is sampled once per clock: high (≥ 1.0 V) marks the cell under the write head for injection at the next generation, and low changes nothing. |
| out 1–4 | Held voltages from read heads 1–4, set by the five-cell population at each head: 0 V when the window is empty, otherwise 3–5 V. |

## Output voltage

For a read head at cell `p`, the output is the population of `[p-2 … p+2]`, with indices wrapping modulo `L`:

| Live cells in window | Output |
|---|---|
| 0 | 0 V |
| 1 | 3.0 V |
| 2 | 3.5 V |
| 3 | 4.0 V |
| 4 | 4.5 V |
| 5 | 5.0 V |

An empty window is silent. Any live cell lifts the output to at least `V_MIN` (3 V), and the remaining populations are spaced evenly up to `V_MAX` (5 V). A plain 1 V-per-cell mapping left the low populations too quiet on Noon. This mapping keeps every active step clearly audible and lets density shape the dynamics. The centre cell does not decide whether the output is on: a 0 in the centre with live neighbours still produces a voltage. Each output acts as a moving sensor of local density.

Each output holds its voltage until the next clock. The script never adds triggers, zero gaps, slew or envelopes, and it does not touch the outputs at generation boundaries. A run of populations such as `0,1,3,4,2,2,0` comes out as one stepped voltage: 0 V, 3 V, 4 V, 4.5 V, 3.5 V, 3.5 V, 0 V.

## Install

Using [druid](https://monome.org/docs/crow/druid/):

```
druid
> u ca_seq.lua     # upload and save to flash (runs at power-up)
> r ca_seq.lua     # or: run once without saving
```

You can also send it from norns/maiden or the crow web tools. Upload the identical file to both crows.

## Parameters

These are constants at the top of `ca_seq.lua`:

| Constant | Default | Notes |
|---|---|---|
| `L` | 17 | Ring length. 24, 19 and 16 are also supported. |
| `RADIUS` | 2 | Five-cell neighborhood, used by both the rule and the population window |
| `BIRTH` | `{2,4}` | Neighborhood sums that produce a live cell (totalistic) |
| `GENS_PER_REV` | 4 | CA generations per ring revolution |
| `V_MIN`, `V_MAX` | 3.0, 5.0 | Output for population 1 and population 5. Population 0 is always 0 V. |
| `CLOCK_THRESH`, `CLOCK_HYST` | 1.0, 0.1 | Input 1 edge detection |
| `DATA_THRESH`, `DATA_HYST` | 1.0, 0.2 | Input 2 threshold. Hysteresis keeps the previous bit while the voltage sits inside the band. |

Offsets and generation timing are calculated from `L`. Each of the 4 segments gets `floor(L/4)` clocks, and the remainder adds one clock each to segments in the order last, first, second, third:

| L | Read offsets | Clocks per generation |
|---|---|---|
| 17 | 0, 4, 8, 12 | 4, 4, 4, 5 |
| 24 | 0, 6, 12, 18 | 6, 6, 6, 6 |
| 19 | 0, 5, 10, 14 | 5, 5, 4, 5 |
| 16 | 0, 4, 8, 12 | 4, 4, 4, 4 |

## Order of operations on each clock

1. Take the five-cell populations at all four read heads from one snapshot of the ring.
2. Set all four outputs (`output[n].volts = population_volts(population)`).
3. Sample in 2 and convert it to a bit.
4. OR the bit into the **pending** buffer at the write head.
5. Advance all heads by one cell, modulo `L`.
6. If this clock ends a generation segment, OR the pending bits into the ring, clear the buffer, and evolve the whole CA once, synchronously. This step never touches the outputs.

Steps 4 and 6 differ from a plain "OR into the ring". If bits went straight into the ring, read head 1's five-cell window would catch them on the next two clocks, and head 4 could catch them a few clocks later, before any generation had passed. The pending buffer guarantees that a written bit only affects the outputs after it has been evolved. One result: under `{2,4}` an isolated bit dies on its first generation, so a single high pulse makes no sound. Bits only survive when nearby bits are injected in the same segment.

Outputs are plain `output[n].volts` assignments with `slew = 0`. The script uses no `action`/`pulse` envelopes.

## Reset behavior

When the script starts or restarts (`init()`):

- All cells and pending bits are set to 0.
- The write head returns to cell 0, and the read heads return to their offsets.
- The clock and generation counters are cleared.
- All outputs are set to 0 V.

The script does not seed itself, reseed itself or detect inactivity.

## Noon compatibility

Landscape lists "Eurorack modular systems" among its strongest recommendations for driving Noon ([landscape.fm/noon](https://www.landscape.fm/noon)). Crow is a Eurorack module, so its outputs can be patched straight into Noon's gate inputs.

Noon has no power supply. According to the [manual](https://www.landscape.fm/s/Noon-Manual-baw6.pdf), each channel's analog circuit is "powered and controlled directly from its respective gate input". This affects the sound:

- **Voltage changes the sound.** The population output therefore sets how hard each voice is driven, step by step. The manual also notes that pitch CV sent to the gate inputs produces "additional behaviors".
- **Gate length matters.** The manual says sequencers that can vary gate length are "highly encouraged", and that trigger-only signals weaken the response. Channels 7 and 8 (Larynx, Bacid) work best with gates rather than triggers. That is why this script holds its voltages.
- Use one crow output per Noon gate input.

## Tests

The harness runs the actual `ca_seq.lua` against stubbed crow `input`/`output` tables. It needs no hardware.

```
lua test/test_ca_seq.lua
```

It covers:

- The CA rule: all neighborhood sums, synchronous update and wraparound.
- The population mapping (0 V, then 3–5 V), wraparound, and a nonzero output when the centre cell is 0.
- Head geometry and the generation schedules for all four lengths.
- Read-before-write: unevolved input is never heard, the ring only changes at generation boundaries, and evolved descendants do reach the outputs.
- OR-writing and data hysteresis.
- Snapshot consistency.
- Exactly one write per output per clock, and no output writes from evolution.
- Shared state across heads, reset, and determinism.
