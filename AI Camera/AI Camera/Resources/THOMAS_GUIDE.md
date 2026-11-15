# The Thomas Guide

Thomas is a camera whose film is language. One press of the shutter gives you three things: the photograph the lens took, the words a vision model wrote about it, and a drawing a second model made from those words alone. This guide explains what you see on screen, what every setting does, and what the Developer Tray is showing you when it opens up the machine's workings.

Thomas teaches by not hiding. A real camera does not rename its controls: the dial says f/2.8, 1/250, ISO 400, and photographers learn those words because the camera shows them. Thomas works the same way. A system prompt is called a system prompt, a temperature is called a temperature, and this guide explains each term rather than replacing it with a friendlier one.

*This document is the companion to Thomas's own screens, and like the app it is open source. Where the app has a "?" beside a setting, this guide tells the same story at greater length.*

---

## Your first shot

You can use Thomas without reading another word of this guide:

1. **Point and press.** On a fresh install Thomas uses Apple's eye, which is already on your device. Press the shutter.
2. **Keep shooting, or wait a few seconds.** The shot develops in the background. A small capsule in the upper left says "Developing."
3. **Open Photos** (the button at the bottom right bounces when a print arrives). You'll find your photograph with the eye's words laid over it.

That is two of the three frames, with nothing downloaded. For the third, the drawing:

4. **Open Preferences** (the sliders icon, upper right), tap **Model Library**, and download a hand: **SD-2.1** is smaller and runs cooler; **SD-Turbo** draws in fewer steps.
5. **Turn on Draw the third frame** on the HAND page. Thomas switches you to the triptych, photo, words and drawing on one plate, so you see all three.
6. **Shoot again**, then open the Dark Room (the tray icon, upper right) and tap **Watch** to see the machine work: where the eye looked as it chose each word, and the drawing forming step by step.

Everything else in this guide is depth you can come back to.

---

## How this guide is organized

1. **[Your first shot](#your-first-shot)**: up and running in a minute.
2. **[Three frames, one press](#three-frames-one-press)**: the one idea behind the whole app.
3. **[Screens and settings](#screens-and-settings)**: a tour of everything you can see and touch, the camera screen, Preferences page by page, the Model Library, and the Dark Room.
4. **[The Developer Tray](#the-developer-tray)**: watching a shot develop, moment by moment, and what the numbers, the glowing squares, and the steps really are.
5. **[The models](#the-models)**: the eyes and hands Thomas can use, and how they differ.
6. **[Privacy](#privacy)**: what stays on your device, what may leave, and how to tell.
7. **[Glossary](#glossary)**: the real terms, each explained in plain words.

---

## Three frames, one press

Press the shutter and Thomas makes three frames:

1. **The lens (frame 1).** The photograph itself: what the camera's sensor actually caught. No AI is involved. It is the evidence.
2. **The eye (frame 2).** A vision model looks at the photograph and says what it sees, in words. Inside, the eye is two parts joined together: one part turns your photo into numbers, the other turns those numbers into words.
3. **The hand (frame 3).** A drawing model reads only the eye's words and draws the scene again from them. It never sees your photograph.

Reality, then machine perception in words, then machine re-imagining. The distance between them is the point. You can see, side by side, what was there, what the machine understood, and what it imagined from its own description.

### The machine says what it sees

The eye reports its perception plainly. It does not hedge ("appears to be," "possibly," "I think"), it does not attach a confidence score, and Thomas does not stamp "AI-generated, may contain errors" on the print. That is deliberate. The photograph is right there beside the words, so you can judge for yourself; the machine does not need to apologize for what it saw. When it says something strange about a scene, it is not grading itself against the world. It is telling you what it saw.

### You set the camera once, then you shoot

You never type anything at the moment you press the shutter. Everything is chosen beforehand, in Preferences, the way you load a film and set a dial before raising a camera. Each shot remembers the settings it was taken with, so changing Preferences later never changes a shot that is already developing.

### The film develops while you keep shooting

Thomas's models run on your device, and that takes real seconds. Rather than make you wait, Thomas lets you keep shooting. Each shot waits in the Dark Room, develops in turn, and lands in your Photos library when it is done, like a print surfacing in a chemical bath.

---

## Screens and settings

A note on wording: Thomas's screens say "iPhone," "iPad," or "Mac" to match the device you are using. Thomas runs on all three (on a Mac, as an iPad app on Apple silicon).

### The camera screen at a glance

The camera screen is kept almost empty on purpose: the viewfinder and the shutter, and a few quiet controls in the corners.

- **The viewfinder** fills the middle. It always shows the whole picture the camera will take, so on a screen of a different shape you will see black bands at the edges. Nothing you see is cropped away later, except in the square layouts (below).
- **Upper left: the status panel.** The privacy lock, plus small labeled capsules that appear only while something needs saying (a shot developing, the device cooling down). See [The status capsules](#the-status-capsules).
- **Upper right: the Dark Room** (a tray icon) and **Preferences** (a sliders icon).
- **Bottom center: the shutter.**
- **Bottom left: flip the camera** (front or back). It appears only when there is a second camera to flip to. A Mac with only its built-in camera has none, so the button is hidden there.
- **Bottom right: Photos.** Opens your Photos app, where finished shots land. It bounces when a new shot arrives.

Nothing about the result ever appears on the camera screen. It shows you the world; the shot shows up in Photos.

**Zoom.** Pinch the viewfinder to zoom. While you pinch, the zoom factor appears above the shutter, written the way Apple's Camera writes it ("0.5×", "1×", "2.4×"), so the numbers match.

**Focus and exposure.** These work like Apple's Camera:

- **Tap** the viewfinder to focus and set exposure there. A yellow square appears where you tapped.
- **Press and hold** to lock both. A yellow **AE/AF LOCK** banner appears above the shutter (AE is auto exposure, AF is autofocus). The next tap clears it.
- **Drag up or down** while the yellow square is showing to make the picture brighter (up) or darker (down). A small sun beside the square moves with it, on cameras that allow it.

**The square guide.** In the layouts that put a drawing beside the photo, the photo is cropped to a square to match the drawing (the hand always draws squares). In those layouts the viewfinder dims everything outside the center square and outlines it, so you can frame for exactly what will be kept.

If Thomas has not been given permission to use the camera, the viewfinder says "The camera needs permission to see."

### Pressing the shutter: what happens next

One press, and then, in the background:

1. The photograph is kept on your device at once, so it is safe even if Thomas closes.
2. The shot joins the queue in the Dark Room.
3. When its turn comes, **the eye looks** and writes its words.
4. If the words are too long for the hand to read, **the same eye shortens them** (see [What the eye said, and what the hand received](#what-the-eye-said-and-what-the-hand-received)).
5. **The hand draws**, if drawing is switched on and the layout has a place for a drawing.
6. The frames are put together in the layout you chose and **saved to Photos**.

Shots develop one at a time, in order. You can keep shooting the whole time. If you leave Thomas, developing pauses; a shot that was halfway through starts over from the beginning when you come back, so nothing is ever half finished. Waiting shots are never lost.

If the eye fails outright (a real malfunction, not a refusal), Thomas tries the look again, up to three times in all, before saving the shot without words.

**A refusal is part of the record.** Sometimes a model declines to describe a picture, or a safety filter stops it. Thomas treats that as something the machine did, not as an error to hide: whatever the machine said is printed as its words. Apple's eye has a filter that can stop a picture before the model sees it; when that happens, Thomas asks again with the filter relaxed (a setting Apple provides for apps that work with pictures you already have). If that second try is also stopped, or the model declines, that answer is what you get: it is printed as the words, and the hand draws from it. Thomas never turns a refusal into an error message. A refusal is true, and you should see it.

### The status capsules

The upper-left panel shows only what is true right now, and is empty most of the time. Tapping a capsule opens the screen that explains it.

| Capsule | What it means | Tap |
|---|---|---|
| **Closed padlock** | Nothing about your shots can leave the device right now. | The privacy explanation |
| **Open padlock** | Something may leave: the look (Apple's eye, online) or the place name lookup. | The privacy explanation |
| **Spinner · Developing** (or "Developing 3") | Shots are in the bath. | The Dark Room |
| **Hourglass · Waiting to develop** | The next shot is waiting its turn behind other work. | The Dark Room |
| **Flask · Mixing the developer…** | The drawing model is loading before its first step. | The Dark Room |
| **Thermometer · Cooling down…** | The device is hot, so developing is holding until it cools. | The Dark Room |
| **Pause · Paused** | You paused the Dark Room. | The Dark Room |
| **Warning triangle · 1 needs a model** | A shot is waiting for a model that is not downloaded. | The Dark Room |
| **Can't save to Photos** | Thomas is not allowed to add pictures to Photos, so shots are waiting. | The Dark Room |
| **Couldn't keep that shot** | A press could not be stored (an empty frame, or no room). Shown for a few seconds. | The Dark Room |
| **Preparing for shooting · 0:42** | The SD-2.1 hand is being prepared for this device's Neural Engine. | The preparation card |
| **Cooling down, then preparing** / **Getting ready to prepare** | The preparation is queued, waiting for the device to cool or for its turn. | The preparation card |
| **Couldn't prepare; the first shot will** | The preparation did not finish; the next shot that draws will do it instead. | The preparation card |

Only one Dark Room capsule shows at a time, and only one capsule ever speaks about heat. When the device is hot, "Cooling down" speaks over the count, because it is the reason nothing is moving.

### The privacy lock

The padlock is an indicator, not a passcode. It shows whether anything about your shots could leave the device right now, and it changes the moment you switch eyes, change the place stamp, or lose or gain a network connection.

Two things can leave:

- **The look.** With Apple's eye and a network connection, Apple may process the look on its Private Cloud Compute servers (encrypted in transit, held in memory that is not kept). With a downloaded eye, or with no network, or with the eye switched off, the look stays on your device.
- **The place.** A place name ("Los Angeles, CA") is found by sending your location to Apple's mapping service. Raw coordinates are computed on your device and sent nowhere. With Location off, there is no place at all.

The lock is closed only when both stay on the device. Tap it for two plain lines, one for the look and one for the place, each describing your situation right now and what you could change, plus a **Preferences** button that takes you to both remedies (a downloaded eye in the Model Library, and raw coordinates on the LENS page).

One honest detail: a shot taken with Apple's eye while offline is looked at when it develops. If you are online by then, Apple may process it.

### Preferences: the front door

Open Preferences with the sliders icon. The first screen is a summary of your camera as it is set now.

- **Your last shot**: the photo, the words, and the drawing from the most recent shot the Dark Room still keeps, labeled LENS, EYE, and HAND. Before your first shot these are empty outlines; Thomas never shows a sample picture. Tap any of them to open the settings for that part.
- **Your camera, as it is set now**: one row each for **LENS**, **EYE**, **HAND**, and **PRINT**, with the current choices in a line (for example "Apple Intelligence · temperature 0.60" or "SD-Turbo (MLX) · 4 steps · 512 px"). Tap a row to change it.
- **Model Library**: every eye and hand, what each shows, and how long each takes.
- **The Dark Room**: what is developing, and the negatives it keeps.
- **About Thomas** and **Reset everything**.

A shot travels left to right: the lens takes the photo, the eye says what it sees, the hand draws from those words, and the print puts them together in Photos. The four pages follow that order, and the pills across the top of each page (LENS, EYE, HAND, PRINT) let you move between them. Every page has a "?" in the corner, and most settings have their own "?" for the longer story.

Every setting is remembered when you put the camera down.

### LENS: what the camera takes

**Picture shape** (only on cameras that can take full-size 16:9 photos; never on a Mac):

- **4:3** (the default) is the camera's whole sensor, the widest view. In the square layouts, the square sees the most of the scene. On a tall screen the viewfinder has black bands above and below.
- **16:9** is taller and narrower, like a video frame, and fills more of the screen. In the square layouts the square sees about a quarter less of the scene, as if zoomed in a little.

**Stamp raw coordinates** (off by default). The footer of every print stamps where the shot was taken. Normally that is a place name, looked up by sending the location to Apple's mapping service while the camera is open (and again after you move about half a kilometer). Turn this on to stamp latitude and longitude instead, with no lookup and no network call. With a downloaded eye and this on, Thomas sends nothing about the shot anywhere; the line under the switch says so only when it is true.

If Location is off for Thomas, the page says so ("Location is off for Thomas, so the footer has no place stamp.") with a link to turn it on in Settings.

### EYE: how it sees

**Use the eye.** On by default. Switching it off starts [the silent loop](#the-silent-loop), where there are no words at all.

**Which eye.** The current eye is named with how long it takes to look (on this device, once you have used it here). Tap it to go to the Model Library, which is where you choose. Apple's eye is built in and needs no download. The others are downloaded and shared with Hal and Posey, so a model they already have is here at no extra cost. If the chosen eye cannot work right now, an orange line says why (for example "Apple Intelligence is off. Turn it on in Settings." or "Not downloaded yet - get it in the Model Library.").

**System prompt.** The eye's standing instructions, sent with every photo. It has two parts:

- **A locked first line**, shown with a padlock. It keeps the description short enough for the hand: the drawing model can read only about fifty words (seventy-five word pieces), and a longer description once crashed the camera. Each eye has its own locked line. Apple's eye and Qwen get "Describe what you see in no more than two or three sentences." SmolVLM, which otherwise writes essays, gets a firmer one. Tap the (i) to read why it is locked.
- **Everything below it is yours.** The text box holds the default prompt, which asks the eye to speak in the first person, in the present tense, plainly and without hedging, and never to mention that it is looking at a photograph. Change any word you like.

Even with the locked line, Thomas shortens any description longer than forty-five words before it reaches the hand.

**Temperature** (0 to 1.5, default 0.60). Each time the eye picks its next word, it has a list of likely candidates. Temperature decides how far down that list it is willing to reach. Higher reaches for less likely words. At 1.0 the eye describes the same scene differently every time; at 0.6 it is steadier and, in testing, more specific, not less imaginative. Qwen's own documentation recommends 0.6 for looking at pictures. The slider appears only for an eye that actually uses temperature; all three current eyes do.

**Frame 2 shows** (appears only when the hand is drawing). When a description runs too long for the hand, the same eye first shortens it. Frame 2 can show:

- **What the hand received** (the default): the exact words the drawing was made from, with no hidden step.
- **The eye's full words**: everything it said, even the part the hand did not get.

On most shots the two are identical.

**Reset the eye's defaults** brings back the system prompt and temperature the camera shipped with.

### HAND: how it draws

**Draw the third frame.** Off on a fresh install, because the hand is a download. Once a hand is downloaded, switch this on. If the chosen hand is not downloaded, the switch is dimmed and an orange line points you to the Model Library.

**Which hand.** As with the eye, the current hand is named with its drawing time, and tapping it opens the Model Library, where you choose. The line beneath says what the hand does: "The hand draws the scene again from the eye's words. It never sees your photo."

**Steps.** The hand draws by starting from static (random noise) and removing a little of it at each step. More steps mean more detail and a little more time. The useful range belongs to each model:

| Hand | Range | Default |
|---|---|---|
| SD-Turbo (MLX) | 1 to 6 | 4 |
| SD-2.1 (Core ML) | 15 to 30 | 20 |

Each hand remembers its own step count. **Reset the hand's defaults** puts the current hand back to its default.

**Decoder** (SD-Turbo only). The last part of making a drawing turns the model's numbers into a picture; that part is the decoder.

- **Detailed** (default): the full decoder, sharper and truer to what the model drew. If your device is short of memory for a particular shot, Thomas quietly switches that one shot to Fast so the drawing still finishes instead of failing.
- **Fast**: a tiny, low-memory decoder, softer and less detailed, that draws in almost any conditions. On a dreamy re-imagining the softness can read as intentional.

SD-2.1 has its decoder built into its own package, so this choice does not appear for it.

**Size.** The hand draws at 512 by 512 pixels, small next to your photograph. Larger sizes enlarge the drawing after it is made, which is quick and does not strain memory.

- **Native (512)**: exactly what the model made.
- **Instagram (1080)**
- **Large (2048)**

When you choose a larger size, an **Upscaler** choice appears: **MetalFX (sharper)**, Apple's GPU upscaler, which falls back to Core Image on any device that does not support it, or **Core Image (softer)**.

**Watch the drawing as.** The Developer Tray can show each step of the drawing, in one of two true ways. One is recorded per shot:

- **The working image**: what the hand actually holds at each step, static slowly becoming a picture.
- **Its best guess**: its prediction of the finished drawing at each step, blurry at first, sharpening.

### The silent loop

Switch off **Use the eye** and you are in the silent loop: no words at all. The hand reads your photograph directly and paints it again. This is a different gap from the language loop: instead of the distance between a photo and a description, you see how a drawing model reinterprets a picture with nothing in between.

- It works only with the **SD-2.1 (Core ML)** hand, the only hand that can read a photo. Switching the eye off selects SD-2.1 and turns drawing on, if SD-2.1 is downloaded. If it is not, nothing switches and the EYE page tells you to download it; until then a shot keeps the photo and your instruction.
- On the HAND page a **Silent loop** card appears with a short **instruction** (up to 80 characters, for example "an oil painting" or "a charcoal sketch"). It nudges the style; the hand still reads your photograph for its shapes and colors. A blank instruction is fine.
- **Transform** (0.20 to 0.90, default 0.60) sets how far the drawing strays from the photo: low keeps the photo's forms, high reinvents them.
- Only layouts that need no words are offered (the drawing alone, the photo alone, or the two side by side).

Switching the eye back on does not switch the hand back; you choose again in the Model Library if you want to.

### PRINT: what lands in Photos

**Layout** is how the finished print is put together. Only the layouts your current eye and hand can actually make are shown, grouped by family, and each is drawn small with your last shot's own pictures.

| Family | Layout | What you get |
|---|---|---|
| Superimposed | On the photo | The eye's words laid over your photo. (The default.) |
| Superimposed | On the drawing | The eye's words laid over the drawing. |
| Single | Words only | Just the words, on their own card. (Thomas began as this idea: only the words.) |
| Single | Drawing only | Just the drawing. |
| Single | Photo only | Just your photo. |
| Diptych | Words · photo / Photo · words | The words and your photo side by side. |
| Diptych | Drawing · photo / Photo · drawing | The drawing and your photo side by side, both square. |
| Triptych | Vertical | Photo, words, and drawing stacked on one plate, all square. |
| Triptych | Horizontal | Photo, words, and drawing side by side on one plate, all square. |

The layouts with a drawing beside the photo are square, because the hand draws squares; the viewfinder shows the square guide so you can frame for the crop.

**A layout with no drawing means no drawing is made.** If the layout you choose has no place for a drawing (words on the photo, words only, photo only, or the words-and-photo diptychs), the hand does not draw at all for that shot, even with drawing switched on, unless "Each frame as its own file" is on. This saves time and heat on a picture nobody would see. When you first switch drawing on (or first get a hand), Thomas moves you to the triptych once, so you see a drawing; after that, your choice stands.

When you switch something off that a layout needed (the eye, or drawing), Thomas moves to the richest layout that still works.

**Words panel** is how the words look when they have a panel of their own (Words only, the diptychs, the triptychs, and the separate files):

- **White on black**: the camera's original look.
- **Black on white**: its reverse.
- **The photo's color**: the strongest color in your photo becomes the panel.
- **The photo, blurred**: a soft copy of your photo behind the words, as Thomas's own screens do.

With the last two, the words are black or white, whichever reads more clearly. Words laid over a photo or drawing always stay white with a shadow.

**Also save to Photos.** Beside the print you chose, a shot can also save:

- **Each frame as its own file**: the photo, the words, and the drawing as separate pictures, in the layout's shape. With a square layout they are square, matching the square you framed in the viewfinder; with any other layout each keeps its own shape, matching the whole view. What you see when you aim is what gets saved. The words file is saved only when the eye spoke; the drawing only when there is one.
- **A contact sheet of the drawing's steps**: every step of the drawing on one page.
- **A flipbook of the drawing's steps**: a short video of the steps, ending on the finished drawing.

The steps in the contact sheet and flipbook are quick previews; the last frame is the finished drawing. These two appear only when the hand is drawing. All of these are off by default, so a shot does no extra work unless you ask.

### The footer: reality's receipt

Every print, in every layout, has black letterbox bars top and bottom and a footer: **the place** at bottom left and **the date** at bottom right. The drawing gets the same bars and footer, so the whole shot reads as one object.

The footer involves no AI. It is the camera's own testimony, the way cameras have printed the date on the frame for decades. The machine makes a claim; the photograph and the footer testify. The words themselves get no disclaimer: the photograph beside them is the disclaimer.

- With no location (Location off, or a picture loaded from your library), there is no place stamp. Thomas never invents a location.
- A picture loaded from your library is dated when it was taken (from the date inside the file), not when you loaded it.
- Thomas never writes hidden GPS coordinates into the saved picture's file. The visible footer is the only place your location appears.

### The Model Library

Open it from Preferences (the **Model Library** row, or tap the current eye or hand on the EYE or HAND page). It has two sections, **The eye** and **The hand**, and it is the one place you choose both.

**Each row** shows the model's name, its download size, and a dot:

- **Green**: downloaded and in use.
- **Gray**: downloaded, not in use.
- **No dot**: not downloaded.

**Tap a row to open its card**, which shows:

- A plain description of the model, with its real trade-offs and no verdict. Which model is better is not Thomas's to say; they see differently.
- **How long it takes**: "About 5.8 s to look on this Mac," the middle of your last few shots on this device; or, until you have used it here, the time measured on an iPhone 16 Plus, labeled as such.
- **In the Developer Tray**: what the tray can show of this model's work, row by row, each marked **Shows** or **Not shown**. See [What the tray shows for each model](#what-the-tray-shows-for-each-model).
- Its license.
- **Download**, or **Select** / **Active** / **Selected**, and **Delete**.

"Selected" appears only on a hand: it is the hand you have chosen, but drawing is switched off, so it is not active.

**Downloading.** Tap Download and a license sheet appears first. It names the license, shows the actual use restrictions in full (for the two hands), states the download size ("Requires 2.4 GB of storage and bandwidth. Wi-Fi recommended."), warns you if you are on cellular data, and links to the full license on Hugging Face. Nothing is fetched until you tap **Accept & Download**. Downloads continue if you leave Thomas. A progress bar with a percentage and a Cancel button shows while it runs.

**Shared models.** Models live in a space shared by Hal, Posey, and Thomas. A model one of them already downloaded is ready here instantly, with no second copy. Deleting a model gives up Thomas's claim on it; the files are removed only when no other app still uses them, and the delete message tells you which is the case ("...is also used by Hal. This camera gives up its claim, but the files stay on the iPhone and no space is freed."). If shots still waiting in the Dark Room need the model, the message says so; they pause, marked "Needs (model name)," until you download it again.

**Models on this device** shows the space all shared models use ("6.49 GB used"), and underneath, how much free space your device has for downloads.

**Clear all family models** is the last resort: it removes every shared model for Hal, Posey, and Thomas at once. Thomas goes back to Apple's eye; your photos are not affected.

### Preparing the drawing model

The SD-2.1 (Core ML) hand runs on the Neural Engine, Apple's chip for machine-learning work. The first time it runs, Apple's software prepares it for your particular device and keeps the prepared copy (about 100 MB). Thomas does this right after the download finishes, and once after each update of Thomas, so the wait comes up front instead of in the middle of a shot. It takes a minute or two (about a minute and a half on an iPhone 16 Plus).

While it runs, the camera screen shows **Preparing for shooting** with a clock, and from the second time on, how long it took last time ("· 0:42 of about 1:24"). Tap it for the card: the real stage it is on ("Step 1 of ..."), the clock, and "Keep Thomas open until it finishes." Apple's software reports no percentage, so Thomas shows none rather than invent one. If the device is hot, the preparation waits for it to cool first, and says so. If it does not finish, nothing is broken: the first shot that draws will prepare it instead.

SD-Turbo runs on the GPU through MLX and needs no preparation.

### The Dark Room

Open the Dark Room from the tray icon on the camera screen, from any Dark Room capsule, or from Preferences. It is where shots wait and develop, and where their negatives hang afterward.

**At the top:** **Pause** (and **Resume**), **Purge** (empties the queue, after asking; this permanently deletes every shot still waiting), and, when more than one shot is developing, **Watch the queue**. The title shows how many shots are "in the bath."

**In the bath.** Each row is one waiting shot: the photo, then the eye's words, then the hand's drawing, filling in as it develops. The one glowing red is developing now, with its stage spelled out ("The eye is looking," "Mixing the developer," "The hand is drawing," with a step count, "Saving to Photos"). **Watch** opens that shot in the Developer Tray. A shot waiting for a missing model says "Needs (model name)" and "Download it in the Model Library to continue."

- Swipe a row to delete it. Tap **Edit** to reorder the queue.
- If the device gets hot, a note says developing is cooling down and will resume on its own. Nothing is lost.
- If Thomas is not allowed to add to Photos, a note says so, with **Allow it in Settings**. Thomas asks only for add-only access: it can add pictures but cannot read the ones already there.

**Developed · in Photos.** After a shot lands in Photos, its **negative** stays here for a while: whatever of the machine's workings the Developer Tray can show for that shot, so you can open it again with **Watch**. Each row shows the date, the eye and hand used, and the three frames. Swiping one away deletes only the negative; the print in Photos is untouched.

**Keep negatives for** the last 20 (default), 50, 100, or 200 shots; the card shows how much space they use. The oldest are removed as new ones arrive. Negatives stay on this device and are not backed up. **Clear kept negatives** removes them all; your photos, words, and drawings in Photos stay.

**Load pictures to develop.** At the bottom, pick as many pictures from your library as you like. They join the queue in the order you picked them and develop exactly like shots from the shutter, with the same heat protection. A loaded picture has no place stamp, and its footer date is when it was taken.

### Staying cool

Drawing is heavy work, and a hot device slows down and can stop a drawing partway. Thomas watches the device's temperature. When it is hot, the next shot waits until it cools, and the camera screen shows "Cooling down…". Nothing is lost; developing resumes on its own. On an iPhone, setting it down somewhere cool, off the charger, helps.

### Reset everything

At the bottom of Preferences. It puts every setting back to how the camera shipped: Apple's eye, the default system prompt and temperature, drawing off, SD-Turbo as the chosen hand, default steps, the "On the photo" layout, white-on-black words, nothing extra saved, and negatives kept for the last 20 shots. If you kept more than 20, the confirmation says so before the older ones are removed. Your photographs are untouched.

### About Thomas

Thomas's version, its MIT license and copyright, a link to its source code ("Thomas is free and open source. You can read every line."), the **models in use** right now with the terms they are used under (a model that is installed but not selected is not listed, because its terms do not apply), and every open-source component Thomas is built on, each with its license.

---

## The Developer Tray

The Developer Tray opens a shot up and shows you, moment by moment, what the machine actually did: what the eye made of your photo before it had a single word, where it looked as it chose each word, what words the hand received, and the drawing forming step by step. Everything in it is real data recorded from that shot. Nothing is a sample, an illustration, or an estimate.

### Opening it

- In the Dark Room, tap **Watch** on the shot developing now, to watch it live.
- Tap **Watch** on a developed shot to open its negative.
- With several shots in the bath, **Watch the queue** follows them one after another.

The tray fills the screen, like the viewfinder. The picture is never cropped (hiding part of it would hide data the eye really looked at); the space it does not fill is a blurred copy of itself.

### Finding your way

- **Top center: LENS · EYE · HAND.** The shot's three chapters. Tap one to jump to its first moment. A chapter the shot does not have (no drawing, for instance) is dimmed.
- **Top left: close (×).** **Top right: "?"**, a short explanation of the exact moment you are on.
- **Above the slider: the moment's name**, for example "“egg” · word 15 of 44" or "Step 3 of 21."
- **The slider** runs through every moment in order, with a mark where each chapter begins. Drag it, tap **‹** and **›**, or swipe on the picture to move one moment at a time. There is no Play button: the data is worth reading, not racing past.
- **Live** (while a shot is still developing) jumps to the newest moment and follows along; a red dot beside the moment's name means you are watching live.
- **Tap the blurred background** to hide or show the controls.

If a shot's workings were not kept, the tray says "This shot's development wasn't kept."

### The moments, in order

Only moments that really happened appear. An eye that does not show its numbers has no numbers moment; a shot with no drawing has no hand chapter.

| Chapter | Moment | What you see |
|---|---|---|
| LENS | Your photograph | What the lens saw, exactly as you shot it. |
| EYE | How it took in your photo | Apple's eye only: tokens read, and time spent looking and writing. |
| EYE | The numbers | Qwen and SmolVLM: your photo as squares, each a list of numbers. |
| EYE | One moment per word | Qwen and SmolVLM: where the eye's attention went as it chose that word. |
| EYE | What the eye said | The eye's words, exactly as it said them. |
| HAND | Mixing the developer | The words the hand received, while the drawing model loads. |
| HAND | Step 1, Step 2, ... | The drawing forming, one step at a time. |
| HAND | The finished drawing | The drawing itself, as saved to Photos. |

### Your photograph

What the lens saw, exactly as you shot it. Everything after this is the machine's: the eye reads the photograph, then the hand draws from the eye's words alone.

### How it took in your photo

This moment appears for Apple's eye, which keeps its inner workings to itself but does report how it took in the picture. The numbers come from Apple's own tools:

- **Tokens read**, split into **your photo** and **its instructions and request**. A token is the unit a language model reads in. Apple's eye takes in your whole photo as tokens, the same units it reads words in (in one shot, 195 of 374 tokens were the photo).
- **Word pieces written**, with the time split into **looking, before its first words** and **writing**. Apple's eye works silently for several seconds, then hands its words over a handful at a time, so they arrive in a rush.

These bars are counts and seconds, not percentages, so they are not the same kind of measurement as the attention bar on Qwen's and SmolVLM's words.

### The numbers

This is the eye's raw understanding of your photo, before it has a single word for it.

**Squares.** The eye cuts your photograph into a grid of small squares. Qwen, for example, turned one photo into 192 squares, 16 across and 12 down. Each square is numbered; tap one to select it.

**Each square becomes a list of numbers.** Before it says a word, the eye translates each square into its own inner language: a list of **2,048 numbers** for Qwen, **960** for SmolVLM. That list is the same size the model uses for every word it reads or writes, so a patch of your photo and a word end up in the same language. The size is set by how the model was built, not by your photo.

**What the numbers mean: a place on a map of ideas.** No single number means anything we can name. Together they place the square on the model's map of ideas, the way coordinates place a city on a map. Researchers call such a list a **vector**, or an **embedding**. Squares the eye sees as alike sit close together on its map; squares it sees as different sit far apart.

This is the same idea behind **word2vec**, a famous early method that taught a computer to place words on such a map just by reading a great deal of text. Words used in similar ways landed near each other, and directions on the map came to carry meaning: the step from "man" to "woman" pointed the same way as the step from "king" to "queen." The eye's squares live on a map like that, except that pictures and words share it.

**Why 2,048 and 960.** The length of the list is the size of the model's inner language: you can think of it as a resolution of meaning, not of pixels. It is how many separate directions the model has for telling ideas apart, and it has nothing to do with how many pixels your photo has. A longer list is not a better eye. Qwen and SmolVLM were built differently, in different sizes and lineages, and they see differently.

**Minus signs.** A number below zero is a direction, not a lack, like west instead of east. A big number, positive or negative, means far out in that direction.

**Vectors and a matrix.** Each square's list is one vector. All the squares together, one row per square and one column per number, make a **matrix**: a table of numbers. For the photo above, that table is 192 rows by 2,048 columns. That table is the eye's whole understanding of the picture, and it exists before any word.

**Comparing squares.** The tray opens this moment on the square the eye looked at most while it spoke. The lit squares are the ones whose numbers are most like the selected square's: brighter means more alike; dark means unlike, or opposite. Every one of the numbers counts in the comparison; nothing is summarized. Before comparing, Thomas sets aside what all the squares have in common, so the comparison shows how they differ. When the eye has spoken, the words glow too, by how much attention each one paid to that square.

- Tap another square to compare from there.
- Tap the selected square itself to read **its actual numbers**: a sheet titled with the square's number and its row and column, showing every number to three decimal places, each tinted warm above zero and cool below, brighter the further from zero.

### Where it looked

One moment for each word the eye wrote. As it chose each word, the eye looked at everything in front of it at once: the picture, its instructions, and every word it had already said. That looking is called **attention**.

- **The picture glows** where the attention landed.
- **The sentence** shows the word being chosen underlined, the words not yet said faint, and the earlier words glowing by how much attention each one got. Every word is a button: tap one to jump to the moment it was chosen.
- **The bar** under the sentence gives the true shares: for example, 66% to the **picture**, 13% to **its instructions**, 21% to **what it had said**.

**Reading the glow honestly.** The picture's light is on one scale for the whole description (while a shot is still developing, that scale settles once the last word is written), so a word that barely looked at the picture leaves it dim. The very brightest glows, about one in a thousand, show at full light. Light is drawn on a curve so faint looks stay visible, and the glow between squares is smoothed, so brightness is not proportional. The bar gives the true numbers.

**Attention sinks.** A few squares may glow for nearly every word. Models park spare attention in a few fixed places, called attention sinks. It is a real part of how they work, not a fault in the picture.

**Invisible markers.** Much of the share that goes to "its instructions" lands not on the words of the instructions but on invisible markers that separate their parts (in one shot, 70% of it). The "?" says how much, word by word.

**How it was measured.** The "?" says which layers of the model were read and how many attention heads were averaged. It differs by model.

Tap a square at any word to light the squares whose numbers are like it, and the words that looked there; **Back to "egg"** returns you to the word.

### SmolVLM's two looks

SmolVLM looks at your photograph twice:

- **Up close, tile by tile.** It cuts the photo into tiles (a 4:3 photo becomes 4 tiles across and 3 down), and turns each tile into an 8 by 8 grid of squares. The tray stitches the tiles back together into one grid.
- **Once at the whole picture, small.** A single overview of the entire photo, also 8 by 8 squares.

Both looks appear on the same picture in the tray: the close look lights single squares, and the whole look lights the larger block each of its squares covered.

Because every tile is cut the same way, each tile stamps the same pattern onto its squares according to where they sit in the tile. When comparing squares, Thomas sets that pattern aside first, so what remains is what the picture put there.

### What the eye said, and what the hand received

**What the eye said** shows the eye's words, exactly as it said them, where the picture was. They are all the hand receives: it never sees your photograph.

**Mixing the developer** shows the words as the hand received them, labeled:

- **Handed to the hand, word for word**: nothing changed.
- **Shortened for the hand · 31 of 62 words** (the numbers are this shot's own): the hand can read only about 50 words, so Thomas asked the same eye to say it again in fewer, keeping everything that could be drawn (the things, their colors, textures, and where they are). It worked from its own words; it did not look at your photograph again.
- **Handed to the hand · it read 40 of 48 words**: the hand's text reader takes in a fixed number of word pieces, so even a short enough description can have its last few words cut off. The "?" says exactly where the cut fell.

Meanwhile the drawing model loads: onto the GPU for SD-Turbo (a second or two), or onto the Neural Engine for SD-2.1 (a second or two, or a minute or two the first time after installing or updating).

### Every step

The hand never sees your photograph. It starts from random noise and, pass by pass, refines it toward the eye's words. Each step's picture is a quick preview of the drawing engine's actual state after that step, made by a small preview decoder; it is not the finished drawing. Depending on the shot's **Watch the drawing as** setting, the previews show either **the working image** (static becoming a picture) or **its best guess** at the finished picture.

SD-2.1's method takes one extra pass at the start, so 20 steps make 21 passes; the moment names count passes ("Step 3 of 21").

While a drawing is still in progress, previews arrive as they can; a line may say "Showing step 5 · step 6's preview is on its way," or, after the drawing, that a preview waits for the device to cool.

### The finished drawing

The drawing itself, as saved to Photos. The hand never saw your photograph. It drew from the eye's words, filling in the rest from what it knows. This is what Thomas saw, as far as it could carry it in words.

### In the silent loop

With the eye off, the tray has no eye chapter. The words moment shows **Your instruction** and sits in the hand's chapter. The hand starts not from noise but from your photograph: it buries the photo in noise, then refines it back toward your instruction. The **Transform** setting decides how deep: the engine skips the noisiest of the planned steps and runs only the rest, which is why a silent-loop shot has fewer steps than its setting.

### Watching the queue

With **Watch the queue**, the tray follows each developing shot in turn. When one finishes, it holds on the finished drawing for a few seconds, then moves to the next. Under the slider a line keeps you informed: "The next shot is developing" (with **Watch the next shot**), "Cooling down: the next shot waits for the iPhone to cool," "Paused. The next shot waits until you resume.", or "That was the last shot." While you watch a shot develop, the screen stays awake.

### What the tray shows for each model

Each model shows what it really gives. Its Model Library card lists the same thing.

| | Apple Intelligence | Qwen3.5-2B | SmolVLM2-500M |
|---|:---:|:---:|:---:|
| Its words (live, as it writes them) | Shows | Shows | Shows |
| How it took in your photo (tokens, time) | Shows | Not shown | Not shown |
| Its numbers (every square of your photo) | Not shown | Shows (2,048 per square) | Shows (960 per square) |
| Where it looked (on your photo, for every word) | Not shown | Shows | Shows (two looks) |
| Where its attention went (picture, instructions, own words) | Not shown | Shows | Shows |

| | SD-Turbo (MLX) | SD-2.1 (Core ML) |
|---|:---:|:---:|
| Every step | Shows (1 to 6 steps) | Shows (15 to 30 steps) |
| Its best guess | Shows | Shows |

Apple's eye keeps its numbers and its attention inside the system, so the tray shows what Apple does report: how it took in the photo.

---

## The models

There is always an eye and a hand, because no single small model can both see and draw. A vision model reads pictures and writes words but cannot draw; a drawing model draws from words but cannot read a picture. Thomas chains them, and the words in between are the whole point.

### The eyes

| Eye | Size | License | About a look* | In short |
|---|---|---|---|---|
| **Apple Intelligence** | Built in | Apple's | 4.9 s | Already on the device, nothing to download. A filter stops some images before the model sees them; Thomas then asks again with the filter relaxed. May use Apple's Private Cloud Compute when online. |
| **Qwen3.5-2B** | 1.6 GB | Apache 2.0 | 5.2 s | Downloaded. Sees differently from Apple's model, and largely ignores instructions about how to speak. No content filter. |
| **SmolVLM2-500M** | 1.0 GB | Apache 2.0 | 14.6 s | The smallest eye, about 500 million parameters against Qwen's two billion. A different lineage, no content filter, so it says what it sees whatever you point it at. Takes the least room and the least memory. |

*Measured on an iPhone 16 Plus, loading included. Once you use a model, its Model Library card shows your own device's time instead.

Apple's eye needs a device with Apple Intelligence, with Apple Intelligence turned on. Thomas works on a fresh install with Apple's eye alone: the photograph and the words, with no download at all.

### The hands

| Hand | Size | License | About a drawing* | In short |
|---|---|---|---|---|
| **SD-Turbo (MLX)** | 2.4 GB | Stability AI Community License (free for users under $1M revenue) | 12 s | Draws on the GPU in a handful of steps. Never sees your photograph. |
| **SD-2.1 (Core ML)** | 1.1 GB | CreativeML OpenRAIL++-M | 10.5 s | Draws on the Neural Engine, using about a third of the memory and running cooler. Prepared for your device after downloading and after each update. The only hand that can work with the eye off (the silent loop). |

*Measured on an iPhone 16 Plus at the default steps.

---

## Privacy

Thomas collects nothing. There are no accounts, no analytics, no advertising, and no servers run by the developer. Your pictures are saved in your own Photos library, not kept hostage in an app.

Whether anything leaves your device depends on two choices, and the [privacy lock](#the-privacy-lock) shows the answer at every moment:

- **The eye.** A downloaded eye keeps the look on your device. Apple's eye may use Apple's Private Cloud Compute when you are online.
- **The place.** Raw coordinates keep it on your device. A place name is looked up with Apple's mapping service when you are online.

With a downloaded eye (or offline) and raw coordinates on (or Location off, or offline), Thomas sends nothing about a shot anywhere. The hand always draws on your device. (Once a print is in Photos, it is Photos' to handle: if you use iCloud Photos, Apple syncs it as it does every picture.)

Other details:

- **Photos access** is add-only: Thomas can add pictures but cannot read your library. When you load pictures to develop, the system picker hands Thomas only the pictures you choose.
- **Location** appears only in the visible footer. Thomas never writes hidden GPS coordinates into the saved file.
- **Model downloads** come from Hugging Face, only when you ask, and then run entirely on your device.
- **Negatives** (the tray's records) stay on your device and are not backed up.
- **Timings** for the Model Library cards are kept on your device and never sent anywhere.

Thomas is open source. If you would rather read the code than take any of this on faith, the link is in About Thomas.

---

## Glossary

**Attention.** How a model, while choosing its next word, weighs everything in front of it: the picture, its instructions, and what it has already said. The tray shows where that weight went.

**Attention head.** One of several parallel "looks" inside each attention layer. The tray averages them.

**Attention sink.** A fixed place where a model parks spare attention. It shows up as a square that glows for nearly every word. Real, and normal.

**Core ML.** Apple's system for running machine-learning models, used here to run SD-2.1 on the Neural Engine.

**Decoder.** The last part of drawing, which turns the model's numbers into a picture you can see.

**Diffusion model.** The kind of model the hand is: it draws by starting from random noise and removing a little at each step until a picture matches the words.

**Embedding.** Another name for a vector that places something (a word, a patch of a photo) on a model's map of ideas.

**Latent / working image.** What the hand is actually holding partway through a drawing: a compact grid of numbers, shown in the tray as a picture.

**Matrix.** A table of numbers. All of a photo's square vectors, stacked, make one.

**MLX.** Apple's open-source system for running models on Apple silicon's GPU, used here for Qwen, SmolVLM, and SD-Turbo.

**Neural Engine.** The part of Apple's chips built for machine-learning work.

**Parameters.** The numbers a model learned in training. A rough measure of a model's size (SmolVLM has about 500 million, Qwen about two billion).

**Steps.** How many times the hand removes noise on its way to a drawing.

**System prompt.** The standing instructions given to the eye with every photo.

**Temperature.** How far down its list of likely next words the eye is willing to reach. Lower is steadier; higher is more varied.

**Token / word piece.** The unit a language model reads and writes in: often a whole word, sometimes part of one ("bl" + "inding"). Apple's eye also reads your photo as tokens.

**Upscaler.** A tool that enlarges a picture after it is made.

**Vector.** A list of numbers that places something on a model's map of ideas, the way coordinates place a city on a map.

**Vision model (VLM).** The kind of model the eye is: one part turns a picture into numbers, the other turns those numbers into words.

---

*Reality, machine perception, machine re-imagining. The gap is the art.*
