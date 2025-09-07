# AlignKwds – User Manual

`AlignKwds` is a Neovim command that neatly aligns tokens into columns based on **spaces (PBS)** and **non-spaces (NPBS)**.
It is *span-aware* (handles quotes, parentheses, etc.), supports **custom blank characters**, and even lets you treat **keywords like `\sp` or `\sw` as spaces**.

<!--
## Special thanks goes to ChatGPT5

In most of my life, I have been extensively learning Pascal, Java, JavaScript,
and other languages but Lua. And I have zero knowledge about Lua before. But
thanks to the coming of ChatGPT, I could write lua program which runs on
NeoVim.

In most of my life, I have been speaking only Japanese. But the coming of
ChatGPT made me available to write User Manual in English.

This manual was mostly written by ChatGPT, except this section.

Thank you, ChatGPT, and thank you God.
-->

## Special Thanks to ChatGPT-5

For most of my life I studied and worked with Pascal, Java, JavaScript, and many other languages — but never Lua. Before this project I had zero knowledge of Lua. Thanks to the arrival of ChatGPT, I was able to write a Lua program that runs inside Neovim.

Similarly, for most of my life I spoke only Japanese. Yet with ChatGPT’s help, I was able to write this User Manual in English.

This manual was written mostly with ChatGPT’s assistance, except for this section.

Thank you, ChatGPT — and thank You, God.

---

## 📦 Installation

Place the Lua file at:

```
~/.config/nvim/lua/align_rfc/init.lua
```

In your `init.lua`:

```lua
require("align_rfc").setup()
```

Now the command `:AlignKwds` is available.

---

## 🚀 Basic Usage

1. Select lines in visual mode, or position cursor inside a block of text.
2. Run:

```
:'<,'>AlignKwds
```

This aligns the selection.
If no range is given, it auto-expands to the contiguous block around the cursor.

---

## ⚙️ Options

You can configure behavior either at setup or per call.

### 1. PBS characters

Which characters count as *spaces* (Potential Blank Space, PBS).

Default: `" \t"`

```vim
:'<,'>AlignKwds pbs=" \t{}"
```

Here, braces `{}` are treated like spaces too.

---

### 2. PBS keywords

Literal sequences that behave like spaces.

```vim
:'<,'>AlignKwds pbs=" \t" pbskw="\\sp \\sw"
```

Now the keywords `\sp` and `\sw` are treated as PBS.

* They align like spaces.
* They are preserved verbatim in output.
* Longest keyword is matched first.

---

### 3. PBS keywords inside spans

By default, keywords inside quotes/parentheses are *not* treated as PBS.
You can override:

```vim
:'<,'>AlignKwds pbskw="\\sp" pbskw_in_spans=true
```

---

### 4. Protected pairs (spans)

Define delimiters that form indivisible NPBS blocks.

Default: `() ""`

```vim
:'<,'>AlignKwds pairs="() [] {} \"\""
```

Now `()`, `[]`, `{}`, and `""` behave as NPBS spans.

---

### 5. Escape character

Default: `\`

```vim
:'<,'>AlignKwds esc="\\"
```

Inside spans, `\x` makes `x` literal (does not close span).

---

### 6. Block expansion

By default, if no range is given, the command aligns the contiguous block around the cursor. Disable:

```vim
:'<,'>AlignKwds block=false
```

---

## 📐 Examples

### Example 1 — Normal spaces

PBS = `" \t"`

```
foo { bar } baz
foo baz bum
```

→

```
foo { bar } baz
foo baz      bum
```

---

### Example 2 — Braces as spaces

PBS = `" \t{}"`

```
foo { bar } baz
foo baz bum
```

→

```
foo { bar } baz
foo   baz   bum
```

---

### Example 3 — Keywords as spaces

PBS = `" \t"`, PBS keywords = `{"\sp","\sw"}`

```
"w" \sp \sw "|a"
"n" \sp \sw "|ə"
```

→

```
"w"   \sp \sw   "|a"
"n"   \sp \sw   "|ə"
```

---

## 🔒 Guarantees

* **Idempotent**: Running it twice doesn’t change the result.
* **Span-aware**: Quoted or parenthesized blocks stay intact.
* **Verbatim**: All original tokens are preserved.
* **Unicode-safe**: Uses display width, so wide characters align correctly.

---

## 🛠️ Tips

* Use `pbskw` for macros like `\sp`, `\sw`, `\tab`.
* Add exotic blanks (e.g. full-width space `\u{3000}`) to `pbs`.
* Define more pairs if you often align JSON, Lisp, or LaTeX code.
* For debugging, we can add a `:AlignRFCDebug` helper to show how a line splits into PBS/NPBS.


