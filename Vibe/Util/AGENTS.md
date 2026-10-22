# Util

**Code with no feature.** That is the whole admission test, and it is stricter than it sounds. If you can name the feature a file serves, it belongs in that feature's directory, however utility-shaped it looks. `Mac/` (AppKit) and `iOS/` (UIKit) have their own `AGENTS.md`.

**`Util/` may not call anything stateful**: a singleton, a setting, a grant or a panel. Stateless code is fair game wherever it lives.

**The featureless helpers another app could use are in vibe-libs' `core/Common`**, and its `AGENTS.md` describes them. They are the path spelling (`FilePaths`), the disk key (`NSURL+Hash`, with `NSData (Hash)`'s `sha1Hex`), file emptiness and identity, the stall sampler (`StallWatch`), the work lanes (`AudioWorkScheduler`), the update timer and its math, the weak proxy, the helper macros, the integer token parser, the colon rule (`NSString+FormLabel`), and build provenance (`NSBundle+BuildInfo` and `generate-git-info.sh`). `HelperMacros.h` and `VibeMacros.h` reach every translation unit through the `.pch`, so anything added to either is paid for everywhere. What stays here is Vibe's: `Formatters` and the two platform halves.

## Formatters joins every info line

**`infoLineFromFields:` joins the codec and tempo fields with ` | `.** It drops empty fields and keeps the rest in order. `tempoLineWithBPM:keyText:` builds both shells' tempo and key line through it, and `fileInfoLineForMetadata:` their codec line. Each shell's doc describes its fields. **The key is always the last field.** The mac colors it as the line's suffix.

## Categories

**Behavior added to a foreign class is a category, never a free function taking that class as its first argument.** A category on an AppKit or UIKit class belongs in `Mac/` or `iOS/`. A portable one with no feature belongs in `Categories/`, or in vibe-libs' `core/Common` when another app could use it. One that serves a feature, such as `PINCache+VibeAudioCache` for the audio caches, belongs in that feature's directory. One on the app's own classes belongs beside that class. The deliberate exceptions are the free functions of vibe-libs' `PlatformImage.h` and `PlatformColor.h`, where the class differs per target (root `AGENTS.md`, Vocabulary).
