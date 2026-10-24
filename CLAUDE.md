# Crow Cellular Automaton Percussion Sequencer
## Implementation specification — v1

### Objective

Implement a generative four-channel gate sequencer on **monome Crow**, intended to drive four voices of a Landscape Noon.

Two independent Crows will run **exactly the same program**, generally receiving different clock signals (often in a 2:3 relationship) and potentially different binary data signals.

Each Crow maintains a one-dimensional binary cellular automaton on a circular ring. Four rotating read heads convert the CA state into four gate outputs. A fifth, coincident write head injects external data into the automaton.

The resulting percussion should exhibit recognizable input-derived rhythms, evolving branches, sustained gates, and emergent repetition. It must not depend on conventional step-sequencer patterns or random trigger generation.

### 1. Initial configuration

| Parameter | Initial value |
|---|---|
| CA rule | Radius-2 totalistic `{2,4}` |
| Ring length `L` | **17** |
| Alternative lengths | **24, 19, 16** |
| Number of read heads | 4 |
| Number of write heads | 1 |
| Input 1 | Clock |
| Input 2 | Binary data |
| Outputs 1–4 | Held gate voltages |
| CA generation rate | Four generations per full ring revolution |
| Initial state | All cells zero |
| External write operation | Logical OR |
| Randomness | None |

All parameters should be constants near the top of the script, making later experimentation straightforward.

There must be no code differences between the two Crows.

### 2. Cellular automaton

Use a binary circular array of `L` cells:

`state[0 ... L-1]`

The local neighborhood has radius 2, consisting of five cells:

`[x-2, x-1, x, x+1, x+2]`

All indices wrap modulo `L`.

The next state of a cell depends only on the total number of active cells in that neighborhood:

- Sum = 2 → next state is 1
- Sum = 4 → next state is 1
- Every other sum → next state is 0

All cells must be updated **synchronously** from the same previous generation. Use a separate next-state buffer or equivalent mechanism.

This is the five-neighbor totalistic `{2,4}` rule. It is not elementary Rule 24.

An isolated active cell cannot reproduce; interacting groups of cells can generate branching structures.

### 3. Clocking and head movement

Every rising edge on input 1 advances the write head and all four read heads by **one cell**, modulo `L`.

Heads rotate continuously through 360 degrees. **They do not reset at CA generation boundaries.**

The write head begins at cell 0:

`write_position = 0`

Four read heads have evenly distributed starting offsets, as closely as possible for the chosen circumference:

`read_position[i] = (write_position + offset[i]) % L`

For the initial `L = 17`:

`offsets = [0, 4, 8, 12]`

These offsets remain fixed relative to the write head throughout operation.

The first read head is always coincident with the write head.

### 4. Generation timing

The automaton evolves **four times per complete ring revolution**.

When `L` is divisible by four, generations are equally spaced.

For lengths not divisible by four, distribute the four generation boundaries approximately evenly across the revolution.

Use the following initial schedules:

| L | Read-head offsets | Clocks per generation |
|---|---|---|
| **17** | 0, 4, 8, 12 | 4, 4, 4, 5 |
| **24** | 0, 6, 12, 18 | 6, 6, 6, 6 |
| **19** | 0, 5, 10, 14 | 5, 5, 4, 5 |
| **16** | 0, 4, 8, 12 | 4, 4, 4, 4 |

For `L = 17`, evolution occurs after clock counts 4, 8, 12, and 17 of each revolution.

The generation schedule repeats every `L` clocks, independent of CA state.

Prefer a general implementation that calculates offsets and boundaries deterministically for any valid `L`, while reproducing the specified schedules above.

### 5. External data writing

Input 2 carries a binary signal, sampled once per clock rising edge.

At the current write-head position:

- If input 2 is high, write `1` into the current CA cell.
- If input 2 is low, leave the cell unchanged.

In other words:

`state[write_position] = state[write_position] OR input_bit`

**Do not write zero when the input is low.**

This distinction is essential. External data excites the existing CA rather than replacing its state.

The write head rotates around the entire ring, not just one quadrant. Over one full revolution, it visits every cell once.

### 6. Read heads and gate outputs

Each of the four read heads examines the current binary CA state at its respective position.

Map each read head directly to one Crow output.

- Cell = 1 → output high.
- Cell = 0 → output low.

The outputs are **held gates, not fixed-duration triggers**.

Consecutive active cells must result in an uninterrupted high gate. Do not insert a low pulse between adjacent active cells, between generations, or at the ring boundary.

This is important because the Landscape Noon responds to gate duration as well as gate voltage.

Make the high voltage configurable, initially targeting a voltage appropriate for Noon (subject to confirming Crow's output-drive capability and Noon's electrical requirements). Low is 0 V.

Avoid unnecessary slew, trigger envelopes, or pulse-width processing.

### 7. Exact event ordering

Each incoming clock rising edge should perform the following operations in order:

1. Read input 2 and convert it to a binary value.
2. OR that bit into the CA cell at the current write-head position.
3. Read the four CA cells at the four current read-head positions.
4. Set the four output gate voltages based on those readings.
5. Advance the write head and all four read heads by one position, modulo `L`.
6. If the completed clock crosses the next generation boundary, synchronously evolve the entire CA once.

The outputs from step 4 remain held until the next clock.

Crucially, **writing occurs before reading**, and **evolution occurs after reading**.

Generation boundaries must not themselves cause additional gate transitions.

### 8. Input intelligibility

Because read head 0 is coincident with the write head, output 1 serves as an intelligibility reference.

Whenever the sampled data input is high, output 1 must be high on that clock.

When the data input is low, output 1 may nevertheless be high because of activity generated by the CA.

Thus output 1 is **a superset of the incoming binary data**, not necessarily an exact echo.

This behavior is intentional: the musician can recognize the input's influence without bypassing the CA.

The other three outputs observe the same lattice at approximately quarter-ring offsets, encountering differently evolved structures.

### 9. Reset and initialization

On program start:

- Initialize all CA cells to zero.
- Position the write head at cell 0.
- Position the four read heads at their starting offsets.
- Reset the clock and generation counters.
- Set all four gate outputs low.

The system should become active naturally through external data injection.

Do not introduce automatic random seeding, pattern presets, inactivity detection, or automatic reseeding in v1.

Ensure that a script restart leaves all outputs in a known safe state.

### 10. Crow implementation requirements

Use the actual monome Crow scripting environment and supported Lua API.

Verify the proper methods for:

- Rising-edge clock detection on input 1.
- Sampling input 2 as an analog voltage and thresholding it.
- Directly setting output voltages.
- Starting and restarting a Crow script.

Implement the gate outputs without asynchronous pulse actions that might interfere with held gate states.

Handle clock processing deterministically, including high clock rates, without dropped steps or unintended output transitions.

Configure the binary-input threshold as a constant. Hysteresis is acceptable if needed to prevent threshold chatter, but input 2 should only be sampled on clock edges.

Output voltage and electrical compatibility with Noon should be documented. If Crow cannot safely supply the required current, flag this for hardware buffering rather than assuming voltage specification alone guarantees compatibility.

### 11. Testing

Provide a small software test harness or equivalent unit tests that verify the algorithm independently from Crow hardware.

Required tests:

**CA rule**

Verify all six possible five-cell neighborhood sums. Only sums of 2 and 4 produce an active output.

Verify simultaneous generation updates and circular wraparound.

**Head movement**

At `L = 17`, verify that the four read offsets remain `[0,4,8,12]` relative to the moving write head, including after wraparound.

Verify that read head 0 is always coincident with the write head.

**Generation boundaries**

Verify that `L = 17` produces the repeating schedule `[4,4,4,5]`.

Verify the alternative lengths and schedules in section 4.

**Writing**

Verify that a high input injects a cell before reading.

Verify that a low input never erases a cell.

Verify that output 1 is high whenever the sampled input is high.

**Output behavior**

Verify that consecutive active cells produce continuous high gates.

Verify that generation boundaries do not introduce extra trigger pulses.

Verify that the other three read heads access the same shared CA state, rather than separate automata.

### 12. Deliverables

1. A single deployable Crow Lua script, identical for either module.
2. A small independent simulation/test script, if practical.
3. A brief README explaining the parameters, installation, input/output wiring, and reset behavior.

### 13. Explicitly out of scope for v1

Do not add:

- Additional CA rules or rule morphing.
- Random excitation or mutation.
- Density controls.
- Automatic reseeding.
- Attractor detection.
- Live ring-length CV control.
- Euclidean rhythms or conventional sequencer patterns.
- Individual output probability controls.
- Different operating modes for the two Crows.

The priority is a simple, reliable implementation of the specified evolving ring.

### 14. Intended musical behavior

Both Crows function independently, each driving four Noon voices.

Their clocks may be related by 2:3, while the internal four-head geometry supplies another layer of rhythmic organization.

The CA can produce stationary structures, traveling patterns, branches, cycles, and transitions caused by incoming data.

The aim is not to force a particular attractor or rhythmic density. It is to create an instrument whose behavior can be explored experimentally through clocking, external excitation, and ring circumference.

**Begin with `{2,4}`, `L = 17`. Preserve easy switching to `L = 24`, `19`, and `16`.**
