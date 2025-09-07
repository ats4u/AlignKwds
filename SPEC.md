# Alignment Specification (RFC Draft v2.3 – Keywords as PBS)

## 1. Scope

* The system **MUST** align tokens consisting of:

  * Non-space character blocks, and
  * Blocks surrounded by configured span delimiters (quotes, parentheses, etc.), treated as indivisible **NPBS**.
* “Space” **MUST** be defined as:

  * Standard blanks (`\t`, `\n`, space),
  * Any additional **Potential Blank Space (PBS)** characters supplied via configuration, and
  * Any configured **PBS keywords** (multi-character sequences).
* All PBS characters and PBS keywords **MUST** behave like spaces for splitting and alignment.
* Processing **MUST** occur line by line within a specified text region.

---

## 2. Line Structure

* Each line **MUST** be parsed into alternating fields:

  ```
  PBS → NPBS → PBS → NPBS → …
  ```

* Each field is either:

  * **PBS**: a contiguous block of PBS characters and/or PBS keywords, or
  * **NPBS**: a contiguous block of non-PBS characters (including whole spans).

* The first PBS field **MUST** represent indentation.

* If a line has no leading PBS, the first PBS field **MUST** be empty.

---

## 3. Span Semantics (NPBS)

* Span delimiters are configured via **`protected_pairs`** (default: quotes and parentheses).
* **Close-first rule**: inside a span, if the current character equals the expected closer, the span **closes**.
* **Symmetric delimiters** (e.g. `"`): treated as closers before potential openers; they **do not self-nest**.
* **Nesting** of different delimiters is allowed (e.g. `"( (x) )"`).
* **Escape**: inside spans, an **`escape_char`** (default `\`) makes the next codepoint literal.
* By default, **PBS keywords inside spans do not split fields** (the span remains NPBS).

  * An optional configuration flag **`pbs_keywords_in_spans`** may override this.

---

## 4. PBS Keywords

* A **PBS keyword** is a literal sequence of one or more characters configured by the user.
* Keywords are matched **longest-first** to avoid ambiguity.
* When a keyword is recognized:

  * Outside spans → it begins or extends a PBS field.
  * Inside spans → ignored by default (the span remains NPBS).
* PBS keywords **MUST** be preserved verbatim in the output and contribute to PBS width.

---

## 5. Preservation & Padding

* PBS blocks (including PBS keywords) and NPBS tokens **MUST** be preserved exactly.
* Padding **MUST** consist only of ASCII spaces (`U+0020`), appended after PBS fields to achieve alignment.
* Padding **MUST NOT** be inserted inside NPBS or keywords.

---

## 6. Column Model

* The alignment grid **MUST** be column-based.
* Columns alternate:

  * **Column 1**: PBS only (indentation).
  * **Columns 2..N**: NPBS followed by PBS.
* Column 1 **MUST NOT** contain NPBS.

---

## 7. Width Computation

* All widths **MUST** use display width (`vim.fn.strdisplaywidth`).
* For each column, compute the maximum width across rows:

  * Column 1: width of indent PBS (including keywords).
  * Columns 2..N: width of NPBS + PBS combined.

---

## 8. Rebuild & Idempotence

* For each row, pad its PBS so each **existing** column matches the column maximum.
* **Do not synthesize** trailing columns a row did not originally have.
* Rebuild lines by concatenating the row’s fields in order.
* Re-running the aligner with the same configuration **MUST** produce identical output.

---

## 9. Special Cases

* **Empty lines**: treated as a single PBS column with value `NULL`. Contributes width `0` to column 1.
* **PBS-only lines**: preserved unchanged; their PBS (including keywords) contributes to column 1 width.

---

## 10. Ragged Rows

* The maximum number of columns is determined by the widest row.
* Rows with fewer columns are processed safely.
* Missing trailing fields are ignored in padding.
* Width calculations consider only existing fields.

---

## 11. Configuration Parameters

* `pbs_chars`: string of characters to treat as PBS. Default: `" \t"`.
* `pbs_keywords`: list of literal sequences to treat as PBS. Default: `{}`.
* `pbs_keywords_in_spans`: boolean; if `true`, PBS keywords inside spans split fields. Default: `false`.
* `protected_pairs`: list of `{open, close}` delimiters for spans. Default: `{ {'"', '"'}, {'(', ')'} }`.
* `escape_char`: character that escapes the next codepoint inside spans. Default: `\`.
* `expand_block_when_no_range`: boolean; if true, operating without a range expands to the contiguous nonblank block around the cursor. Default: `true`.

---

## 12. Examples

### Example 1 — braces as NPBS

PBS = `" \t"`

```
Input:   foo { bar } baz
         foo baz bum

Output:  foo { bar } baz
         foo baz      bum
```

### Example 2 — braces as PBS

PBS = `" \t{}"`

```
Input:   foo { bar } baz
         foo baz bum

Output:  foo { bar } baz
         foo   baz   bum
```

### Example 3 — keywords as PBS

PBS = `" \t"`, PBS keywords = `{"\\sp","\\sw"}`

```
Input:   "w" \sp \sw "|a"
         "n" \sp \sw "|ə"

Output:  "w"   \sp \sw   "|a"
         "n"   \sp \sw   "|ə"
```

---

✅ This RFC v2.3 reflects the new **PBS keyword** functionality.

---

Would you like me to also append an **“Implementation Notes” appendix** (like RFCs often do), showing how PBS keyword matching is longest-first and integrated into the parser loop? That way the spec isn’t just external behavior but also guidance for reimplementors.

