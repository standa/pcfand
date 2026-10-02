# PC FAND for Visual Studio Code

Syntax highlighting for PC FAND chapter sources: the `NNN-T-Name.txt` files
that `fand TASK --source-out DIR` writes and `--source-in DIR` reads back.
No code runs; the extension only adds two languages and their grammars.

| Language id   | Chapters                | Files                                   |
|---------------|-------------------------|-----------------------------------------|
| `fand`        | F E R M P D U I         | `NNN-F-*.txt` … `NNN-I-*.txt`, `*.fand` |
| `fand-prolog` | L (FAND Prolog)         | `NNN-L-*.txt`                           |

`NNN` is the chapter number (three or four digits) and the letter is the
chapter type, for example `005-F-INVOICE.X.txt`, `011-R-InvList.txt`,
`001-U-.txt`. Other files can be switched with *Change Language Mode* or a
`files.associations` setting.

## Install

From the repository root:

```sh
ln -s "$PWD/tools/vscode-fand" ~/.vscode/extensions/pcfand-fand
```

or copy the directory there (on Windows to
`%USERPROFILE%\.vscode\extensions\pcfand-fand`), then run
*Developer: Reload Window*.

## What is highlighted

- nested comments `{ a { b } c }` and directives `{$include Name}`,
  `{$define …}`, `{$ifdef X}`, `{$ifndef X}`, `{$else}`, `{$endif}`
- strings with `''`, `\nnn` and `\\`; numbers, dates (`1.1.2020`) and times
  (`12:30:15.50`)
- keywords, statements, standard functions and options, in any case;
  identifiers with Czech letters (any non-ASCII character, as in the compiler)
- `#K #C #A #U #D #L #I`, `#I1_FILE`, `#O_FILE`, `#O*_dummy`, `#_FILE`,
  `#RH #PH #DE2 #CH_Field …` as section markers
- field types after `:` in F chapters (`A,30`, `F,9.2`, `D,'DD.MM.YYYY'` …)
- the text templates of R levels and E forms, with their `___` / `@@@` masks
- in L chapters: `#DOMAINS` … `#CLAUSES`, variables, `:-`, `!`, the built-in
  predicates and `@file(Field/Type)` views

The grammar does not know the chapter type, so the heading text above `#_FILE`
in an E chapter is coloured as code.

## License

MIT, like PC FAND.
