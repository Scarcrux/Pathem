# Translations

Pathem ships in English, French, German, Spanish, Japanese, and Simplified
Chinese. The non-English strings are machine-translated and provisional, so a
native speaker's review is genuinely welcome. There are two ways to help.

## Just report it (no code)

Open a **Translation feedback** issue: say the language, where you saw the text,
the current wording, and (if you can) a better one. That's it.

## Fix it directly (a pull request)

Each language is one file:

```
Sources/Pathem/Resources/<lang>.lproj/Localizable.strings
```

where `<lang>` is `fr`, `de`, `es`, `ja`, or `zh-hans`. Each line is
`"key" = "value";`. **Edit only the value.** Two rules keep the app working:

- **Never change the key** (the part left of `=`). It ties the string to the code.
- **Keep every `%@` and `%d` placeholder**, in the same set as English. `%@` is a
  name or piece of text; `%d` is a number. Reorder the sentence freely, but if
  English has `%d` the translation must too, or the app will garble that string.

Compare against the English source of truth in `en.lproj/Localizable.strings`.

## Check your change

```
python3 scripts/l10n_lint.py
```

It verifies every key is present, the file parses, and the `%@`/`%d` placeholders
match English. It must print `ok` for your language (this also runs in CI). Then
open a pull request. Thank you.
