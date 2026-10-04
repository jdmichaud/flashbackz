# Movement testing

The full Conrad movement pass is in progress. These additions are ready in the Linux executable:

| Movement | Controls |
| --- | --- |
| Walk → run | Hold Left or Right, then press Shift while walking. |
| Run → walk | Keep holding the direction and release Shift. Conrad finishes the committed stride; some foot placements brake before walking. |
| Running turn | Keep Shift held, release the current direction, and press the opposite direction. |
| Running wall stop | Hold Shift + Left/Right toward a wall, including when starting one step away. Conrad stops without crossing it. |
| Automatic running ledge grab | Run toward a raised platform, release Left/Right and keep Shift held. Conrad jumps to a reachable ledge. Keep Shift held to hang; add Up to climb. |
| Running roll | While running, keep Shift held, release Left/Right and press Down. Keep Shift + Down held to repeat where terrain allows. |
| Crouched roll | Press Down to crouch, then release Down and press the direction Conrad faces. |
| Running off a ledge | Hold Shift + Left/Right across the edge; Conrad drops and recovers on a lower platform. |
| Running jump | While running, keep Shift held, release Left/Right, and press Up. The running jump needs more room than the standing jump. |

Briefly overlapping Left/Right or Up/Down is also supported. It no longer terminates the game.
The original's input arbitration determines which direction resumes after release.

The latest batch passes 2,036 original floppy movement-update comparisons, including the
651 earlier transition checks. Native SDL input exercises the wall stop, ledge grab/climb
and running roll. Some reference cases use isolated initial placements on disposable asset
copies. These checks do not establish all movement/terrain combinations: broader airborne
landings, armed locomotion and further room/death handling remain in progress before world
mechanism work resumes.

Existing basic controls remain: arrows move/jump/crouch, Shift modifies movement and picks up
nearby objects, Tab opens inventory, and Return uses a selected supported item.

Weapon-drawn walking, turning, crouching and holstering are now implemented in development
builds and pass 920 original update comparisons. Firing is still unfinished, so this weapon
batch is not yet included in the executable offered for user testing.
