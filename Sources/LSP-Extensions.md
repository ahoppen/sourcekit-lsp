# LSP-Extensions

## SymbolInfo Request

Request for semantic information about the symbol at a given location.

This request looks up the symbol (if any) at a given text document location and returns SymbolDetails for that location, including information such as the symbol's USR. The symbolInfo request is not primarily designed for editors, but instead as an implementation detail of how one LSP implementation (e.g. SourceKit) gets information from another (e.g. clangd) to use in performing index queries or otherwise implementing the higher level requests such as definition.

- Parameters:
  - textDocument: The document in which to lookup the symbol location.
  - position: The document location at which to lookup symbol information.

- Returns: `[SymbolDetails]` for the given location, which may have multiple elements if there are multiple references, or no elements if there is no symbol at the given location.

This request does *not* require any additional client or server capabilities to use.