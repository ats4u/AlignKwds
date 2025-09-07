# Alignment Specification (RFC Draft v2.2 – Final)

## 1. Scope

* The system **MUST** align tokens consisting of:

  * Non-space character blocks, and
  * Blocks surrounded by configured span delimiters (quotes, parentheses, etc.), treated as indivisible **NPBS**.

* “Space” **MUST** be defined as:

  * Standard blanks (`\t`, `\n`, space), and
  * Any additional **Potential Blank Space (PBS)** characters supplied via configuration.

* All PBS characters **MUST** behave like spaces for splitting and alignment.

* Processing **MUST** occur line by line within a specified text region.

---

## 2. Line Structure

* Each line **MUST** be parsed into alternating fields:

  ```
  PBS → NPBS → PBS → NPBS → …
  ```

* Each field is either:

  * **PBS**: a contiguous block of PBS characters, or
  * **NPBS**: a contiguous block of non-PBS characters (including spans).

* The first PBS field **MUST** represent indentation.

* If a line has no leading spaces, the first PBS field **MUST** be empty.

---

## 3. Span Semantics (NPBS)

* Span delimiters are configured via **`protected_pairs`** (default: `(")", "\"\"")`).
* **Close-first rule**: inside a span, if the current character equals the expected closer, the span **closes**.
* **Symmetric delimiters** (e.g. `"`): act as closers before openers; they **do not self-nest**.
* **Nesting** of *different* delimiters is allowed (e.g. `"( (x) )"`).
* **Escape**: inside spans, an **`escape_char`** (default `\`) makes the next codepoint literal.
* The entire span (including delimiters and any PBS inside) is one **NPBS** field, preserved verbatim.

---

## 4. Preservation & Padding

* PBS blocks and NPBS tokens **MUST** be preserved exactly.
* Padding **MUST** consist only of ASCII spaces (`U+0020`), appended **after PBS** to achieve alignment.
* The algorithm **MUST NOT** insert padding inside NPBS.

---

## 5. Column Model

* The alignment grid **MUST** be column-based.
* Columns alternate:

  * **Column 1**: PBS only (indentation).
  * **Columns 2..N**: NPBS followed by PBS.
* Column 1 **MUST NOT** contain NPBS.

---

## 6. Width Computation

* All widths **MUST** use display width (`vim.fn.strdisplaywidth`).
* For each column, the maximum width across rows is computed:

  * Column 1: width of indent PBS.
  * Columns 2..N: width of NPBS + PBS combined.

---

## 7. Rebuild & Idempotence

* For each row, pad its PBS so each **existing** column matches the column maximum.
* **Do not synthesize** trailing columns a row did not originally have.
* Rebuild lines by concatenating the row’s fields in order.
* Re-running the aligner with the same configuration **MUST** produce identical output.

---

## 8. Special Cases

* **Empty lines**: treated as a single PBS column with value `NULL`. Contributes width `0` to column 1.
* **PBS-only lines**: preserved unchanged; their PBS width contributes to column 1.

---

## 9. Ragged Rows

* The maximum number of columns is determined by the widest row.
* Rows with fewer columns are processed safely.
* Missing trailing fields are ignored in padding.
* Width calculations consider only existing fields.

---

## 10. Configuration Parameters

* `pbs_chars`: string of characters to treat as PBS. Default: `" \t"`.
* `protected_pairs`: list of `{open, close}` delimiters for spans. Default: `{ {'"', '"'}, {'(', ')'} }`.
* `escape_char`: character that escapes the next codepoint inside spans. Default: `\`.
* `expand_block_when_no_range`: boolean; if true, operating without a range expands to the contiguous nonblank block around the cursor. Default: `true`.

---

## 11. Examples

### Example 1 — Braces as NPBS

PBS = `" \t"`

```
Input:   foo { bar } baz
         foo baz bum

Output:  foo { bar } baz
         foo baz      bum
```

Explanation: Braces are not PBS, so they “stick” as NPBS tokens.

---

### Example 2 — Braces as PBS

PBS = `" \t{}"`

```
Input:   foo { bar } baz
         foo baz bum

Output:  foo { bar } baz
         foo   baz   bum
```

Explanation: Braces are included in PBS, so they behave like spaces and split fields.

---

✅ This version (v2.2) reflects the **actual behavior of your program** after the fixes:

* Correct PBS parsing (quoted values & escapes).
* Symmetric delimiters handled with close-first rule.
* Idempotent rebuild (no phantom columns).


