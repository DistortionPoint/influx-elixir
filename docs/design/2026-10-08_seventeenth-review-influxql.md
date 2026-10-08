# Seventeenth Review (InfluxQL): One Order of Errors, Blanks and Operand Characters

**Date**: 2026-10-08
**Scope**: `Client.Local` InfluxQL parse errors and their order
**Issue**: scheduled quality sweep. Reviews 5b02165.

---

## Problem

- A `)` that closes nothing lost to a later token error, and an unterminated quote or
  comment won over an earlier real parse error (the largest class of wrong bodies).
- Two orderings of errors (`first_error`, and `earliest` recovering positions by re-parsing
  the rendered body, with `guarded` swallowing raises and a `{:final}` skipped unless first).
- `SELECT m. FROM m` answered `[]`; a carriage return was a blank after a keyword; a
  non-ASCII letter or digit was read as an identifier or number character.
- Quadratic work: a `u`-flag regex validated the whole remaining text for every token.

## Decision

- Every check returns `{position, error}` (or `nil`); `InfluxQLCheck.leftmost/2` is the one
  ordering. A lexer error (quote, regular expression, comment) is met when the parser reaches
  the token: a quote is a literal only where an operand is wanted.
- `InfluxQLLex` holds the one table of blanks and the one of characters that start no
  operand. A carriage return directly after a keyword is no blank (`InfluxQLBlanks`):
  verified for `SELECT AS FROM WHERE AND OR GROUP BY ORDER ASC DESC LIMIT OFFSET SLIMIT
  SOFFSET`; `fill`/`tz`, a `fill()` option and SHOW statements are refused by name.
- A name with a dot and no name after it is "expected field" (first item) or a statement
  left unparsed (later item, or in an alias).
- Identifiers and numbers are ASCII (no `u` flag): linear tokenizing, `usageé` is a
  leftover.
- `=~ /.*/` and `!~ /.*/` reach the SQL path as `(?:.*)`: InfluxQL has no `NOT`, and
  Core answers them as the expression reads.
- Refusals of select items name why.

## Verification

Every statement of the new `InfluxQLDefectCases.lexing/0` and `any_regex/0` was read from
Core 3.10.1 (73 + 7 cases; 60 of the 73 were wrong or refused on 5b02165).
