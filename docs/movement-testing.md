# Movement testing

The full Conrad movement pass is in progress. These additions are ready in the Linux executable:

| Movement | Controls |
| --- | --- |
| Walk → run | Hold Left or Right, then press Shift while walking. |
| Run → walk | Keep holding the direction and release Shift. Conrad finishes the committed stride; some foot placements brake before walking. |
| Running turn | Keep Shift held, release the current direction, and press the opposite direction. |
| Draw/holster | Press Space. Drawing from standing enters aim; forward first lowers the aim before walking. |
| Lower-platform quick draw | Tap Space during a forward jump that descends onto a lower platform. A supported interior landing can finish in crouched aim; an edge or vertical drop can require normal recovery. |
| Climb quick draw | Tap Space during the pull-up animation. Conrad draws as he finishes climbing. |
| Armed roll recovery | From a crouched gun-ready pose, release Down and press the facing direction. Conrad rolls and recovers into crouched aim when terrain allows. |
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

Weapon-drawn walking, turning, crouching and holstering are included, together with the
three transitions above. The weapon batch passes 1,165 new player-update comparisons plus
the previous 2,956 movement checks. Space can be tapped during a committed movement; keeping
it held delays the gun-ready pose until release. Shift now plays standing/crouched firing
and the measured flash/wall-impact effects, with animated casings. Forest ambience, movement,
switch, gunshot and impact sounds use the shared digital-effect system. Enemy damage, further
world behaviours and complete sound/terrain coverage remain in progress.

### Operate a nearby control

Stand beside a supported wall control and hold **Shift** without an arrow key. Conrad
reaches out, presses, and withdraws his hand. Releasing Shift before the press cancels
the activation while the animation finishes. This shared motion now drives the imported
repeatable relay-control family (seven enabled placements across the level data).
The control artwork, hint and completion sound are implemented; signal consumers such
as the connected hazard are still pending, so this does not certify the resulting puzzle.

### Pick up and throw a stone

Hold **Shift** beside a stone to pick it up. Open **Tab**, select **STONE** with the
arrow keys, close inventory with **Tab**, then press **Return** while standing to throw.
The throw uses the original motion data, including wall rebounds, drops and landing sound.
Settled stones remain available to pick up again. The jungle gunmen whose original profile
reacts to loose objects now turn and approach them; the other profile ignores stones.
The English floppy's first stone pickup has no separate cinematic.

### Jungle gunmen (first behavior increment)

Enter rooms containing gunmen to see their idle, turn, walk, aim and firing animations.
The same system drives every eligible jungle gunman, including rooms with several enemies.
Standing in their forward view alerts them; throw stones to distract the responsive variant.
Press **Space** to draw the gun, then **Shift** to shoot: gunmen now take hits, fall and
award points. Their defeat trajectory accounts for walls, platform edges and room exits.
Enemy shots now hurt Conrad. You can test **backward knockdown from a front hit**,
**forward knockdown from a rear hit**, and **getting up after a hit**. Press **Space** during
recovery to request a gun-ready get-up. Conrad briefly blinks after recovery; those shots
are absorbed without further damage. A fatal hit leads to Continue/Abort.

Hold **Down** to crouch: high shots can pass over Conrad, and nearby gunmen can respond by
**crouching and firing low**. Other gunmen can be hit by a shot that passes Conrad.
The standing/rear recovery, low-aim response and combat defeat flow have native checks.
Airborne/ledge injury combinations and complete encounter fidelity remain to qualify;
robots and ceiling laser guns still require their own behavior families.

Airborne hit correction: incoming damage now completes the interrupted motion's remaining
displacement before selecting the reaction. Running-jump descent hits no longer leave
Conrad standing 12–16 pixels above the floor. The same interruption rule applies to enemies.

### Deployable ground robots

The small box robots now deploy when Conrad approaches, pursue him along supported ground,
turn, retract and strike at close range. Their opened posture accepts **low shots**:
press **Space** to draw, **Down** to crouch, and **Shift** to fire. A successful low hit
starts collapse, overload and explosion; the robot then disappears. Keep clear during
that sequence. Closed robots and high shots retain the original immunity rules.
All seven Normal-difficulty jungle placements use this shared family; the same import
also covers twelve Earth-city and two spaceport placements. Native combat was checked
in the jungle; this does not qualify those later levels or the ceiling-gun family.

### Stone distraction in the jungle DEMO

The gunman now investigates the loose credits before Conrad throws the stone, then turns
and walks toward the landed stone. Both reactions use ordinary collectible perception.
The missing credit pickups and shortened item-detection range have been corrected;
this is not a movement scripted specifically for the recording. Hold **Shift** beside
loose credits to collect them into the existing purse and play the original pickup movie.
