# Bug: the display-art stash is retained on rows when the cache write is skipped

Found 2026-08-21 by audit (item C1), investigated but **not fixed**. The file:line anchors below are against `main` at `f814829`; the working tree was dirty at that commit but none of the anchored files were among the modifications, so the anchors are clean. Re-check them before acting.

Severity: **low**. The audit filed it as medium on a magnitude claim that does not survive checking — see *What the audit got wrong*.

## The mechanism

`_archivedDisplayArtDataForStorage` is a strong ivar on `AudioTrackArtwork` (`AudioTrackArtwork.m:258`). It is written once, at compaction, from `+metadataWithURL:` (`AudioTrackMetadata.mm:481`), immediately before `discardArtData` — which deliberately does **not** clear it, and must not: the stash is cut from the original bytes one line earlier and the discard would destroy it before the write.

Its only consumer in the whole tree is `takeArchivedDisplayArtDataForStorage` at `AudioTrackMetadataLoader.m:1089`, nested under two guards:

- outer — `if (metadata.parsedOK && cacheKey)` (`AudioTrackMetadataLoader.m:1063`)
- inner — `if (generation == owner.cacheGeneration)` (`AudioTrackMetadataLoader.m:1084`)

Miss either and nothing ever consumes it. The instance holding it is the one `installMetadataIfUnresolved:` puts on the `AudioTrack`, and tracks live for the playlist's lifetime, so the bytes are pinned until the playlist goes.

The in-branch comment at `AudioTrackMetadataLoader.m:1086-1088` — *"The stash is consumed either way, so a skipped write costs the header one extraction, never a leak"* — is true of the inner write-then-recheck pair only. It says nothing about the outer guard, and reads as if it covered both.

## It contradicts a documented rule

`Audio/Metadata/CLAUDE.md:75`:

> The rendition is **disk-resident only**: rows never retain it (the stash is consumed by the one cache write), so per-row memory stays at the 128px bytes, whatever the sidecar weighs.

The code does not keep that. This is the main reason to fix it: the doc states the intent correctly, so the fix is bringing the code back to a rule already written, not a new design.

## What the audit got wrong

The finding says Clear Cache means *"every art-bearing row parsed afterwards pins its full rendition ... hundreds of MB"*. It does not.

`invalidateWithCompletion:` bumps the generation exactly once (`AudioTrackMetadataCache.m:119`), and `generation` is captured at the **top** of each parse (`AudioTrackMetadataLoader.m:1060`). A parse that *starts* after the bump captures the new value and matches. Only parses straddling the bump leak, so the exposure is bounded by `localMetadataParseConcurrency` — **4** in production (`AudioLoadingConfiguration.m:24`). Roughly four rows per Clear Cache, single-digit MB.

## The three escape hatches, audited

1. **Generation mismatch.** Real, bounded at the parse concurrency per Clear Cache, as above. The debug channel can raise that concurrency (`AudioLoadingConfiguration+Debug.m:118`), which raises the bound with it.
2. **`cacheKey == nil`.** Real but rare — needs a stat failure both at cache-check time and again after the parse (`NSURL+Hash` returns nil rather than a degenerate key). Transient by nature.
3. **`!metadata.parsedOK`.** Effectively unreachable *with a stash present*: art is adopted at `AudioTrackMetadata.mm:550` and `parsedOK = YES` is set at `:555`, with nothing between them that can throw. A parse that fails earlier never adopted art, so `artDataForArchivedDisplayArt` is nil and `stashArchivedDisplayArtDataIfPossible` stores nothing.

Two things checked and cleared, so they are not re-investigated:

- **Waiter rows are safe.** `copyWithZone:` (`AudioTrackArtwork.m:320-323`) deliberately does not transfer the stash, so only the parsing row can pin it — a duplicate-URL playlist does not multiply the leak.
- **A nil `_owner` is safe.** `generation` reads 0 from the nil weak owner and `owner.cacheGeneration` reads 0 again, so the guard matches, the take runs, and the nil disk cache no-ops the write.

## The fix

The rendition is not row state. It is a second output of the parse that exists for exactly one write. Modelling it as an ivar with a "consumed exactly once" discipline is what created the bug; modelling it as an out-param makes retention impossible rather than merely intended. Net effect is a deletion: one ivar, two methods, two declarations and two clear sites go, one out-param arrives.

1. `AudioTrackMetadata.mm:438` — `stashArchivedDisplayArtDataIfPossible` becomes `- (nullable NSData *)archivedDisplayArtDataForStorage`, returning nil / the verbatim original / the downscale instead of calling into the artwork. Same three branches, same bound logic.
2. `AudioTrackMetadata.mm:467` — `+metadataWithURL:` gains `displayArtData:(NSData *_Nullable __autoreleasing *_Nullable)`, filled before `discardArtData`, ordering otherwise unchanged. This matches the out-param idiom the file already uses for `AudioTrackArtworkExtractor`'s `artData` (`AudioTrackArtworkInternal.h:31-33`).
3. `AudioTrackMetadataInternal.h:18` — update the declaration and the comment above it (`:20-21` mentions the stash).
4. `AudioTrackMetadataLoader.m:1061` — take the rendition into a local at the parse and use it inside the guards. The local is released with the method frame whichever guard fails, which is the whole fix.
5. `AudioTrackArtwork.m` — delete the ivar (`:258`), `stashArchivedDisplayArtDataForStorage:` (`:429`), `takeArchivedDisplayArtDataForStorage` (`:435`), and the two now-dead clear sites in `adoptParsedArtData:` (`:373`) and `adoptArchivedThumbnailData:` (`:392`). **`artDataForArchivedDisplayArt` stays** — that is the `_embeddedArtData` read, still needed by step 1.
6. `AudioTrackArtworkInternal.h:66-70` — delete both declarations, trim the comment to the provider half.
7. Comments and doc: `AudioTrackArtwork.m:321` (the "storage stash deliberately does not transfer" sentence goes vacuous), `AudioTrackMetadataLoader.m:1086-1088` (reword to the local's lifetime, which is what actually makes "never a leak" true), and `Audio/Metadata/CLAUDE.md:75` (drop the parenthetical — after this the rendition never lands on a row at all).

`grep -rn -i stash Vibe` is the completeness check for step 7; the three unrelated hits are `AudioWaveformView.mm:22` and `AudioFileMaterializationCoordinator.m:111`.

### Alternative, if the churn is unwanted

Hoist the `takeArchivedDisplayArtDataForStorage` call from `:1089` up to `:1061` into a local used inside the guards. One-line move, zero API churn, fixes all three hatches. It keeps the ivar and therefore keeps the discipline requirement that produced the bug, so it is the lesser fix — but it is a legitimate one.

## Verification

`make analyze CONFIG=Release`, `make build`, `make build-ios`, `make check-layout`, `make check-vocabulary`, `make test`.

Behavioural, through the debug channel:

- Normal scan of art-bearing files — `#displayArt` keys land in the store and the mac header shows art with no source re-read.
- Clear Cache mid-scan — the straddling rows lose their sidecar, the header pays one extraction, art still shows. That is the documented "one extraction, never a leak" degradation, and it is what the fix makes true.

**No unit test.** The seam needs real audio files and a live PINCache, and `Tests/` is pure logic and host-less (`Tests/CLAUDE.md`). Deleting the state is the durable guarantee here; a test would only assert that one call site still behaves.
