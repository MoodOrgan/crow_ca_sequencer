# crow CA percussion sequencer

A four-channel gate sequencer for [monome crow](https://monome.org/docs/crow/), built to drive four voices of a Landscape Noon.

A one-dimensional binary cellular automaton runs on a ring of `L` cells. Four read heads turn its state into four held gates. A write head, coincident with read head 1, ORs an external binary signal into the ring. The script has no randomness and no presets. It starts silent, and the data you feed it is the only thing that brings it to life.

Both crows run the same script. Give them different clocks (for example 2:3) and different data to get two related, independently evolving parts.

The full spec is in [`CLAUDE.md`](CLAUDE.md).

## Wiring

| Jack | Function |
|---|---|
| in 1 | Clock. Each rising edge through 1.0 V (0.1 V hysteresis) advances the sequencer one step. |
| in 2 | Binary data. It is sampled once per clock: high (≥ 1.0 V) writes a 1 into the ring, and low leaves the ring unchanged. |
| out 1–4 | Held gates from read heads 1–4: `GATE_HIGH_V` when the cell is 1, 0 V when it is 0. |

Out 1 sits on the write head, so it is always high on a clock where in 2 is high. It can also go high when the CA itself is active, which makes it a superset of the input rather than a copy.

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
| `L` | 17 | Ring length. The spec also covers 24, 19 and 16. |
| `RADIUS` | 2 | Five-cell neighborhood |
| `BIRTH` | `{2,4}` | Neighborhood sums that produce a live cell (totalistic) |
| `GENS_PER_REV` | 4 | CA generations per ring revolution |
| `GATE_HIGH_V` / `GATE_LOW_V` | 5.0 / 0.0 | Gate levels |
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

1. Sample in 2 and convert it to a bit.
2. OR the bit into the cell under the write head.
3. Read the four cells under the read heads.
4. Set the outputs. An output is written only when its value changes, so runs of 1s produce one unbroken gate.
5. Advance all heads by one cell, modulo `L`.
6. If this clock ends a generation segment, evolve the whole CA once, synchronously. This never touches the outputs.

Gates are plain `output[n].volts` assignments with `slew = 0`. The script uses no `action`/`pulse` envelopes.

## Reset behavior

When the script starts or restarts (`init()`):

- All cells are set to 0.
- The write head returns to cell 0, and the read heads return to their offsets.
- The clock and generation counters are cleared.
- All outputs are set to 0 V.

The script does not seed itself, reseed itself or detect inactivity.

## Electrical notes: verify before use

- The crow docs give an output range of about −5 V to +10 V, which makes 5 V gates a conservative default. The docs do not give an output current or output impedance figure.
- The Noon's gate/trigger input threshold and input impedance are **not confirmed here**. Check Landscape's documentation. Most Eurorack gate inputs are high impedance and 5 V is fine. If the Noon's inputs draw significant current, or several inputs are driven from one output, put a buffer (for example a buffered mult) between crow and Noon. A voltage spec alone does not guarantee compatibility.
- If the Noon needs a higher gate level, raise `GATE_HIGH_V` (up to crow's 10 V maximum).

## Tests

The harness runs the actual `ca_seq.lua` against stubbed crow `input`/`output` tables. It needs no hardware.

```
lua test/test_ca_seq.lua
```

It covers the CA rule (all neighborhood sums, synchronous update, wraparound), head geometry, generation schedules for all four lengths, OR-writing, the output 1 superset property, continuous gates, the absence of extra transitions at generation boundaries, shared state across heads, and reset.
