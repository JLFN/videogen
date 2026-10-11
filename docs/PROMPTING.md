# Prompting guide

The H3 prompt is not free prose. MiniMax publishes the format the model was
trained on, and this recipe follows it exactly; the CLI reads the prompt from a
file because the format is multi-line.

The authoritative document is
[`docs/VIDEO_PROMPT_WRITING_GUIDE_base_en.md`](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/docs/VIDEO_PROMPT_WRITING_GUIDE_base_en.md)
in the `MiniMaxAI/MiniMax-H3` repository (and a reference-image variant next to
it, `VIDEO_PROMPT_WRITING_GUIDE_ref_en.md`). What follows is the part that
matters in practice, with the rules that change a result.

## The three core fields

Every prompt is three fields, each starting its own line, in this order:

```text
integrated_multimodal_description: [Shot 1] ...

overall_soundscape: ...

non_diegetic_music: ...
```

| Field | What goes in it |
|---|---|
| `integrated_multimodal_description` | The main body: visual style, composition, subjects, actions, shot changes, camera motion, speakers and their dialogue, and any sound the characters themselves can hear. |
| `overall_soundscape` | One to four sentences of ambient sound, physical action sounds and non-verbal human sounds (wind, footsteps, cloth, impacts, breathing, laughter). Dialogue, singing and diegetic music belong in the multimodal description instead, and must not be repeated here. |
| `non_diegetic_music` | One to three sentences describing score only the audience hears: instrumentation, speed, rhythm, dynamics. Not mood words. Use `N/A` when there is none. |

H3-Context-IR, the hosted service MiniMax uses to turn a user request into this
structure, is not part of the open release. The model card says so and points at
the prompting guide instead, which is why this recipe writes the structure by
hand.

## Shots and cuts

- `[Shot 1]` carries no timestamp. Begin it with the style and the initial
  composition, for example `[Shot 1] Live-action, cinematic, a medium-wide shot
  frames...`
- Later shots open with a strictly increasing cut time inside the clip's
  duration: `[Shot 2] At 00:02.500, the camera cuts to...`
- Use phrases like `the camera cuts to`, `the shot cuts to`, `the shot
  transitions to`, `the shot switches to`. A cut should bring new information:
  a new subject, space, state, viewpoint or time. If only the distance or a
  slight angle changes, prefer moving the camera.

## Camera motion

Write motion as a natural action inside the shot sentence, with three
dimensions: motion type, amplitude and speed.

```text
The camera trucks right with small amplitude at slow speed, keeping the fox in
the lower third of the frame.
```

The vocabulary the model was trained on: `Zoom In` / `Zoom Out`,
`Push In` / `Pull Out`, `Pan Left` / `Pan Right`, `Truck Left` / `Truck Right`,
`Tilt Up` / `Tilt Down`, `Pedestal Up` / `Pedestal Down`, `Arc Shot`,
`Tracking Shot`, `Static Shot`, `Shake Slightly` / `Shake Strongly`, `POV`,
`Roll Clockwise` / `Roll Counterclockwise`; amplitude `with small amplitude` or
`with large amplitude`; speed `at slow speed` or `at fast speed`. Medium
amplitude at normal speed is the default and can be left unwritten.

## Speakers, dialogue and singing

- Give every subject who speaks, sings or produces an off-screen human voice a
  stable id: `(S1)`, `(S2)`, or `(S1,S2)` when numbered speakers vocalize
  together. The id stays with the speaker across shots, and characters who
  never vocalize get none.
- On first appearance, establish identity from the audio and visual context:
  character type, age, gender, on-screen or off, pitch, timbre, speaking rate,
  accent.
- Keep the identifying phrase, the id, the action and the delivery *outside*
  the `<d>` tags. Inside `<d>` goes only the language tag and the spoken words,
  verbatim, punctuation included, untranslated.
- For voiceover, use the exact phrase `says in an off-screen voiceover`, and
  state that the on-screen character's lips remain closed.
- When a line crosses a cut, use `<scenetrans>` at both connecting points and
  say that the audio continues (`continues seamlessly across the cut`,
  `carries over from the previous shot`). Use `<cutoff>` when speech is cut off
  by the end of the video.

```text
The young woman with a quiet, breathy voice (S1) says: <d>[English] I get off at the next station.</d>
The two children (S1,S2) shout together, <d>[English] Wait for us!</d>
```

## On-screen text

Any sign, banner, label or subtitle that is actually visible goes in English
double quotation marks, verbatim and untranslated:

```text
A red neon sign reading "营业中" glows above the doorway.
```

## Reference images

Each task opens with a fixed alignment sentence, as the first line, followed by
one blank line before the three fields. `S.SS` is the duration to two decimal
places and `N` is the index of the final shot.

| Task | Opening line |
|---|---|
| T2VA (text only) | none; the three fields start the prompt. |
| I2VA (first frame) | `For the target video, at 0.00 seconds into the target video, <Picture 1> (from [Shot 1]) is fully referenced.` |
| FL2VA (first and last frame) | `How the reference pictures align with the target video — Picture 1 (from Shot 1) aligns with the 0.00-second mark of the target video; Picture 2 (from Shot N) aligns with the S.SS-second mark of the target video.` |
| L2VA (last frame) | `How the reference pictures align with the target video — <Picture 1> (from [Shot N]) aligns with the S.SS-second mark of the target video.` |

The two task partitions in the released checkpoints are FL2VA and Ref2VA. In
FL2VA the guide recommends a single shot so the model can interpolate between
the two frames continuously; use several shots only when they are explicitly
intended.

## What this means for the preset

The released checkpoints are CFG-distilled, which is why the wrapper runs
`--cfg-scale 1.0` and why there is no negative prompt to write bans into: with
a single conditioning input and no guidance branch, describe what you want as a
positive. Write your constraints into the prompt ("the sign is blank") rather
than into a negative field.

The turbo adapters are the other half of the choice. Their own model card states
the useful range plainly: 4 steps is the recommended minimum, 4 to 8 steps is
the range, 6 to 8 looks noticeably better than 4 if you can afford it, and past
8 steps the adapter stops helping and can start introducing over-sharp
artifacts. The `v1` checkpoint this recipe downloads as `turbo` is the line its
author describes as more prone to over-sharpening at high step counts, kept as
the default only because it is the reference deployment's own pin; the `v4`
checkpoint at the same size is the author's current recommendation and can be
dropped into `models/loras` and selected with `--lora` directly.

The `quality` preset runs the base model with no adapter at 28 steps. That is
this recipe's own choice of a working point, not a vendor figure, and it is
listed as unverified in [Verification status](USAGE.md#verification-status)
alongside the other open items.

## Audio levels

If a clip comes back with a very quiet soundtrack, the soundscape is the first
thing to check. Measured here at the same canvas, frame count and seed: a prose
prompt that asked for audio inline came back at mean -57.6 dB and peak
-33.9 dB, and a prompt in this format, with the ambient layer written out
explicitly, came back at mean -44.6 dB and peak -32.4 dB. The field structure
is worth 13 dB of mean level, so write the ambient layer out rather than
looking for a scaling problem in the decode path.

## The example prompt

[`examples/prompts/t2va-fox.txt`](../examples/prompts/t2va-fox.txt) is a
working two-shot T2VA prompt in this format. It is the prompt behind the clip in
the README, and a good starting point for editing:

```text
integrated_multimodal_description: [Shot 1] Live-action, cinematic, a medium-wide tracking shot frames a red fox trotting through a sunlit meadow at golden hour, tall grass parting around its legs. The camera trucks right with small amplitude at slow speed, keeping the fox in the lower third of the frame as warm backlight catches its fur. The fox's appearance, fur color, proportions, and gait stay consistent throughout. [Shot 2] At 00:02.500, the camera cuts to a close-up of the fox's forepaws pressing through the dry stems while its tail sweeps behind it, the same warm backlight continuing.

overall_soundscape: Soft wind moves through the tall meadow grass, and dry stems rustle as the fox's paws part them. A distant bird calls twice, and the grass settles as the fox slows near the end.

non_diegetic_music: A sparse acoustic-guitar pattern at a slow tempo, joined by low sustained strings that rise slightly and fade out.
```

## Sources

- `MiniMaxAI/MiniMax-H3`, `docs/VIDEO_PROMPT_WRITING_GUIDE_base_en.md` (the
  format, the shot and camera vocabulary, the speaker and `<d>` rules, the
  on-screen text rule, the soundscape and music rules, and the reference-image
  opening lines).
- `MiniMaxAI/MiniMax-H3`, model card (CFG-distilled checkpoints, 24 fps, 4-15 s,
  768-pixel short edge, H3-Context-IR not included in the open release).
- `larryvrh/MiniMax-H3-Turbo-Lora`, model card (the 4-to-8-step range and the
  over-sharpening past 8 steps).
