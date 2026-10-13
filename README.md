# RecipeBox — Setup

A SwiftUI iOS app that photographs a recipe (camera or library), reads it
with **AI vision** (Claude by default, ChatGPT as an alternative — swap or
add providers easily), and shows it as an **editable text page** you can
swipe to compare against the **original photo**.

## 1. Create the Xcode project
1. Open Xcode → **File → New → Project → iOS → App**.
2. Product Name: `RecipeBox`. Interface: **SwiftUI**. Language: **Swift**.
3. Set the **Minimum Deployment Target** to **iOS 16.0** (needed for
   `NavigationStack`).

## 2. Add the files
Drag all the `.swift` files from this folder into the Xcode project
(check "Copy items if needed"), replacing the default `ContentView.swift`
it created for you:

- `RecipeBoxApp.swift`
- `ContentView.swift`
- `SettingsView.swift`
- `ImagePicker.swift`
- `OCRTextExtractor.swift` (shared on-device OCR step)
- `RecipeParserService.swift` (on-device heuristic engine)
- `StructuredRecipe.swift` (shared recipe model + text layout)
- `AIRecipeProvider.swift` (protocol for pluggable AI engines, text-based)
- `AnthropicRecipeProvider.swift` (Claude implementation)
- `OpenAIRecipeProvider.swift` (ChatGPT implementation)
- `AIRecipeParser.swift` (runs OCR, then hands text to the AI provider)
- `AIRecipeJSONParser.swift` (shared response parsing)
- `RecipeParserFactory.swift` (picks the active engine)
- `KeychainHelper.swift` (secure API key storage)
- `ComparePagerView.swift`
- `RecipeEditView.swift`
- `ImageDisplayView.swift`

## 3. Add permission strings (required — camera/photos won't work without these)
Open your target's **Info** tab (or `Info.plist` source) and add the two
keys from `Info.plist.additions.xml`:
- `NSCameraUsageDescription`
- `NSPhotoLibraryUsageDescription`

## 4. Get an API key
The app defaults to Claude for parsing. Before first use, get an API key
from https://console.anthropic.com/settings/keys (or switch to ChatGPT in
Settings and use an OpenAI key from https://platform.openai.com/api-keys
instead). Paste it into the app's Settings screen — the app will prompt
you for this automatically the first time you try to add a photo without
one set.

## 5. Build & run
- The camera only works on a **physical device** (the simulator has no
  camera) — use "Choose from Library" in the simulator instead.
- Build target: any iPhone running iOS 16+.

## How it works
- **Capture**: `ImagePicker.swift` wraps `PHPickerViewController` (library)
  and `UIImagePickerController` (camera) for SwiftUI.
- **Parsing (hybrid, cost-optimized)**: photos are **never sent to the AI
  directly**. `OCRTextExtractor.swift` runs Apple's Vision OCR on-device
  first (free), and only the extracted text goes to the AI to be cleaned
  up and structured into JSON. This is a large cost cut versus sending
  images: text tokens are far cheaper than image tokens, and it means the
  request doesn't need a vision-capable model at all.
  - **Claude** (`AnthropicRecipeProvider.swift`) — default. Uses Claude's
    Haiku-tier model, since structuring already-extracted text doesn't
    need a frontier model.
  - **ChatGPT** (`OpenAIRecipeProvider.swift`) — uses `gpt-4o-mini` for
    the same reason. One tap away in Settings.
  - **On-Device** (`RecipeParserService.swift`) — the same OCR step, run
    through a simple heuristic formatter instead of an AI call. Free,
    offline, no API key, but noticeably less accurate — kept as a fallback.
  - `max_tokens` is capped at 900 on both AI providers — enough headroom
    for a recipe with grouped ingredients, tips, and nutrition facts (see
    below), while still bounding worst-case cost per request and stopping
    the model from rambling.
- If the selected engine is an AI provider with no API key saved yet,
  tapping "Add Recipe Photo" prompts the user to open Settings instead of
  silently failing after taking a photo.
- **Settings** (`SettingsView.swift`) lets the user pick the active engine
  and paste in an API key per AI provider. Keys are stored in the iOS
  **Keychain** (`KeychainHelper.swift`), never in plain text or committed
  to source control.
- **Compare UI**: `ComparePagerView.swift` is a `TabView` with
  `.tabViewStyle(.page)` for the native swipe-between-pages feel. Page 1
  (`RecipeEditView`) is an editable `TextEditor`; page 2
  (`ImageDisplayView`) shows the original photo, pinch-to-zoom.

## Known failure mode: two-column recipe cards
A common recipe-card layout (one ingredient list on the left, another
list plus the steps on the right — like the sample photo this app was
tested against) can trip up the hybrid pipeline, because Apple's Vision
OCR has no concept of columns: without help, it interleaves left- and
right-column lines by vertical position instead of reading one column
fully before the other. A cheap AI model handed that scrambled order can
give up on structuring it and return a title with no ingredients or
instructions at all — which looked, from the app, like the photo just
didn't have any.

Two defenses are in place:
- `OCRTextExtractor.swift` now detects a clear vertical gap between two
  clusters of text roughly in the image's middle third and, if found,
  emits the left column fully (top to bottom) before the right column,
  instead of a single interleaved pass. It's a heuristic (a fixed x-split
  down the whole image), not real layout analysis, so it won't handle
  three+ columns or a split that moves partway down the page.
- `AIRecipeParser.swift` now treats "OCR found substantial text, but the
  AI returned zero ingredients and zero instructions" as an error
  (`AIProviderError.emptyStructuredResult`) rather than a successful,
  quietly-empty recipe — so a parsing failure surfaces as a clear message
  ("try again / retake the photo / switch engines") instead of silently
  rendering as if the photo had nothing on it.
- `StructuredRecipe`'s decoder also now accepts the AI falling back to
  the older flat `"ingredients": [...]` / `"instructions": [...]` schema
  (wrapping it into a single unnamed group) instead of only recognizing
  the current `ingredientGroups`/`instructionGroups` keys — a cheap model
  reverting to the more common flat shape it's seen more of in training
  no longer silently produces an empty result.

If empty results persist on multi-column photos, the next step up would
be real layout analysis (e.g. `VNDocumentCameraViewController` region
detection, or clustering by full bounding-box overlap rather than a
single x-split) rather than the current column heuristic.

## Known failure mode: word-wrapped ingredients in narrow columns
Fixing the column-interleaving problem above surfaced a second, subtler
one on the same kind of layout. A narrow column forces a single printed
ingredient or step to wrap across two or more physical print lines (e.g.
"2 tablespoons dill" / "pickle relish" as two separate lines for one
ingredient). Vision's OCR returns each wrapped line as a separate,
unmarked observation, so the AI has to guess which lines are wrap
continuations versus new items using content alone — and on a test photo
this produced real errors: a hallucinated ingredient ("bacon", which
wasn't in the photo at all — most likely a mangled fragment the model
replaced with a plausible-sounding but wrong word), an ingredient
assigned to the wrong section, two adjacent wrapped ingredients with
their words cross-mixed, and a fabricated instruction step ("place the
top bun") that wasn't in the printed text.

Part of the cause was a previous prompt change (see the section above)
that told the model not to give up on messy/reordered text — a fix for
under-extraction that, on this photo, tipped into over-extraction:
filling uncertain gaps with invented content instead of preserving what
OCR actually saw. `AIRecipePrompt.instructions` in `AIRecipeProvider.swift`
now carries three additional explicit rules to correct this without
reverting the earlier fix:
- **Wrap-joining**: recognizes that a short, grammatically incomplete
  line is very likely the second half of the line above it, not a new
  item.
- **Literal fidelity over plausibility**: correcting an obvious
  single-character OCR misread (`l` → `1`, `0` → `o`) is still fine, but
  an unclear fragment should be kept as close to the literal OCR text as
  possible rather than replaced with a different, unrelated word — since
  an odd-looking but honest transcription is far more useful to someone
  comparing it against the original photo than a smooth-sounding
  fabrication. This applies to instructions too: no action may be added
  that the OCR text doesn't actually describe.
- **Section headers control grouping**: an ingredient or step belongs to
  the most recent all-caps header above it in the OCR text, decided by
  position, not by guessing which section it "should" belong to.

This was shipped as a prompt-only fix first (no new OCR code) — the
deliberately lower-risk option, since a geometry-based fix needs testing
against real photos on a device running Vision, which this environment
can't do.

### Follow-up 1: a real test run showed the prompt-only fix has a ceiling
Testing the fix above against the actual crab burger photo fixed three
of the four original defects (no more hallucinated ingredients, correct
section assignment, correctly-joined "dill pickle relish"), but a
**second run of the same photo** dropped the quantity and descriptor
from a different wrapped ingredient ("2 tablespoons white" / "onion,
finely chopped" → just "onion, finely chopped"). Two independent runs
losing content on the exact same kind of fragment was good evidence that
guessing wrap-vs-new-item from content alone has a real ceiling — the
model has no way to know which lines belong together in the original
print unless it's told.

The first attempt at giving it that signal used vertical spacing
(inserting a blank line wherever the gap between two OCR lines looked
unusually large) — reasoning that printed lists usually have visibly
more space between distinct items than between the two halves of one
wrapped line. **That assumption turned out to be wrong for this photo**:
inspecting the actual image directly, the person testing this app found
the vertical spacing between every line is uniform — there is no gap to
detect. The only real signal distinguishing a new ingredient from a
wrapped continuation is whether the line starts with its printed
quantity (a number or a fraction like ½).

### Follow-up 2: rebuilt around the quantity-leading rule instead
`OCRTextExtractor.swift` now rejoins wrapped lines deterministically,
before the text ever reaches the AI, using that confirmed rule: within
each column, a line starting with a digit or a fraction glyph (½, ¼, ¾,
⅓, ⅔, ⅛, ⅜, ⅝, ⅞) always starts a new ingredient/step; a short all-caps
line (a section header like "TARTAR SAUCE:") also always starts fresh;
anything else is the wrapped continuation of whatever line came before
it and gets joined onto it with a space. Traced by hand against the full
crab burger photo, this correctly reconstructs every wrapped ingredient
in both ingredient lists, including the exact line that broke twice
before. Because the joining now happens deterministically in code rather
than being left to the AI's judgment, `AIRecipePrompt.instructions` was
simplified to match: it now tells the model line-wrapping is already
resolved and each line is complete, rather than asking it to detect and
join wraps itself (which risked the model second-guessing already-correct
lines).

`RecipeParserService.swift`'s on-device heuristic path benefits from this
too, automatically — it consumes the same rejoined lines, so its own
ingredient/instruction splitting (which had no wrap-handling of its own)
gets cleaner input for free.

**Known limitation at the time**: an ingredient with no printed quantity
at all (e.g. "Iceberg lettuce cups" in this same photo's "For Serving"
list, or "Salt and pepper to taste" in other recipes) looked identical to
a wrapped continuation line under the quantity-only rule, and could get
merged into the ingredient above it. A fix that was tried — treating a
capitalized line as "probably a new item" — broke a different real line
in the same photo ("1 teaspoon Old Bay" / "Seasoning": the continuation
"Seasoning" is also capitalized, since it's part of a proper product
name). This is addressed below in Follow-up 3.

### Follow-up 3: rule refined from "has a quantity" to "is flush left"
Looking directly at the photo again, the person testing this app pointed
out the actual print signal: "Iceberg lettuce" (no quantity) sits at the
**same left indentation** as every quantity-led bullet in that list —
it's a new item simply because it starts at the list's left margin — while
"Seasoning" (the wrapped continuation of "1 teaspoon Old Bay") is
**indented further right**, under the text of the line above it, not at
the margin. Indentation, not the presence of a leading digit, is the real
and complete signal; a leading quantity is just one reliable way a line
happens to reach that same left margin.

`OCRTextExtractor.swift` now uses this directly. Each OCR line's left
edge (`xLeft`, from Vision's bounding box) is tracked alongside its
existing midpoint/top values. Within each column, the quantity-led lines
(the ones we can already identify with certainty) serve as that column's
own self-calibrating "anchor" points: their median `xLeft` is the list's
left margin, and their own spread around that median sets the tolerance
for "close enough to flush" — a fixed pixel or normalized threshold can't
be assumed across different photos, framing, or crops, so the margin and
tolerance are measured fresh from each photo's own bullet lines rather
than hard-coded. A line then starts a new item if it starts with a
quantity glyph *or* its left edge falls within that tolerance of the
margin; anything else (indented further right, like "Seasoning") is
merged into the line above it as a wrapped continuation. A short all-caps
header line still always starts fresh, same as before.

Traced by hand against the crab burger photo, this reconstructs every
previously-correct item and now also correctly separates "Iceberg lettuce
cups" as its own item, closing the gap above, while still correctly
merging "Seasoning" into "1 teaspoon Old Bay" — the case that broke the
earlier capitalization-based attempt. If a column has no quantity-led
lines at all (most likely prose instructions with no printed step
numbers), there's nothing to calibrate a margin against, so that column
still falls back to merging every line into one flowing block, same as
before.

**Still worth flagging**: the tolerance values in code (a floor of 0.01,
or 0.015 when a column has only one anchor line, both in Vision's
normalized 0–1 coordinate space) are reasonable-sounding estimates based
on tracing this rule against the recipes tested so far, not values
verified against live Vision output — this environment has no Xcode or
device to run OCR on an actual photo. A photo with unusual print spacing
could still need these adjusted after real testing.

### Follow-up 4: manual masking for stray text from other recipes
A different problem than wrap-detection: a photo of a book/binder page can
legitimately contain text from a *different* recipe — the tail end of the
previous one at the top of the page, or the start of the next one at the
bottom — and Vision happily OCRs all of it, with nothing in the geometry
or heuristics above knowing to leave it out. Rather than guess where one
recipe ends and another begins, the person now marks it directly.

**New screen: `MaskEditorView.swift`.** Right after a photo is picked
(camera or library), instead of parsing immediately the app now shows the
photo with an instruction to draw a box over anything that shouldn't be
read. The person can draw as many boxes as needed, tap one to remove it,
or tap Continue with none drawn to parse the whole photo as before —
masking is opt-in, not an extra required step. Each box is drawn in the
view's own on-screen coordinates and converted to an image-fraction rect
(0...1, top-left origin) so it stays correct regardless of screen size or
how large the photo is displayed.

**Where it's enforced: `OCRTextExtractor.extractLines`.** The view hands
its rects to `ContentView`, which passes them through
`RecipeParserFactory` → `RecipeParsing.parseRecipe(from:excludedRegions:)`
→ `OCRTextExtractor.extractLines(from:excludedRegions:)`. There, each rect
is flipped once from top-left to Vision's bottom-left-origin normalized
space, and any recognized OCR line whose center falls inside one of them
is dropped *before* column-splitting or wrap-merging ever run. That
ordering matters: a blocked-out line can't accidentally get merged into a
real ingredient just because it happened to sit at the same left margin,
and it never reaches the AI prompt at all — there's no "ignore this" rule
for the model to get wrong, because the text simply isn't there.

This is additive: `RecipeParsing.parseRecipe` gained an `excludedRegions`
parameter, with a protocol-extension default of `[]` so any other call
site (previews, tests) that doesn't care about masking still compiles
unchanged. Both `VisionRecipeParser` (on-device) and `AIRecipeParser`
(Claude/ChatGPT) route through the same `OCRTextExtractor` call, so
masking works identically no matter which engine is selected.

**Not yet handled**: a box only blocks OCR on *this* photo — there's no
way to save a mask and reuse it if the person retakes the same page. Also
untested here for the usual reason: drag gestures over a photo, and how
SwiftUI resolves a tap-to-delete on a box versus a new drag starting on
top of it, both need a real device to confirm feel right; the logic is
correct by inspection but not exercised against actual touch input.

### Follow-up 5: on-demand AI Vision re-read from the photo page
The default path stays cheap: local OCR, then only text goes to the AI.
When that isn't enough (messy layout, neighbouring-recipe text, bad OCR),
the photo page of `ComparePagerView` now has a **Re-read with AI Vision**
button that sends the photo itself to the selected AI engine and has the
model find and structure the recipe directly.

- `AIRecipeProvider` gained `requestRecipe(fromJPEGData:...)`; both
  `AnthropicRecipeProvider` (image content block) and `OpenAIRecipeProvider`
  (`image_url` data URI, `detail: high`) implement it, sharing one private
  `send` helper with the text path. Same models as before (both accept
  images); the vision output cap is 1500 tokens vs 900 for text.
- `AIRecipePrompt` was split into shared pieces: `schemaAndRules` (JSON
  shape + rules, used by both paths so the output is identical),
  `ocrIntro` (text path) and `visionIntro` (vision path). The vision intro
  tells the model to extract only the one main recipe and ignore partial
  text from neighbouring recipes, how to read two-column and indented
  wrapped ingredients, and to transcribe literally.
- `RecipeImageEncoder` downscales the photo to 1600px on the long edge
  (image tokens scale with pixels) and paints any areas blocked out in
  MaskEditorView solid white, so masks are honoured here too.
- `AIImageRecipeParser` / `RecipeParserFactory.makeImageParser` wire it up.
  The On-Device engine has no vision, so the button explains that Claude
  or ChatGPT must be selected.
- The result replaces the Recipe page text and jumps to it; an **Undo AI
  Re-read** toolbar button restores the previous text (including edits).

Cost: a vision call sends image tokens on top of the prompt, so it costs
noticeably more than the text path — that is why it's a button, not the
default. Untested here (no Xcode/device or API access in this sandbox).

### Follow-up 6: camera photos were OCR'd sideways
Photos from the in-app camera store their pixels in the sensor's
orientation and carry an `imageOrientation` flag (typically `.right` for a
portrait shot) saying how to rotate them upright; library photos are
usually already `.up`. `OCRTextExtractor` fed Vision the raw `cgImage`
with no orientation, so camera photos were read rotated — worse OCR, and
bounding boxes in the rotated frame, which also made mask boxes (drawn on
the upright image) land in the wrong place. It now passes
`CGImagePropertyOrientation(image.imageOrientation)` to
`VNImageRequestHandler`, so Vision reads and reports boxes in the upright
frame. The vision (AI) path was already correct: `RecipeImageEncoder`
redraws with `image.draw(in:)`, which applies orientation. Untested on a
device here.

## Further cost levers if needed
- **Cascade to AI only when needed**: run the on-device heuristic first;
  if it produces a suspiciously empty/short result, only then call the
  AI. Skips the AI call entirely for clean, well-formatted photos.
- **De-dupe repeat photos**: hash the image and cache the resulting
  `StructuredRecipe` so re-parsing the same photo doesn't re-call the AI.
- **Trim OCR noise before sending**: `OCRTextExtractor` returns raw lines
  as-is; filtering out obvious junk (single characters, page numbers)
  before building the prompt shrinks the input further.
- Model and pricing details move over time — check
  https://www.anthropic.com/pricing and
  https://platform.openai.com/docs/pricing before assuming the numbers
  above still hold.

## The recipe model is flexible, not fixed to title/ingredients/steps
Real recipes vary a lot in what they print — some have two labeled
ingredient lists (e.g. "Vinaigrette" and "Salad"), a make-ahead tip, and a
per-serving nutrition panel; most have none of that. `StructuredRecipe`
(in `StructuredRecipe.swift`) models this without assuming any section
beyond a title is present:

- `ingredientGroups: [IngredientGroup]` / `instructionGroups: [InstructionGroup]`
  — each group has an optional `name` (nil for a plain, ungrouped list) and
  its items/steps. A recipe with one flat ingredient list is just one
  group with `name: nil`; a recipe with labeled sections is multiple named
  groups. `renderedText()` only prints section headers when there's more
  than one group, so a simple recipe's text output is unchanged from
  before this model existed.
- `prepTime` / `cookTime` / `totalTime` / `servings` — free-text strings
  copied as printed (e.g. `"20 minutes"`), not parsed into numbers.
- `tips: [String]` — any make-ahead notes, tips, or variations printed
  with the recipe.
- `nutrition: [NutritionFact]` — ordered label/value pairs (e.g.
  `{"label": "Calories", "value": "238"}`), since recipes print wildly
  different sets of nutrition facts, if any.
- `source: String?` — a printed attribution, website, or page number.

Every field beyond `title` is optional or defaults to empty, and
`StructuredRecipe`'s custom `Decodable` implementation treats a missing
key from the AI as "this recipe doesn't have that section" rather than a
decode failure — so the AI is explicitly prompted (see
`AIRecipePrompt.instructions` in `AIRecipeProvider.swift`) to omit a
field rather than invent content to fill it. The on-device heuristic
parser (`RecipeParserService.swift`) still only ever produces one flat
ingredient group and one flat instruction group — it has no way to
detect section headers — via the `StructuredRecipe(title:ingredients:instructions:)`
convenience initializer.

To add another optional section later (say, a photo caption or an
equipment list): add a field to `StructuredRecipe` with a default value,
decode it the same lenient way in `init(from:)`, render it in
`renderedText()` only when non-empty, and mention it in
`AIRecipePrompt.instructions`. Nothing else needs to change, since the UI
only ever sees the rendered plain text.

## Adding another AI provider later
This is the whole point of the `AIRecipeProvider` protocol — swapping or
adding an AI backend never touches the UI or navigation code:

1. Create a new file (e.g. `GeminiRecipeProvider.swift`) with a struct
   conforming to `AIRecipeProvider`. Copy `OpenAIRecipeProvider.swift` as
   a starting template — implement
   `requestRecipe(fromOCRText:apiKey:completion:)` to call the new API and
   return a `StructuredRecipe`.
2. Add one case to the `ParserEngine` enum in `RecipeParserFactory.swift`
   (`displayName` and `aiProvider` need one line each).
3. Add one more `Section` to `SettingsView.swift` for its API key field.

That's it — `ContentView`, `ComparePagerView`, and everything else are
written against the `RecipeParsing` protocol and don't know which engine
is active.

## A note on API keys in a client app
Calling AI vision APIs directly from the app (as this project does) means
the request goes straight from the user's phone using a key they paste
into Settings — fine for personal use or a prototype. For a shipped app
you'd distribute to others, route these calls through your own backend
server instead, so your API key isn't embedded in the app; the
`AIRecipeProvider` protocol makes that a drop-in change (a provider that
calls *your* server instead of the vendor directly, using the same
interface).
