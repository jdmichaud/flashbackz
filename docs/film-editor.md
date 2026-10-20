# Film editor — design note

Status: design discussion with the user, 2026-10-19 and 2026-10-20 (PLAN ED-1). Nothing is built.
The note records the decisions taken so far and the questions still open.

## Technology

A separate program, not part of flashbackz (user decision, 2026-10-20). It is written against the
classic Win32 API: a window class, a window procedure, menus and child controls. On Windows it
uses the real API; elsewhere it runs on ween32 (https://github.com/jdmichaud/ween32), a portable
Zig reimplementation of that API with the classic Windows 2000 look. That look fits the classic,
minimalist interface below. For the preview it can still link the film code of flashbackz's
shared module, which has no host dependency.

## Purpose

A tool to make and change the game's vector films: trace filmed footage the way the originals were
made (rotoscoping), edit existing films, preview them exactly as the game plays them, and export
them. The game plays its films from the data set's `films/` directory in their original formats
(PLAN FL-1, `docs/formats/data-set.md`); the editor reads and writes those files.

## The film model

The format is 2D (`docs/formats/vector-films.md`). The editor works with the same concepts:

- **Outline**: a polygon (a dot or a line with one or two points) or an ellipse. A POL vertex
  record.
- **Shape**: an ordered group of primitives. A primitive is an outline with a color index (0 to
  15), a see-through flag and an optional offset; one outline can appear several times in a shape.
  Later primitives cover earlier ones. Shapes form a library and are reused across frames.
- **Frame** (a film frame): a picture made of placed shapes. A placement gives the shape, the
  position, and optionally a scale and three angles. The angles turn the flat shape in 3D and
  flatten it again without perspective; the second and third default to 180 and 90, no tilt. A
  placement is a parameter of one draw, never a change to the shape.
- **Timeline**: the frames in order, each with how long it stays (waits and holds, in timer
  ticks). Each frame is drawn from scratch, except the **background**: shapes drawn in a
  background mode are kept and copied into the following pictures until the background mode
  changes.
- **Colors**: a primitive gives an index; the actual colors come from the palette that the film
  loads (a command of the timeline), so they can change during a film.
- **Captions and interactive pages**: caption texts (from the caption files) and page loops,
  which wait for a key and jump.

## Project file and export

The editor keeps its own project file with everything the film files cannot hold: layers (names,
order, visibility, opacity, lock), the reference images and their placement, the mapping of
reference images to frames, names of shapes, and editor settings. CMD and POL are an export, as a
PNG is an export of a layered image:

- Layers flatten into drawing order: the bottom layer's shapes are drawn first.
- The background layer maps to the background mode and is kept from frame to frame.
- Layer names, visibility, opacity, locks and reference images are not exported.

Importing an original film gives a flat project: a background layer and one layer of shapes per
frame, until someone organizes it.

## User interface

Classic, minimalist and functional: a menu bar, a drawing zone and the panels that the model
needs.

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ File  Edit  View  Shape  Frame  Film  Export  Help                           │
├────┬──────────────────────────────────────────────────┬──────────────────────┤
│ ↖  │                                                  │ LAYERS               │
│ ▱  │   ┌──────────────────────────────────────────┐   │ 👁 ▣ Captions   100% │
│ ◯  │   │                                          │   │ 👁 ▣ Conrad     100% │
│ ╱  │   │        drawing zone                      │   │ 👁 ▢ Ship        60% │
│ ✥  │   │   (reference image under the shapes,     │   │ 👁 🔒 Background 100% │
│ 🔍 │   │    previous frame faint = onion skin)    │   │ 👁 Reference     40% │
│ 💧 │   │                                          │   │ [+] [−] [↑] [↓]      │
│    │   └──────────────────────────────────────────┘   ├──────────────────────┤
│    │                                                  │ SHAPES (library)     │
│    │                                                  │  ship_body  ship_fin │
│    │                                                  │  lamp       window   │
│    │                                                  │ [new] [edit] [dup]   │
│    │                                                  ├──────────────────────┤
│    │                                                  │ SELECTION            │
│    │                                                  │ shape  ship_body     │
│    │                                                  │ x  120  y  64        │
│    │                                                  │ scale  1.00          │
│    │                                                  │ angles 10 180 90     │
│    │                                                  ├──────────────────────┤
│    │                                                  │ COLORS (frame 12)    │
│    │                                                  │ ■■■■■■■■ ■■■■■■■■    │
│    │                                                  │ see-through ☐        │
├────┴──────────────────────────────────────────────────┴──────────────────────┤
│ ◀◀ ◀ ▶ ▶▶  ⟲ loop   onion ☑ 1 back 0 ahead                  frame 12 / 148   │
│     │1 │2 │3   │4 │5 │6 │7      │8 │9 │10│11│12│13│14 │15│…                  │
│ pic ├──┼──┼────┼──┼──┼──┼───────┼──┼──┼──┼──┼▓▓┼──┼───┼──┤   (width=time)    │
│ bg  ████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░   (kept until …)  │
│ txt         ┌ "WELCOME TO …" ┐                 ┌ "…" ┐                        │
│ ref  37  38  39  40  41  42  43  44  45  46  47  48  49  50   (film image #)  │
├──────────────────────────────────────────────────────────────────────────────┤
│ x 132 y 71   zoom 3×   DOS 256×224   film area (8,50) 240×128   saved        │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Menus.** File: new, open and save a project, import CMD/POL. Edit: undo, copy, paste. View:
  zoom, reference opacity, onion skin. Shape: new, edit outline, reorder primitives. Frame:
  insert, duplicate, delete, duration. Film: colors, background mode, captions, page loops,
  preview. Export: CMD/POL, video, vector animation.
- **Tools.** Select and move, polygon, ellipse, line, pan, zoom, color picker.
- **Drawing zone.** The film area at its true size and place, zoomable and pannable. The
  reference image lies under the shapes; the onion skin shows the previous frame (and optionally
  the next) faintly.
- **Layers.** Each layer, the background layer and the reference image included, has an opacity
  and can be hidden or locked. The background layer is marked as such.
- **Shapes.** The library of reusable shapes.
- **Selection.** The placement of the selected shape: position, scale, the three angles.
- **Colors.** The 16 colors in force at the cursor's frame, and the see-through flag.
- **Timeline.** One cell per frame, its width the time it stays. Tracks: the pictures, the span of
  the background, the captions, and the reference image of each frame. A cursor moves from frame
  to frame with the mouse or with keys (←/→ one frame, Home/End the ends); moving it switches the
  reference image, the frame's layers and the colors together. Transport: play, pause, step,
  loop, onion skin settings.
- **Status bar.** Pointer coordinates, zoom, resolution preset and film area, saved state.

## Reference images

Rotoscoping traces shapes over filmed images. The editor takes a stack of reference images (an
image sequence, or a video split into images) that can be moved, scaled and panned under the
drawing. Film frames and footage do not correspond one to one, so each frame names its reference
image. Reference images are never exported.

## Preview

The preview plays the document through the game's own film code (`src/shared/content/
vector_cinematic.zig` and the film player), as an export in memory: it shows exactly what the
game will play, with the original's quirks and timing in ticks. A separate preview renderer would
drift from the game. It plays on demand or after each edit, with play, pause and a loop over a
range of frames.

## Export

- **CMD/POL**: the game's formats, into a data set's `films/`.
- **Video** (MP4, WebM, animated GIF or APNG): frames rendered by the game's film code, then
  encoded (for example by ffmpeg). Exact.
- **Vector animation** (Lottie, or SVG): keeps the shapes as shapes, so it scales to any size.
  Not exact: see-through pixels and palette changes do not map cleanly.

## Resolution

- **Rendering resolution** (preview and exports) can be any multiple: the films are vectors.
- **Authoring resolution**: the coordinates are 16-bit, but the films are composed for the
  original's 256 × 224 picture with the film area at (8, 50), 240 × 128, and the game plays them
  there. A film for another canvas needs the game to know that canvas too.
- **Presets**: DOS, Mega Drive and Amiga. Their exact screen and film-area sizes are to be measured
  (the DOS and Mega Drive editions are at hand; the Amiga edition is not), not taken from memory.

## Open questions

- The shape library: a panel always shown, or a tab?
- Editing a shape's outlines: in place, or in a separate shape mode with the frame dimmed?
- The preview: in the drawing zone, or in its own window?
- The modern vector format: Lottie, SVG, or both?
- Where the editor's repository lives, and how it gets flashbackz's film code (a Zig package
  dependency, or a copy of the module).
