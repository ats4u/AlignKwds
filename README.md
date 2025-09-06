# Alignment Specification (RFC Draft v2 – Corrected & Clarified)

## 1. Scope

* The system **MUST** align tokens consisting of:

  * Non-space character blocks, and
  * Blocks surrounded by span delimiters (quotes, parentheses, braces, etc.), treated as NPBS.
* “Space” **MUST** be defined as:

  * Standard blank characters (`\t`, `\n`, `" "`), and
  * Any additional *Potential Blank Space characters (PBS)* supplied via configuration.
* All PBS characters **MUST** be treated as equivalent to spaces for splitting and alignment.
* Processing **MUST** occur line by line within a specified text region.

---

## 2. Line Structure

* Each line **MUST** be parsed as a sequence of alternating fields.

* Each field **MUST** be one of:

  * **PBS**: a contiguous block of PBS characters, or
  * **NPBS**: a block of non-PBS characters.

* Field order **MUST** alternate as:

  ```
  PBS → NPBS → PBS → NPBS → …
  ```

* The first PBS field **MUST** represent indentation.

* If a line has no leading spaces, the first PBS field **MUST** be empty.

---

## 3. Preservation Rules

* PBS blocks **MUST** be preserved exactly as written.
* NPBS fields **MUST** be preserved exactly.
* Padding **MUST** consist only of additional ASCII spaces (`U+0020`) appended after PBS blocks to reach alignment width.

---

## 4. Column Model

* The alignment grid **MUST** be column-based.
* Columns alternate as follows:

  * Column 1: PBS only (indentation).
  * Columns 2..N: NPBS followed by PBS.
* Column 1 **MUST NOT** contain an NPBS field.

---

## 5. Alignment Algorithm

1. Collect all lines in the target region.
2. For each column, compute the maximum display width across rows:

   * Column 1 width = max width of indent PBS.
   * Columns 2..N width = max width of NPBS + PBS.
3. For each row, pad PBS fields with spaces until the total column width matches the maximum.
4. Rebuild each line by concatenating its padded fields in order.
5. Continue until all rows have been rebuilt.

---

## 6. Special Cases

* **Empty lines**: treated as a single PBS column with value `NULL`. Contributes width `0` to column 1.
* **PBS-only lines**: preserved unchanged, but their PBS width still contributes to column 1.

---

## 7. Ragged Rows

* The maximum number of columns is determined by the widest row.
* Rows with fewer columns **MUST** be processed safely.
* Missing trailing fields are ignored in padding.
* Width calculations consider only existing fields.

---

## 8. Output Guarantees

* Alignment is **idempotent**: re-running the aligner produces identical output.
* Indentation and blank lines are preserved.
* PBS blocks and NPBS tokens are preserved verbatim.

---

## 9. Examples

### Example 1

PBS = `" \t"` (spaces and tabs only)

**Input**

```
foo { bar } baz
foo baz bum
```

**Output**

```
foo { bar } baz
foo baz      bum
```

Explanation:
Braces `{` and `}` are treated as NPBS because they are not in `pbs_chars`.
Thus, they “stick” to neighboring tokens and do not act like spaces.

---

### Example 2

PBS = `" \t{}"` (spaces, tabs, and braces)

**Input**

```
foo { bar } baz
foo baz bum
```

**Output**

```
foo { bar } baz
foo   baz   bum
```

Explanation:
Braces `{` and `}` are included in `pbs_chars`.
They are treated exactly like spaces, splitting tokens into separate columns and affecting alignment.



