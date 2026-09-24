# v5.2.2 build fix

Root cause found in the v5.2.1 GitHub build settings:
`PRODUCT_NAME` was empty, which caused Xcode to resolve the application wrapper as `.app`
instead of `SyndicateQuant.app`, with `EXECUTABLE_PATH=.app/`.

Fixes:
- explicit `PRODUCT_NAME = SyndicateQuant`
- explicit iOS supported platforms
- version/build bumped to 5.2.2 / 522
- workflow also passes `PRODUCT_NAME=SyndicateQuant`
- unsigned build remains `CODE_SIGNING_ALLOWED=NO` / `CODE_SIGNING_REQUIRED=NO`
- bundle validation requires `SyndicateQuant.app/SyndicateQuant` and matching CFBundleExecutable
