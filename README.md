# LLM Paper Reading Helper

This repo is the source code for llm paper reading helper. The initial idea to
have a lightweight PDF reader, which can work across macOS, iPadOS and iOS to 
help me read purpose.

## Development (macOS)
```bash
make dev   # Run the macOS app via SwiftPM
make build # Build the macOS app
make release # Build a release .app bundle in dist/
make package # Build and zip a release bundle in dist/
make clean # Remove build artifacts and dist bundle
```

## Functionality 1:
For macOS I want to be able to open the paper (pdf). Then I should be able to 
select the context from the paper then if I right click. I will have the 
following options:
1. Highlight (Compatible with Preview on MacOS and chrome browser)
2. Add notes (Compatible with Preview on MacOS and chrome browser)
3. Invoke LLM with selected text. When clicked, one window is split to 
two panels. One on the left with the open pdf, one on the right being the 
chat interface with user selected LLM (default GPT). The select text 
becomes by default context of the conversation. Then user can add more 
context window in the input box on the right.

## Functionality 2:
I should be able to add comments in the pdf. The comments should be compatible 
with default pdf browser on macOS and chrome browser. When I open the comment 
I have the option to render it as Latex on the right tab. If there is a
rendering error, query the LLM to automatically fix it for me. 
