# Alignment Specification (RFC Draft v2.1 – Finalized)

## 1. Scope

* The system **MUST** align tokens consisting of:

  * Non-space character blocks, and
  * Blocks surrounded by configured span delimiters (quotes, parentheses, etc.), treated as indivisible **NPBS**.
* “Space” **MUST** be defined as:

  * Standard blanks (`\t`, `\n`, space), and
  * Any additional **Potential Blank Space (PBS)** characters supplied via configuration.
* All PBS **MUST** behave like spaces for splitting and alignment.
* Processing **MUST** occur line by line within a specified text region.

---

## 2. Line Structure

* Each line **MUST** be parsed into alternating fields:

  ```
  PBS → NPBS → PBS → NPBS → …
  ```
* Each field is either:

  * **PBS**: a contiguous block of PBS characters; or
  * **NPBS**: a contiguous block of non-PBS characters (including whole spans).
* The first PBS field **MUST** be indentation; if there is no leading space, it is empty.

---

## 3. Span Semantics (NPBS)

* Span delimiters are configured via **`protected_pairs`** (default: `(")", "\"\"")`).
* **Close-first rule**: inside a span, if the current character equals the expected closer, the span **closes**.
* **Symmetric delimiters** (e.g. `"`): are closers before potential openers; they **do not self-nest**.
* **Nesting** of *different* delimiters is allowed (e.g. `"( (x) )"`).
* **Escape**: inside spans, an **`escape_char`** (default `\`) makes the next codepoint literal (doesn’t close or open spans).
* The entire span (including its delimiters and internal PBS) is a single **NPBS** field and is preserved verbatim.

---

## 4. Preservation & Padding

* PBS blocks and NPBS tokens **MUST** be preserved exactly as written.
* Padding **MUST** be appended **after PBS** to reach alignment; padding is ASCII space (`U+0020`) only.
* The algorithm **MUST NOT** insert padding inside NPBS.

---

## 5. Column Model

* Columns alternate:

  * **Column 1**: PBS only (indentation),
  * **Columns 2..N**: NPBS followed by PBS.
* Column 1 **MUST NOT** contain NPBS.

---

## 6. Width Computation

* Use display width (`vim.fn.strdisplaywidth`) for all measurements.
* For each column, compute the maximum width across rows:

  * Column 1: width of indent PBS.
  * Columns 2..N: width of **NPBS + PBS** combined.

---

## 7. Rebuild & Idempotence

* For each row, pad its PBS so each **existing** column reaches the column maximum.
* **Do not synthesize** trailing columns that the row did not originally have.
* Rebuild by concatenation of that row’s columns only.
* Running the aligner repeatedly with the same configuration **MUST** produce identical output.

---

## 8. Special Cases

* **Empty lines**: behave as a single PBS column with `NULL` width (`0`) in column 1.
* **PBS-only lines**: preserved unchanged; their PBS contributes to column 1 width.

---

## 9. Ragged Rows

* The total number of columns is determined by the widest row.
* Rows with fewer columns are processed without error; missing trailing fields are ignored in padding and width.

---

## 10. Examples

**Example 1 — braces as NPBS**
PBS = `" \t"`

```
Input:   foo { bar } baz
         foo baz bum
Output:  foo { bar } baz
         foo baz      bum
```

**Example 2 — braces as PBS**
PBS = `" \t{}"`

```
Input:   foo { bar } baz
         foo baz bum
Output:  foo { bar } baz
         foo   baz   bum
```

---

If that looks good, you’re fully in sync with the current code. If you’d like, I can also drop a tiny “debug widths” command that prints the parsed columns and measured widths for the current selection — handy for future puzzles like the `(j)` case.

