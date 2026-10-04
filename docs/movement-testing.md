# Movement testing

The full Conrad movement pass is in progress. These additions are ready in the Linux executable:

| Movement | Controls |
| --- | --- |
| Walk → run | Hold Left or Right, then press Shift while walking. |
| Run → walk | Keep holding the direction and release Shift. Conrad finishes the committed stride; some foot placements brake before walking. |
| Running turn | Keep Shift held, release the current direction, and press the opposite direction. |
| Running jump | While running, keep Shift held, release Left/Right, and press Up. The running jump needs more room than the standing jump. |

Briefly overlapping Left/Right or Up/Down is also supported. It no longer terminates the game.
The original's input arbitration determines which direction resumes after release.

These additions passed 651 original floppy movement-update comparisons and four native SDL
input runs, including a running jump across the first jungle gap. They do not establish all
movement/terrain combinations. Running off edges, some airborne landings, chained rolls,
armed locomotion and further room/death handling are still being completed before world
mechanism work resumes.

Existing basic controls remain: arrows move/jump/crouch, Shift modifies movement and picks up
nearby objects, Tab opens inventory, and Return uses a selected supported item.
