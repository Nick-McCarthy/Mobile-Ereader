# EPUB Metadata Extraction

Fields required by the concept: **title, author, publication date, cover**. Any missing field uses a placeholder: `Unknown Title`, `Unknown Author`, `Unknown` (date), and a generated placeholder cover (title + author on a tinted background derived from a hash of the title).

## Parsing steps
1. Read `META-INF/container.xml` → first `<rootfile full-path="…">` → the OPF package document.
2. In the OPF `<metadata>`:
   - **Title:** first `dc:title`. For EPUB 3 with multiple titles, prefer the one refined with `title-type="main"`.
   - **Author:** all `dc:creator` elements whose role is `aut` (EPUB 2 `opf:role="aut"` or EPUB 3 `<meta refines="#id" property="role">aut</meta>`); if no roles at all, take every `dc:creator`. Join multiple authors with `" & "` for display; store the first as the primary for sorting.
     Capture `file-as` (EPUB 2 `opf:file-as` attribute or EPUB 3 `<meta refines property="file-as">`).
   - **Publication date:** `dc:date` with `opf:event="publication"` if present, else first `dc:date`. Ignore EPUB 3 `dcterms:modified`. Accept `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or full ISO timestamps; anything unparseable → null.
   - **Series (bonus):** `calibre:series` / `calibre:series_index` metas, or EPUB 3 `belongs-to-collection` with `collection-type` = `series` and `group-position`.
3. **Cover**, in priority order:
   1. EPUB 3 manifest item with `properties` containing `cover-image`.
   2. EPUB 2 `<meta name="cover" content="<manifest id>">` → that manifest item.
   3. Manifest item whose id or href contains `cover` and has an image media-type.
   4. Guide `<reference type="cover">` → XHTML page → first `<img>`/`<image xlink:href>`.
   5. None → placeholder.
   Downscale to max 600 px on the long edge, encode JPEG q≈0.8, save to `Caches/Covers/<bookId>.jpg`. Resolve hrefs relative to the OPF's directory and percent-decode them.

## Reading metadata without downloading the book
Applies to **Dropbox and OneDrive** (iCloud files are read locally after a coordinated fetch, see [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md#icloud-drive--files-specifics)). An EPUB is a ZIP, and both providers' download endpoints honour HTTP `Range` headers. Each adapter exposes a `ByteRangeReading` (`func read(_ range: Range<Int64>) async throws -> Data`, `var length: Int64`), so the provider-agnostic `RemoteZipReader` can:
1. `GET` the last ~64 KB (`Range: bytes=-65536`) → locate the End-Of-Central-Directory record (and ZIP64 locator if present).
2. Fetch the central directory (if not already inside that tail) → map of entry name → local header offset, compressed size, method.
3. For each needed entry (`container.xml`, the OPF, the cover image) fetch `offset … offset + 30 + nameLen + extraLen + compressedSize` (read the local header first to get the exact lengths), then inflate (`method 8` → raw DEFLATE via `Compression`/zlib; `method 0` → stored).
Typical cost: 3–5 small requests per book instead of the full file. **Fallback:** if the server ignores `Range` (returns 200 with full body) or the archive is malformed, download the whole file to a temp location, parse locally, and discard it unless the user downloads the book.

Local files (imports, already-downloaded books, and iCloud/Files items) are parsed with ZIPFoundation or Readium's `Publication` API.

## Security of untrusted archives
EPUBs are untrusted input.
- Never extract the archive to disk with entry paths as file names (zip-slip). Read entries in-memory or via Readium.
- Cap: total uncompressed bytes read for metadata (e.g. 20 MB), entry count (e.g. 10 000), XML depth, and compression ratio (zip-bomb guard).
- Use `XMLParser` with `shouldResolveExternalEntities = false`.
- A malformed book must never crash sync — record it with placeholders and a `parseError` note.

## Author name normalisation
Concept requirement: books store authors as either `"Last, First"` or `"First Last"`; the user wants a single uniform display format.

**Per-book stored format** (`authorStoredFormat`), auto-detected then user-editable in *Edit details*:
- Contains exactly one comma separating two non-empty parts, and the part after the comma isn't a suffix (`Jr.`, `Sr.`, `II`, `III`, `PhD`…) → `lastFirst`.
- Otherwise, if `file-as` is present and differs from the raw value, use `file-as` to derive the components.
- Otherwise → `firstLast` (single-word names such as "Homer" → family = whole name, given = nil).
- Organisations/ambiguous → `unknown`, displayed verbatim.

**Components:** parse into `given` / `family` (+ optional particles like "van", "de", "le" kept with family, suffixes kept separately). Unit-test a fixture table of tricky names: `"Le Guin, Ursula K."`, `"Ursula K. Le Guin"`, `"Tolkien, J. R. R."`, `"Martin Luther King, Jr."`, `"Homer"`, `"Gabriel García Márquez"`, `"Bob Smith & Jane Doe"`.

**Global setting** (Settings → Library → *Author name format*): `As stored` · `First Last` · `Last, First`. `AuthorNameFormatter` (in `Core`) renders from components; it is a pure function and used everywhere an author is shown. Author sort always uses family name regardless of display setting. The raw value is never mutated, so the setting is fully reversible.
